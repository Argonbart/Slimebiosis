extends Node
## Headless grab/throw referee check: the real sandbox (client A, through Net)
## plus two raw clients B and C in the same process.
## Run: godot --headless --path . --fixed-fps 60 res://tests/grab_test.tscn
## Requires a local server with the module published as "slimecrime".

const TIMEOUT := 15.0

var _failures: Array[String] = []

func _ready() -> void:
	await _run()
	for a in ["move_left", "move_right", "jump", "grab"]:
		Input.action_release(a)
	for f in _failures:
		printerr("FAIL: ", f)
	print("grab_test: %s" % ("PASSED" if _failures.is_empty() else "FAILED"))
	get_tree().quit(0 if _failures.is_empty() else 1)

func _check(cond: bool, what: String) -> void:
	if not cond:
		_failures.append(what)

## Headless frames run far faster than real time; while set, frames are slowed
## to ~60 per second so frame delta and wall-clock time agree.
var _paced := false

func _process(_delta: float) -> void:
	if _paced:
		OS.delay_msec(16)

func _until(cond: Callable, what: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await get_tree().process_frame
	_failures.append("timeout: " + what)
	return false

## Waits real (wall clock) time; the server's clock does not follow --fixed-fps.
func _real_wait(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

func _tap(action: String) -> void:
	Input.action_press(action)
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release(action)
	await get_tree().physics_frame

## Awaits a reducer call; returns "" on success or the error text.
func _result(call: SpacetimeDBReducerCall) -> String:
	if call == null:
		return "not sent"
	var out := {"done": false, "err": ""}
	call.on_error.connect(func(e: String) -> void: out.err = e)
	call.response.connect(func(_r) -> void: out.done = true)
	await _until(func() -> bool: return out.done, "reducer response")
	return out.err

func _expect_error(call: SpacetimeDBReducerCall, needle: String, what: String) -> void:
	var err := await _result(call)
	_check(needle in err, "%s: expected error containing '%s', got '%s'" % [what, needle, err])

func _client(token: String) -> GameModuleClient:
	var c: GameModuleClient = load("res://spacetime_bindings/schema/module_game_client.gd").new()
	c.token_save_path = token
	add_child(c)
	var options := SpacetimeDBConnectionOptions.new()
	options.threading = false
	options.one_time_token = true
	var ok := {"v": false}
	c.connected.connect(func(_i, _t) -> void: ok.v = true)
	c.connect_db(Net.url, Net.database, options)
	await _until(func() -> bool: return ok.v, "client connected")
	var sub := c.subscribe(Net.QUERIES)
	await _until(func() -> bool: return sub.active, "client subscribed")
	return c

func _state(c: GameModuleClient, identity: PackedByteArray) -> GameSlimeState:
	return c.db.slime_state.identity.find(identity)

## The resting ring in the wire format, as a real client would send it.
var _rest: PackedByteArray

## Reports a resting slime for a bare client.
func _put(c: GameModuleClient, pos: Vector2, angle := 0.0) -> String:
	return await _result(c.reducers.update_slime(pos, Vector2.ZERO, angle, 0.0, _rest))

func _run() -> void:
	# Soft-body physics runs on frame delta while the server runs on wall-clock
	# time; keep both in step for the whole test.
	_paced = true
	Net.token_path = "user://token_grab_test_a.dat"
	Net.one_time_token = true
	Net.offline = false
	Net.url = Net.LOCAL_URL
	Net.database = Net.LOCAL_DB
	var sandbox: Node2D = load("res://world/sandbox.tscn").instantiate()
	add_child(sandbox)
	if not await _until(func() -> bool: return Net.is_ready, "Net ready"):
		return
	var a: VerletSlime = sandbox.local_slime
	var a_ident := Net.local_identity
	var spawner: SlimeSpawner = sandbox.spawner
	_rest = a.pack_shape()
	var a_resting := func() -> bool: return a.velocity.length() < 20.0 and absf(a.spin) < 0.3
	await _until(a_resting, "A settles")

	var b := await _client("user://token_grab_test_b.dat")
	var c := await _client("user://token_grab_test_c.dat")
	var b_ident := b.get_local_identity()
	var c_ident := c.get_local_identity()
	var b_id := Net.id_of(b_ident)
	var c_id := Net.id_of(c_ident)
	await _until(func() -> bool: return b.db.slime_transform.identity.find(a_ident) != null, "B sees A")
	var reach := a.size * 2.0 # centre distance of two touching slimes of this size
	var look := func() -> Vector2: return Vector2.from_angle(a.angle)

	# --- referee: out of reach
	await _put(b, a.position + Vector2(1000, 0))
	await _until(func() -> bool: return spawner.puppets.has(b_id), "puppet B")
	var pb: VerletSlime = spawner.puppets[b_id]
	await _expect_error(Net.grab(b_ident, 0.0), "out of reach", "far grab")
	await _tap("grab") # input path must not even try: nothing within reach
	_check(a.holding_id == "", "A should hold nobody yet")

	# --- look sector: the server refuses an angle outside it, and the input
	# path does not grab a slime that is close but behind
	await _put(b, a.position - look.call() * (reach + 10.0))
	await _until(func() -> bool: return pb.position.distance_to(a.position) < reach + 20.0, "puppet B behind A")
	await _expect_error(Net.grab(b_ident, PI), "look sector", "grab behind")
	await _expect_error(Net.grab(b_ident, 1.0), "look sector", "grab just outside the sector")
	await _tap("grab")
	await _real_wait(0.3)
	_check(a.holding_id == "", "A must not grab a slime behind it")

	# --- grab through real input: B in front of A's face, slightly off centre
	var offset_angle := 0.4
	await _put(b, a.position + look.call().rotated(offset_angle) * (reach + 10.0))
	await _until(func() -> bool: return pb.position.distance_to(a.position + look.call().rotated(offset_angle) * (reach + 10.0)) < 6.0, "puppet B in front of A")
	await _tap("grab")
	await _until(func() -> bool: return a.holding_id == b_id and pb.held_by_id == Net.local_id, "A holds B")
	var sb := _state(b, b_ident)
	_check(absf(sb.hold_angle - offset_angle) < 0.15, "captive sticks where it was caught, hold_angle %.2f" % sb.hold_angle)
	await _expect_error(b.reducers.break_free(), "too early", "immediate break free")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(pb.position.distance_to(a.hold_point(pb)) < 6.0, "held puppet sits on A's rim point, off by %.1f" % pb.position.distance_to(a.hold_point(pb)))
	_check(absf(pb.position.distance_to(a.position) - reach) < 20.0, "captive sits on A's rim, distance %.1f" % pb.position.distance_to(a.position))

	# held slime's own updates are ignored
	var before: Vector2 = b.db.slime_transform.identity.find(b_ident).pos
	await _put(b, Vector2(-5000, 0))
	_check(b.db.slime_transform.identity.find(b_ident).pos == before, "held slime must not move itself")

	# --- referee: no double grabs, no chains
	await _put(c, a.position + Vector2(-reach, 0))
	await _expect_error(c.reducers.grab(b_ident, 0.0), "already held", "grab a held slime")
	await _expect_error(c.reducers.grab(a_ident, 0.0), "holding someone", "grab a holder")
	await _expect_error(Net.grab(c_ident, 0.0), "already holding", "grab while holding")
	await _expect_error(b.reducers.grab(c_ident, 0.0), "being held", "grab while held")
	await _expect_error(c.reducers.throw_held(Vector2.RIGHT), "not holding", "throw with empty hands")

	# --- the captive turns with its holder: rolling left swings it over the top
	var arm0 := (pb.position - a.position).angle()
	var x_before := a.position.x
	Input.action_press("move_left")
	await _real_wait(0.6)
	Input.action_release("move_left")
	var swung := absf(angle_difference(arm0, (pb.position - a.position).angle()))
	print("grab_test info: captive swung %.2f rad, holder moved %.1f px in 0.6 s" % [swung, a.position.x - x_before])
	_check(swung > 0.5, "captive rotates with the rolling holder, swung %.2f rad" % swung)
	_check(pb.position.distance_to(a.hold_point(pb)) < 25.0, "captive stays on its rim point while carried, off by %.1f" % pb.position.distance_to(a.hold_point(pb)))
	_check(absf(pb.position.distance_to(a.position) - reach) < 30.0, "captive stays on the rim while carried, distance %.1f" % pb.position.distance_to(a.position))
	_check(absf(angle_difference(pb.angle, a.angle + pb.hold_angle)) < 0.01, "captive faces outward from the holder")

	# --- throw through real input: outward, wherever the captive is right now
	var out := (a.hold_point(pb) - a.position).normalized()
	await _tap("grab")
	await _until(func() -> bool: return a.holding_id == "" and not pb.is_held(), "A threw B")
	await _until(func() -> bool: return _state(b, b_ident).launch_seq == 1, "B sees its launch")
	sb = _state(b, b_ident) # a lambda cannot assign the outer variable
	_check(sb.held_by.is_none(), "B no longer held")
	var thrown := sb.launch_vel.normalized()
	_check(thrown.dot(out) > 0.8, "thrown outward: %s vs captive direction %s" % [thrown, out])
	_check(absf(sb.launch_vel.length() - 420.0) < 1.0, "throw speed comes from slime_stats, got %.1f" % sb.launch_vel.length())
	var a_row: GameSlimeTransform = b.db.slime_transform.identity.find(a_ident)
	# A keeps moving and reporting after the throw, so compare loosely.
	_check(sb.launch_pos.distance_to(a_row.pos + thrown * reach) < 40.0, "launch_pos on the thrower's rim along the throw, off by %.1f" % sb.launch_pos.distance_to(a_row.pos + thrown * reach))
	_check(b.db.slime_transform.identity.find(b_ident).pos.distance_to(sb.launch_pos) < 0.01, "server moved B's transform to the launch position")
	await get_tree().physics_frame
	await get_tree().physics_frame
	# no prediction: the puppet waits at the launch position until B's client reports
	await _real_wait(0.2)
	_check(pb.position.distance_to(sb.launch_pos) < 2.0, "puppet B waits at the launch position, off by %.1f" % pb.position.distance_to(sb.launch_pos))
	# B's client reports its flight; the puppet must follow without jumping
	var prev := pb.position
	var worst_back := 0.0
	var worst_step := 0.0 # in units of what the throw speed covers in that frame
	var last_ms := Time.get_ticks_msec()
	for i in 8:
		var at := 0.05 * (i + 1)
		b.reducers.update_slime(sb.launch_pos + sb.launch_vel * at, sb.launch_vel, 0.0, 0.0, _rest)
		var until := Time.get_ticks_msec() + 50
		while Time.get_ticks_msec() < until:
			await get_tree().process_frame
			var step := (pb.position - prev).dot(thrown)
			prev = pb.position
			var frame_s := maxf(Time.get_ticks_msec() - last_ms, 8.0) / 1000.0
			last_ms = Time.get_ticks_msec()
			worst_back = minf(worst_back, step)
			worst_step = maxf(worst_step, step / (420.0 * frame_s))
	_check(worst_back > -1.0, "puppet B never jumps back after a throw, worst %.1f" % worst_back)
	_check(worst_step < 3.0, "puppet B never jumps forward after a throw, worst %.1fx the throw speed" % worst_step)
	_check((pb.position - sb.launch_pos).dot(thrown) > 100.0, "puppet B follows B's reported flight")
	# then B's own report takes over
	var landed := a.position + Vector2(400.0, 0.0)
	await _put(b, landed)
	await _until(func() -> bool: return pb.position.distance_to(landed) < 2.0, "puppet B follows B's own reports again")

	# --- A is grabbed and thrown by B: the local slime freezes, then takes over again
	await _until(a_resting, "A at rest before being grabbed")
	await _put(b, a.position + Vector2(reach, 0), PI) # B looks left, at A
	await _until(func() -> bool: return pb.position.distance_to(a.position) < reach + 6.0 and absf(angle_difference(pb.angle, PI)) < 0.01, "puppet B next to A")
	_check(await _result(b.reducers.grab(a_ident, 0.0)) == "", "B grabs A")
	await _until(func() -> bool: return a.is_held(), "A is held")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(a.position.distance_to(pb.position + Vector2(-reach, 0)) < 2.0, "A sits on puppet B's face, off by %.1f" % a.position.distance_to(pb.position + Vector2(-reach, 0)))
	Input.action_press("move_right")
	await _real_wait(0.2)
	Input.action_release("move_right")
	_check(a.position.distance_to(pb.position + Vector2(-reach, 0)) < 2.0, "held A cannot roll away")
	_check(await _result(b.reducers.throw_held(Vector2(-1, -1))) == "", "B throws A")
	await _until(func() -> bool: return not a.is_held(), "A released")
	await get_tree().physics_frame
	_check(a.velocity.x < -200.0 and a.velocity.y < -200.0, "A flies up-left after the throw, v=%s" % a.velocity)
	await _until(func() -> bool:
		var t: GameSlimeTransform = b.db.slime_transform.identity.find(a_ident)
		return a_resting.call() and t != null and t.pos.distance_to(a.position) < 3.0, "A lands, stops and reports its own position again")
	_check(a.position.y < 1800.0 and a.position.y > 1700.0, "A rests on the ground after the flight, y %.1f" % a.position.y)

	# --- break free by mashing jump
	await _put(c, a.position + Vector2(reach, 0), PI)
	_check(await _result(c.reducers.grab(a_ident, 0.0)) == "", "C grabs A")
	await _until(func() -> bool: return a.is_held(), "A is held by C")
	await _real_wait(0.75)
	for i in 4:
		await _tap("jump")
	await _until(func() -> bool: return not a.is_held(), "A mashes free")
	_check(_state(c, c_ident).holding.is_none(), "C's hands are empty after the escape")

	# --- holder disconnects: captive is freed
	await _until(a_resting, "A lands again")
	await _put(b, a.position + Vector2(reach, 0), PI)
	_check(await _result(b.reducers.grab(a_ident, 0.0)) == "", "B grabs A again")
	await _until(func() -> bool: return a.is_held(), "A is held by B")
	b.disconnect_db()
	await _until(func() -> bool: return not a.is_held(), "A freed when its holder leaves")

	# --- captive disconnects: holder's hands are freed
	await _until(func() -> bool:
		var t: GameSlimeTransform = c.db.slime_transform.identity.find(a_ident)
		return a_resting.call() and t != null and t.pos.distance_to(a.position) < 3.0, "A settled")
	await _put(c, a.position + look.call() * reach)
	await _until(func() -> bool: return spawner.puppets.has(c_id) and spawner.puppets[c_id].position.distance_to(a.position) < reach + 6.0, "puppet C in front of A")
	await _tap("grab")
	await _until(func() -> bool: return a.holding_id == c_id, "A holds C")
	c.disconnect_db()
	await _until(func() -> bool: return a.holding_id == "", "A's hands freed when the captive leaves")
	await get_tree().physics_frame
	await get_tree().physics_frame
