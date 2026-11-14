class_name SlimeControls
extends Node
## Translates player input into slime rolling and jumping.


@export_category("Components")
@export var slime: Slime = null

@export_category("Data")
@export var move_speed: float = 200.0
@export var jump_speed: float = 365.0

var _jump_held: bool = false



# -------------------------------- GODOT FUNCTIONS ----------------------------------------


func _physics_process(_delta: float) -> void:
	var left: bool = Input.is_action_pressed("ui_left") or Input.is_physical_key_pressed(KEY_A)
	var right: bool = Input.is_action_pressed("ui_right") or Input.is_physical_key_pressed(KEY_D)
	var jumping: bool = Input.is_physical_key_pressed(KEY_SPACE)
	slime.steer(float(right) - float(left), move_speed)
	if jumping and not _jump_held:
		slime.jump(jump_speed)
	_jump_held = jumping

