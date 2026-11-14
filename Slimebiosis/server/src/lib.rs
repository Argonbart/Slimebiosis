use spacetimedb::{Identity, ReducerContext, SpacetimeType, Table, Timestamp};

/// Must keep this exact name and shape: the Godot plugin maps it to a native Vector2.
#[derive(SpacetimeType, Clone, Copy, Debug, PartialEq)]
pub struct Vector2 {
    pub x: f32,
    pub y: f32,
}

/// Test fixture for tests/roundtrip_test: covers every column type the game tables use.
/// Only compiled with `--cfg test_fixture` (tools/publish.sh sets it for the local server).
#[cfg(test_fixture)]
#[spacetimedb::table(accessor = type_probe, public)]
pub struct TypeProbe {
    #[primary_key]
    pub id: u32,
    pub owner: Identity,
    pub pos: Vector2,
    pub facing: i8,
    pub mode: u8,
    pub seq: u32,
    pub held_by: Option<Identity>,
    pub at: Timestamp,
    pub angle: f32,
    pub shape: Vec<u8>,
}

// ---------------------------------------------------------------- game tables

/// Number of spawn points in the level. The server only hands out an index;
/// the positions live in the Godot level scene.
const SPAWN_SLOTS: u32 = 4;
const MAX_NAME_LEN: usize = 16;
/// Positions outside this box are rejected as garbage.
const WORLD_LIMIT: f32 = 100_000.0;

const ZERO: Vector2 = Vector2 { x: 0.0, y: 0.0 };

// Interaction tuning. Changing these only needs a republish, not new bindings.
/// Half of the look sector a slime can grab with, in radians (45 degrees), plus
/// a little tolerance for rounding. Mirrors `Slime.LOOK_HALF_ANGLE` in Godot.
const LOOK_HALF_ANGLE: f32 = 0.7854 + 0.05;
/// How far beyond touching (sum of both radii) a grab still reaches, in pixels.
/// Mirrors `LocalController.GRAB_MARGIN`.
const GRAB_MARGIN: f32 = 30.0;
/// Extra tolerance for latency: stored positions lag what the grabbing client saw.
const GRAB_SLACK: f32 = 300.0;
/// Upward pop when a captive breaks free.
const BREAK_FREE_VEL: Vector2 = Vector2 { x: 0.0, y: -320.0 };
/// A captive cannot break free before this much time has passed.
const MIN_HOLD_MICROS: i64 = 600_000;
/// Bytes in `SlimeTransform::shape`: 32 rim points, two signed bytes each.
/// Mirrors `VerletSlime.SHAPE_POINTS` in Godot.
const SHAPE_BYTES: usize = 64;

// Starting values for `SlimeStats`. Clients read them from the table.
const DEFAULT_WEIGHT: f32 = 1.0;
const DEFAULT_SIZE: f32 = 40.0;
const DEFAULT_ROTATION_SPEED: f32 = 5000.0;
const DEFAULT_THROW_STRENGTH: f32 = 780.0;
const DEFAULT_JUMP_STRENGTH: f32 = 400.0;
const DEFAULT_SOFTNESS: f32 = 0.5;
// Allowed range of each stat for `set_stats`. Mirrors the sliders in ui/hud.gd.
const WEIGHT_RANGE: (f32, f32) = (0.2, 5.0);
const SIZE_RANGE: (f32, f32) = (24.0, 100.0);
const ROTATION_SPEED_RANGE: (f32, f32) = (500.0, 10000.0);
const THROW_STRENGTH_RANGE: (f32, f32) = (100.0, 2000.0);
const JUMP_STRENGTH_RANGE: (f32, f32) = (100.0, 1000.0);
const SOFTNESS_RANGE: (f32, f32) = (0.0, 1.0);

