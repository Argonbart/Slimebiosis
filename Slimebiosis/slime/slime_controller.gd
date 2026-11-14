class_name SlimeController
extends Node
## Forwards configurable movement and stiffness input to a slime.


@export_category("Components")
@export var slime: VerletSlime = null

@export_category("Settings")
@export var move_left_key: Key = KEY_A
@export var move_right_key: Key = KEY_D
@export var boost_key: Key = KEY_W


# -------------------------------- GODOT FUNCTIONS ----------------------------------------


func _physics_process(_delta: float) -> void:
	var left: bool = Input.is_physical_key_pressed(move_left_key)
	var right: bool = Input.is_physical_key_pressed(move_right_key)
	slime.set_controls(float(right) - float(left), Input.is_physical_key_pressed(boost_key))


func _exit_tree() -> void:
	if is_instance_valid(slime):
		slime.set_controls(0.0, false)
