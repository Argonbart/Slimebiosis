class_name LocalController extends Node
## Drives the parent Slime from player input. Only attached to the local player's slime.
## Roll speed and jump strength come from the slime (server slime_stats).

## How far beyond touching a grab still reaches. Mirrors GRAB_MARGIN on the server.
const GRAB_MARGIN := 30.0
const BREAK_FREE_MASHES := 4   # jump presses needed to wriggle out
const BREAK_FREE_MIN := 0.65   # server refuses earlier than 0.6 s
const MAX_HELD := 5.0          # after this the captive frees itself automatically

var slime: Slime
var _held_time := 0.0
var _mashes := 0
var _break_free_cooldown := 0.0

func _ready() -> void:
	slime = get_parent() as Slime
	assert(slime != null, "LocalController must be a child of a Slime")
	slime.show_sector = true
	var cam := Camera2D.new()
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 8.0
	slime.add_child.call_deferred(cam)
	slime.hold_started.connect(_on_hold_started)
	slime.launched.connect(_on_launched)

func _on_hold_started() -> void:
	_held_time = 0.0
	_mashes = 0
	_break_free_cooldown = 0.0

func _on_launched(pos: Vector2, vel: Vector2) -> void:
	# The server placed and launched us; take over simulation from there.
	slime.teleport(pos, vel)

## While held: no movement, only the struggle to break free.
func _process_held(delta: float, typing: bool) -> void:
	_held_time += delta
	_break_free_cooldown = maxf(_break_free_cooldown - delta, 0.0)
	if not typing and Input.is_action_just_pressed("jump"):
		_mashes += 1
	var wants_out := _mashes >= BREAK_FREE_MASHES and _held_time >= BREAK_FREE_MIN
	if (wants_out or _held_time >= MAX_HELD) and _break_free_cooldown == 0.0:
		_break_free_cooldown = 0.5 # do not spam the reducer while waiting for the answer
		Net.break_free()

## Holding someone: throw them outward, wherever they are on the rim right now.
## Otherwise: grab the nearest slime inside the look sector.
func _try_grab_or_throw() -> void:
	if slime.holding_id != "":
		var captive: Slime = Slime.registry.get(slime.holding_id)
		if captive != null:
			Net.throw_held((slime.hold_point(captive) - slime.position).normalized())
		return
	var best: Slime = null
	var best_d := INF
	var best_angle := 0.0
	for other: Slime in Slime.registry.values():
		if other == slime or other.is_held() or other.holding_id != "":
			continue
		var to_other := other.position - slime.position
		var d := to_other.length()
		if d > slime.hold_distance(other) + GRAB_MARGIN or d >= best_d:
			continue
		var in_body := angle_difference(slime.angle, to_other.angle())
		if absf(in_body) > Slime.LOOK_HALF_ANGLE:
			continue
		best = other
		best_d = d
		best_angle = in_body
	if best != null:
		Net.grab(best.net_identity, best_angle)

func _physics_process(delta: float) -> void:
	# While a text field has focus the keyboard belongs to the UI.
	var typing := slime.get_viewport().gui_get_focus_owner() is LineEdit
	if slime.is_held():
		_process_held(delta, typing)
		return
	var dir := 0.0 if typing else Input.get_axis("move_left", "move_right")
	slime.steer(dir, slime.move_speed)
	if typing:
		return
	if Input.is_action_just_pressed("jump"):
		slime.jump(slime.jump_speed)
	if Input.is_action_just_pressed("grab"):
		_try_grab_or_throw()