/// One row per identity that has ever connected. Persists across sessions.
#[spacetimedb::table(accessor = player, public)]
pub struct Player {
    #[primary_key]
    pub identity: Identity,
    pub name: String,
    /// Hue in 0..1, derived from the identity.
    pub hue: f32,
    /// Open connections for this identity; the slime exists while this is > 0.
    pub connections: u32,
}

/// High-frequency movement state. Written only by the owning client
/// (the server only touches `pos` when a hold ends).
#[spacetimedb::table(accessor = slime_transform, public)]
pub struct SlimeTransform {
    #[primary_key]
    pub identity: Identity,
    pub pos: Vector2,
    pub vel: Vector2,
    /// Rotation of the body in radians; the look sector is centred on it.
    pub angle: f32,
    /// Angular speed in radians per second.
    pub spin: f32,
    /// The 32 rim points relative to `pos`, see `VerletSlime.pack_shape` in Godot.
    pub shape: Vec<u8>,
}

/// Low-frequency interaction state. Written only by the server.
/// A slime is "in the world" exactly while this row exists.
#[spacetimedb::table(accessor = slime_state, public)]
pub struct SlimeState {
    #[primary_key]
    pub identity: Identity,
    pub spawn_index: u32,
    pub held_by: Option<Identity>,
    pub holding: Option<Identity>,
    pub held_since: Timestamp,
    /// Where on the holder's body this captive sticks, in the holder's body
    /// frame (radians from the holder's `angle`). Only meaningful while held.
    pub hold_angle: f32,
    pub launch_pos: Vector2,
    pub launch_vel: Vector2,
    pub launch_seq: u32,
}

/// Per-slime physics parameters. Written only by the server; meant to change
/// during play later. Lives as long as the slime's `slime_state` row.
#[spacetimedb::table(accessor = slime_stats, public)]
pub struct SlimeStats {
    #[primary_key]
    pub identity: Identity,
    /// Scales how far this slime flies when thrown and how much it slows its carrier.
    pub weight: f32,
    /// Radius of the body in pixels.
    pub size: f32,
    /// Rolling drive of the body (the client's `drive_acceleration`).
    pub rotation_speed: f32,
    /// Launch speed of a thrown slime of weight 1.
    pub throw_strength: f32,
    /// Upward speed of a jump.
    pub jump_strength: f32,
    /// 0 = stiff rim, 1 = floppy rim.
    pub softness: f32,
}

fn radius_of(ctx: &ReducerContext, identity: Identity) -> f32 {
    ctx.db.slime_stats().identity().find(identity).map(|s| s.size).unwrap_or(DEFAULT_SIZE)
}

/// Centre-to-centre distance of a captive stuck to its holder's rim.
/// Mirrors `VerletSlime.hold_distance` in Godot.
fn hold_distance(ctx: &ReducerContext, holder: Identity, captive: Identity) -> f32 {
    radius_of(ctx, holder) + radius_of(ctx, captive)
}

/// Ends the hold between `holder` and `captive`: clears both sides, places the
/// captive and launches it with `vel`. `dir` is the unit direction from the
/// holder to the captive if the caller knows it (a throw); otherwise it comes
/// from the holder's stored rotation. Every way a hold can end goes through
/// here so the captive's position is never left stale.
fn end_hold(ctx: &ReducerContext, holder: Identity, captive: Identity, dir: Option<Vector2>, vel: Vector2) {
    if let Some(mut h) = ctx.db.slime_state().identity().find(holder) {
        h.holding = None;
        ctx.db.slime_state().identity().update(h);
    }
    let Some(mut c) = ctx.db.slime_state().identity().find(captive) else {
        return;
    };
    let captive_pos = ctx.db.slime_transform().identity().find(captive).map(|t| t.pos);
    let holder_t = ctx.db.slime_transform().identity().find(holder);
    let pos = match (holder_t, captive_pos) {
        (Some(t), _) => {
            let d = dir.unwrap_or_else(|| {
                let a = t.angle + c.hold_angle;
                Vector2 { x: a.cos(), y: a.sin() }
            });
            let dist = hold_distance(ctx, holder, captive);
            Vector2 { x: t.pos.x + d.x * dist, y: t.pos.y + d.y * dist }
        }
        (None, Some(p)) => p,
        (None, None) => ZERO,
    };
    c.held_by = None;
    c.launch_pos = pos;
    c.launch_vel = vel;
    c.launch_seq = c.launch_seq.wrapping_add(1);
    ctx.db.slime_state().identity().update(c);
    if let Some(mut t) = ctx.db.slime_transform().identity().find(captive) {
        t.pos = pos;
        t.vel = vel;
        ctx.db.slime_transform().identity().update(t);
    }
}

