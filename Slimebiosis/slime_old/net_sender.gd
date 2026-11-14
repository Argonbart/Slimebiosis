class_name NetSender extends Node
## Sends the parent (local) slime's transform and shape to the server at a
## fixed rate, and only when something changed.

const SEND_INTERVAL := 0.05 # 20 Hz

var slime: Slime
var _timer := 0.0
var _has_sent := false
var _last_pos := Vector2.ZERO
var _last_vel := Vector2.ZERO
var _last_angle := 0.0
var _last_shape := PackedByteArray()

func _ready() -> void:
	slime = get_parent() as Slime
	# After (re)connecting the server has no transform row for us: send once.
	Net.ready_to_play.connect(func() -> void: _has_sent = false)

func _physics_process(delta: float) -> void:
	_timer += delta
	if _timer < SEND_INTERVAL or not Net.is_ready or slime.is_held():
		return
	_timer = 0.0
	var shape := slime.pack_shape()
	# A resting soft body still trembles a little; ignore that.
	var changed := not _has_sent \
		or slime.position.distance_squared_to(_last_pos) > 0.25 \
		or slime.velocity.distance_squared_to(_last_vel) > 4.0 \
		or absf(angle_difference(slime.angle, _last_angle)) > 0.01 \
		or shape != _last_shape
	if not changed:
		return
	_has_sent = true
	_last_pos = slime.position
	_last_vel = slime.velocity
	_last_angle = slime.angle
	_last_shape = shape
	Net.send_transform(_last_pos, _last_vel, _last_angle, slime.spin, shape)
