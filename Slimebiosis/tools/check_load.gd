extends SceneTree
## Loads the autoloads (by starting) and the generated client, then quits.
## Used by gen_bindings.sh to surface script errors after regeneration.
func _init() -> void:
	load("res://spacetime_bindings/schema/module_game_client.gd")
	quit()