fn remove_slime(ctx: &ReducerContext, identity: Identity) {
    if let Some(state) = ctx.db.slime_state().identity().find(identity) {
        if let Some(captive) = state.holding {
            end_hold(ctx, identity, captive, None, ZERO);
        }
        if let Some(holder) = state.held_by {
            if let Some(mut h) = ctx.db.slime_state().identity().find(holder) {
                h.holding = None;
                ctx.db.slime_state().identity().update(h);
            }
        }
    }
    ctx.db.slime_transform().identity().delete(identity);
    ctx.db.slime_state().identity().delete(identity);
    ctx.db.slime_stats().identity().delete(identity);
}

// ------------------------------------------------------------------ lifecycle

#[spacetimedb::reducer(client_connected)]
pub fn client_connected(ctx: &ReducerContext) {
    let me = ctx.sender();
    match ctx.db.player().identity().find(me) {
        Some(mut p) => {
            p.connections += 1;
            ctx.db.player().identity().update(p);
        }
        None => {
            let bytes = me.to_byte_array();
            ctx.db.player().insert(Player {
                identity: me,
                name: format!("slime-{:02x}{:02x}", bytes[0], bytes[1]),
                hue: bytes[2] as f32 / 256.0,
                connections: 1,
            });
        }
    }
    // Idempotent: a second connection of the same identity keeps the existing slime.
    if ctx.db.slime_state().identity().find(me).is_none() {
        let spawn_index = ctx.db.slime_state().count() as u32 % SPAWN_SLOTS;
        ctx.db.slime_state().insert(SlimeState {
            identity: me,
            spawn_index,
            held_by: None,
            holding: None,
            held_since: ctx.timestamp,
            hold_angle: 0.0,
            launch_pos: ZERO,
            launch_vel: ZERO,
            launch_seq: 0,
        });
    }
    if ctx.db.slime_stats().identity().find(me).is_none() {
        ctx.db.slime_stats().insert(SlimeStats {
            identity: me,
            weight: DEFAULT_WEIGHT,
            size: DEFAULT_SIZE,
            rotation_speed: DEFAULT_ROTATION_SPEED,
            throw_strength: DEFAULT_THROW_STRENGTH,
            jump_strength: DEFAULT_JUMP_STRENGTH,
            softness: DEFAULT_SOFTNESS,
        });
    }
}

#[spacetimedb::reducer(client_disconnected)]
pub fn client_disconnected(ctx: &ReducerContext) {
    let me = ctx.sender();
    let mut remaining = 0;
    if let Some(mut p) = ctx.db.player().identity().find(me) {
        p.connections = p.connections.saturating_sub(1);
        remaining = p.connections;
        ctx.db.player().identity().update(p);
    }
    if remaining == 0 {
        remove_slime(ctx, me);
    }
}

// ------------------------------------------------------------------- reducers

#[spacetimedb::reducer]
pub fn set_name(ctx: &ReducerContext, name: String) -> Result<(), String> {
    let name = name.trim().to_string();
    if name.is_empty() || name.chars().count() > MAX_NAME_LEN {
        return Err(format!("name must be 1 to {MAX_NAME_LEN} characters"));
    }
    let mut p = ctx
        .db
        .player()
        .identity()
        .find(ctx.sender())
        .ok_or("unknown player")?;
    p.name = name;
    ctx.db.player().identity().update(p);
    Ok(())
}

