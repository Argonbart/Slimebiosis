class_name RemotePuppet extends Node
## Moves the parent Slime from network snapshots: renders slightly in the past
## and interpolates, with a short velocity extrapolation when updates stall.

const DELAY_MS := 50.0
const MAX_EXTRAPOLATE_MS := 150.0
const TELEPORT_DISTANCE := 300.0
const MAX_SNAPSHOTS := 16

var slime: Slime
## Each: {t: msec received, pos, vel, angle, spin, shape (body-frame rim)}
var _snaps: Array[Dictionary] = []

## Diagnostics for the debug overlay (F3), all in msec; -1 = not measured yet.
var _launch_at := -1.0          # when the last launch reached this client
var _awaiting_owner := false    # launch seen, owner has not reported since
var _launch_pos := Vector2.ZERO
var throw_confirm_ms := -1.0    # our throw input -> launch arrived from the server
var first_report_ms := -1.0     # launch arrived -> thrown player's first own report

func _ready() -> void:
	slime = get_parent() as Slime
	slime.hold_started.connect(reset)
	slime.launched.connect(_on_launched)

func _on_launched(pos: Vector2, _vel: Vector2) -> void:
	# No prediction: the slime waits where the hold ended until its owner's
	# client reports the flight. The anchor snapshot (zero velocity, so it is
	# not extrapolated) lets the first report blend in instead of jumping.
	var now := float(Time.get_ticks_msec())
	reset()
	_snaps.append({"t": now, "pos": pos, "vel": Vector2.ZERO, "angle": slime.angle, "spin": 0.0, "shape": slime.rest_shape()})
	slime.position = pos
	slime.velocity = Vector2.ZERO
	slime.spin = 0.0
	slime.apply_shape(slime.rest_shape())
	_launch_pos = pos
	_launch_at = now
	_awaiting_owner = true
	first_report_ms = -1.0
	throw_confirm_ms = now - Net.throw_sent_at if Net.throw_sent_at > 0.0 else -1.0
	Net.throw_sent_at = 0.0

func push(row: GameSlimeTransform) -> void:
	var now := float(Time.get_ticks_msec())
	if _awaiting_owner:
		# The server writes the launch position into the row itself; that is
		# already covered by the anchor snapshot.
		if row.pos.distance_to(_launch_pos) < 0.5:
			return
		_awaiting_owner = false
		first_report_ms = now - _launch_at
	var snap := {"t": now, "pos": row.pos, "vel": row.vel, "angle": row.angle, "spin": row.spin, "shape": slime.unpack_shape(row.shape)}
	if not _snaps.is_empty() and (_snaps[-1].pos as Vector2).distance_to(row.pos) > TELEPORT_DISTANCE:
		_snaps.clear()
	if _snaps.is_empty() and is_instance_valid(slime):
		slime.position = row.pos
	_snaps.append(snap)
	if _snaps.size() > MAX_SNAPSHOTS:
		_snaps.pop_front()

## Drop history, e.g. when the slime is grabbed or launched.
func reset() -> void:
	_snaps.clear()

func _process(_delta: float) -> void:
	if slime.is_held():
		return # Slime positions itself on its holder
	if _snaps.is_empty():
		return
	var s := _sample(float(Time.get_ticks_msec()) - DELAY_MS)
	slime.position = s.pos
	slime.velocity = s.vel
	slime.angle = s.angle
	slime.spin = s.spin
	slime.apply_shape(s.shape)

## Interpolated state at `render_t` (msec), extrapolating briefly past the newest snapshot.
func _sample(render_t: float) -> Dictionary:
	var a: Dictionary = _snaps[0]
	var b: Dictionary = _snaps[-1]
	if render_t <= a.t:
		return a
	if render_t >= b.t:
		var ahead := minf(render_t - b.t, MAX_EXTRAPOLATE_MS) / 1000.0
		return {"pos": b.pos + b.vel * ahead, "vel": b.vel, "angle": b.angle + b.spin * ahead, "spin": b.spin, "shape": b.shape}
	for i in range(_snaps.size() - 1, 0, -1):
		if _snaps[i - 1].t <= render_t:
			a = _snaps[i - 1]
			b = _snaps[i]
			break
	var w := inverse_lerp(a.t, b.t, render_t)
	# A fast slime turns more than half a circle between two snapshots, so the
	# shortest way round is not always the way it went: use the spin to decide.
	var turned := angle_difference(a.angle, b.angle)
	var expected: float = (a.spin + b.spin) * 0.5 * (b.t - a.t) / 1000.0
	turned += TAU * roundf((expected - turned) / TAU)
	var rim := PackedVector2Array()
	var rim_a: PackedVector2Array = a.shape
	var rim_b: PackedVector2Array = b.shape
	for i in rim_a.size():
		rim.append(rim_a[i].lerp(rim_b[i], w))
	return {"pos": (a.pos as Vector2).lerp(b.pos, w), "vel": (a.vel as Vector2).lerp(b.vel, w),
		"angle": a.angle + turned * w, "spin": lerpf(a.spin, b.spin, w), "shape": rim}

## One line for the debug overlay: how this slime's updates are arriving.
func debug_text() -> String:
	var text := "no updates yet"
	if _snaps.size() >= 2:
		var total := 0.0
		var worst := 0.0
		for i in range(1, _snaps.size()):
			var gap: float = _snaps[i].t - _snaps[i - 1].t
			total += gap
			worst = maxf(worst, gap)
		text = "updates every %d ms (worst %d), newest %d ms old, drawn %d ms behind" % [
			total / (_snaps.size() - 1), worst, float(Time.get_ticks_msec()) - _snaps[-1].t, DELAY_MS]
	if _launch_at >= 0.0:
		text += "\n    last launch:"
		if throw_confirm_ms >= 0.0:
			text += " server confirmed our throw after %d ms," % throw_confirm_ms
		text += " owner's first report %s" % ("pending" if first_report_ms < 0.0 else "%d ms after the launch arrived" % first_report_ms)
	return text
