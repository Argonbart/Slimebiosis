class_name LocalController
extends Node
## Drives the parent slime from player input and referees grabs through the
## server. Only attached to the local player's slime in a networked level.


## How far beyond touching a grab still reaches. Mirrors GRAB_MARGIN on the server.
const GRAB_MARGIN: float = 30.0
## Jump presses needed to wriggle out of a hold.
const BREAK_FREE_MASHES: int = 4
## The server refuses a break free earlier than 0.6 s.
const BREAK_FREE_MIN: float = 0.65
## After this the captive frees itself automatically.
const MAX_HELD: float = 5.0
## Stiffens the rim while held down. Registered here until it gets a proper input map entry.
const BOOST_ACTION: StringName = &"boost"
const BOOST_KEYS: Array[Key] = [KEY_SHIFT, KEY_S, KEY_DOWN]

var slime: VerletSlime = null

var _held_time: float = 0.0
var _mashes: int = 0
var _break_free_cooldown: float = 0.0
var _release_cooldown: float = 0.0


# -------------------------------- GODOT FUNCTIONS ----------------------------------------


func _init() -> void:
	# Input is applied before the slime simulates its step.
	process_physics_priority = -1


func _ready() -> void:
	slime = get_parent() as VerletSlime
	assert(slime != null, "LocalController must be a child of a VerletSlime")
	_register_boost_action()
	slime.show_sector = true
	var camera: Camera2D = Camera2D.new()
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 8.0
	slime.add_child.call_deferred(camera)
	slime.hold_started.connect(_on_hold_started)
	slime.launched.connect(_on_launched)


func _physics_process(delta: float) -> void:
	# While a text field has focus the keyboard belongs to the UI.
	var typing: bool = slime.get_viewport().gui_get_focus_owner() is LineEdit
	if slime.is_held():
		slime.set_controls(0.0, false)
		_process_held(delta, typing)
		return
	if slime.is_burst():
		# A burst slime cannot hold on to anyone; let the captive go.
		_release_cooldown = maxf(_release_cooldown - delta, 0.0)
		if slime.holding_id != "" and _release_cooldown == 0.0:
			_release_cooldown = 0.5
			Net.throw_held(Vector2.UP)
		return
	if typing:
		slime.set_controls(0.0, false)
		return
	slime.set_controls(Input.get_axis("move_left", "move_right"), Input.is_action_pressed(BOOST_ACTION))
	if Input.is_action_just_pressed("jump"):
		slime.jump()
	if Input.is_action_just_pressed("grab"):
		_try_grab_or_throw()


func _exit_tree() -> void:
	if is_instance_valid(slime):
		slime.set_controls(0.0, false)


# -------------------------------- LOCAL FUNCTIONS ----------------------------------------


func _register_boost_action() -> void:
	if InputMap.has_action(BOOST_ACTION):
		return
	InputMap.add_action(BOOST_ACTION)
	for key: Key in BOOST_KEYS:
		var event: InputEventKey = InputEventKey.new()
		event.physical_keycode = key
		InputMap.action_add_event(BOOST_ACTION, event)


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
	var wants_out: bool = _mashes >= BREAK_FREE_MASHES and _held_time >= BREAK_FREE_MIN
	if (wants_out or _held_time >= MAX_HELD) and _break_free_cooldown == 0.0:
		_break_free_cooldown = 0.5 # do not spam the reducer while waiting for the answer
		Net.break_free()


## Holding someone: throw them outward, wherever they are on the rim right now.
## Otherwise: grab the nearest slime inside the look sector.
func _try_grab_or_throw() -> void:
	var center: Vector2 = slime.get_center()
	if slime.holding_id != "":
		var captive: VerletSlime = VerletSlime.registry.get(slime.holding_id)
		if captive != null:
			Net.throw_held((slime.hold_point(captive) - center).normalized())
		return
	var best: VerletSlime = null
	var best_distance: float = INF
	var best_angle: float = 0.0
	for other: VerletSlime in VerletSlime.registry.values():
		if other == slime or other.is_held() or other.holding_id != "":
			continue
		var to_other: Vector2 = other.get_center() - center
		var distance: float = to_other.length()
		if distance > slime.hold_distance(other) + GRAB_MARGIN or distance >= best_distance:
			continue
		var in_body: float = angle_difference(slime.angle, to_other.angle())
		if absf(in_body) > VerletSlime.LOOK_HALF_ANGLE:
			continue
		best = other
		best_distance = distance
		best_angle = in_body
	if best != null:
		Net.grab(best.net_identity, best_angle)