/// Debug tuning: a client changes its own slime's physics parameters.
/// Values are clamped to the allowed ranges.
#[spacetimedb::reducer]
pub fn set_stats(
    ctx: &ReducerContext,
    weight: f32,
    size: f32,
    rotation_speed: f32,
    throw_strength: f32,
    jump_strength: f32,
    softness: f32,
) -> Result<(), String> {
    let me = ctx.sender();
    if ![weight, size, rotation_speed, throw_strength, jump_strength, softness].iter().all(|v| v.is_finite()) {
        return Err("invalid stats".into());
    }
    let mut row = ctx.db.slime_stats().identity().find(me).ok_or("you have no slime")?;
    row.weight = weight.clamp(WEIGHT_RANGE.0, WEIGHT_RANGE.1);
    row.size = size.clamp(SIZE_RANGE.0, SIZE_RANGE.1);
    row.rotation_speed = rotation_speed.clamp(ROTATION_SPEED_RANGE.0, ROTATION_SPEED_RANGE.1);
    row.throw_strength = throw_strength.clamp(THROW_STRENGTH_RANGE.0, THROW_STRENGTH_RANGE.1);
    row.jump_strength = jump_strength.clamp(JUMP_STRENGTH_RANGE.0, JUMP_STRENGTH_RANGE.1);
    row.softness = softness.clamp(SOFTNESS_RANGE.0, SOFTNESS_RANGE.1);
    ctx.db.slime_stats().identity().update(row);
    Ok(())
}

/// Called ~20x per second by each client for its own slime.
#[spacetimedb::reducer]
pub fn update_slime(
    ctx: &ReducerContext,
    pos: Vector2,
    vel: Vector2,
    angle: f32,
    spin: f32,
    shape: Vec<u8>,
) -> Result<(), String> {
    let me = ctx.sender();
    let Some(state) = ctx.db.slime_state().identity().find(me) else {
        return Err("no slime for this connection".into());
    };
    // While held the holder decides where we are; late packets are dropped quietly.
    if state.held_by.is_some() {
        return Ok(());
    }
    let finite = [pos.x, pos.y, vel.x, vel.y, angle, spin].iter().all(|v| v.is_finite());
    if !finite || pos.x.abs() > WORLD_LIMIT || pos.y.abs() > WORLD_LIMIT || shape.len() != SHAPE_BYTES {
        return Err("invalid transform".into());
    }
    let row = SlimeTransform { identity: me, pos, vel, angle, spin, shape };
    if ctx.db.slime_transform().identity().find(me).is_some() {
        ctx.db.slime_transform().identity().update(row);
    } else {
        ctx.db.slime_transform().insert(row);
    }
    Ok(())
}

