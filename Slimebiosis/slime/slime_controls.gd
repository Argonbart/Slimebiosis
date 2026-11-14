extends Node

@export var move_speed := 200.0
@export var jump_speed := 365.0

@onready var slime = get_parent()
var jump_held := false

func _physics_process(_delta: float) -> void:
	var left := Input.is_action_pressed("ui_left") or Input.is_physical_key_pressed(KEY_A)
	var right := Input.is_action_pressed("ui_right") or Input.is_physical_key_pressed(KEY_D)
	var jumping := Input.is_physical_key_pressed(KEY_SPACE)
	slime.steer(float(right) - float(left), move_speed)
	if jumping and not jump_held:
		slime.jump(jump_speed)
	jump_held = jumping