/// Pick up another slime. The server is the referee: both must be free and close.
/// `attach_angle` is where the target sits on the grabber's body, in the
/// grabber's body frame; it must lie inside the look sector. The client
/// measures it because the stored rotation is too stale to check against (a
/// slime turns through the whole sector between two updates).
#[spacetimedb::reducer]
pub fn grab(ctx: &ReducerContext, target: Identity, attach_angle: f32) -> Result<(), String> {
    let me = ctx.sender();
    if target == me {
        return Err("cannot grab yourself".into());
    }
    let mut mine = ctx.db.slime_state().identity().find(me).ok_or("you have no slime")?;
    let mut theirs = ctx.db.slime_state().identity().find(target).ok_or("target has no slime")?;
    if mine.held_by.is_some() {
        return Err("you are being held".into());
    }
    if mine.holding.is_some() {
        return Err("you are already holding someone".into());
    }
    if theirs.held_by.is_some() {
        return Err("target is already held".into());
    }
    if theirs.holding.is_some() {
        return Err("target is holding someone".into());
    }
    let my_t = ctx.db.slime_transform().identity().find(me).ok_or("you have no position yet")?;
    let their_t = ctx.db.slime_transform().identity().find(target).ok_or("target has no position yet")?;
    if !attach_angle.is_finite() || attach_angle.abs() > LOOK_HALF_ANGLE {
        return Err("target is outside your look sector".into());
    }
    let (dx, dy) = (my_t.pos.x - their_t.pos.x, my_t.pos.y - their_t.pos.y);
    let limit = hold_distance(ctx, me, target) + GRAB_MARGIN + GRAB_SLACK;
    if dx * dx + dy * dy > limit * limit {
        return Err("target is out of reach".into());
    }
    mine.holding = Some(target);
    theirs.held_by = Some(me);
    theirs.held_since = ctx.timestamp;
    theirs.hold_angle = attach_angle;
    ctx.db.slime_state().identity().update(mine);
    ctx.db.slime_state().identity().update(theirs);
    Ok(())
}

/// Throw the held slime outward. `dir` is the direction from the thrower to
/// the captive at the moment of the throw. The launch speed is the thrower's
/// strength divided by the captive's weight.
#[spacetimedb::reducer]
pub fn throw_held(ctx: &ReducerContext, dir: Vector2) -> Result<(), String> {
    let me = ctx.sender();
    let captive = ctx
        .db
        .slime_state()
        .identity()
        .find(me)
        .and_then(|s| s.holding)
        .ok_or("you are not holding anyone")?;
    let len = (dir.x * dir.x + dir.y * dir.y).sqrt();
    if !len.is_finite() || len < 0.001 {
        return Err("invalid throw direction".into());
    }
    let unit = Vector2 { x: dir.x / len, y: dir.y / len };
    let strength = ctx.db.slime_stats().identity().find(me).map(|s| s.throw_strength).unwrap_or(DEFAULT_THROW_STRENGTH);
    let weight = ctx.db.slime_stats().identity().find(captive).map(|s| s.weight).unwrap_or(DEFAULT_WEIGHT);
    let speed = strength / weight.max(WEIGHT_RANGE.0);
    let vel = Vector2 { x: unit.x * speed, y: unit.y * speed };
    end_hold(ctx, me, captive, Some(unit), vel);
    Ok(())
}

/// The held slime wriggles out. Also the escape hatch when a holder's client hangs.
#[spacetimedb::reducer]
pub fn break_free(ctx: &ReducerContext) -> Result<(), String> {
    let me = ctx.sender();
    let state = ctx.db.slime_state().identity().find(me).ok_or("you have no slime")?;
    let holder = state.held_by.ok_or("you are not being held")?;
    let held_micros = ctx
        .timestamp
        .duration_since(state.held_since)
        .map(|d| d.as_micros() as i64)
        .unwrap_or(0);
    if held_micros < MIN_HOLD_MICROS {
        return Err("too early to break free".into());
    }
    end_hold(ctx, holder, me, None, BREAK_FREE_VEL);
    Ok(())
}

// ------------------------------------------------------------- test fixture

#[cfg(test_fixture)]
#[spacetimedb::reducer]
pub fn probe(
    ctx: &ReducerContext,
    id: u32,
    pos: Vector2,
    facing: i8,
    mode: u8,
    seq: u32,
    target: Identity,
    held: bool,
    angle: f32,
    shape: Vec<u8>,
) -> Result<(), String> {
    if mode > 3 {
        return Err(format!("invalid mode {mode}"));
    }
    ctx.db.type_probe().id().delete(id);
    ctx.db.type_probe().insert(TypeProbe {
        id,
        owner: ctx.sender(),
        pos,
        facing,
        mode,
        seq,
        held_by: if held { Some(target) } else { None },
        at: ctx.timestamp,
        angle,
        shape,
    });
    Ok(())
}
