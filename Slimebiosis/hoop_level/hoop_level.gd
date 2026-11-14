extends Node2D
## Sketch greybox. Read the simulated centers/hulls: the slimes' Node2D origins
## stay at their spawn positions and aren't suitable for Area2D body tracking.

@export var button_bounds: Rect2 = Rect2(414, 1204, 380, 60)
@export var hoop_left: float = 1100.0
@export var hoop_right: float = 1216.0
@export var hoop_height: float = 800.0

const MUSHROOM = preload("res://hoop_level/placeholder_mushroom.gd")

@onready var players: Array[VerletSlime] = [$Player, $Companion]
@onready var doors: Array[StaticBody2D] = [$Doors/ExitDoor]
@onready var status: Label = $HUD/Panel/Instructions

var upgrade_spawned: bool = false
var doors_open: bool = false
var _previous_centers: Array[Vector2] = []
var _camera: Camera2D


func _ready() -> void:
	# Run after both soft bodies have integrated this frame.
	process_physics_priority = 10
	for player in players:
		_previous_centers.append(player.get_center())
	_camera = $Camera2D
	get_viewport().size_changed.connect(_fit_camera)
	_fit_camera()


func _fit_camera() -> void:
	var viewport_size: Vector2 = get_viewport_rect().size
	var fit: float = minf(viewport_size.x / 1510.0, viewport_size.y / 1390.0)
	_camera.zoom = Vector2.ONE * fit


func _physics_process(delta: float) -> void:
	var button_weight: float = 0.0
	for index in players.size():
		var player: VerletSlime = players[index]
		var center: Vector2 = player.get_center()
		if _stands_on_button(player):
			# In 2D, body area is proportional to radius squared.
			button_weight += pow(player.radius / 48.0, 2.0)
			if not upgrade_spawned:
				_spawn_upgrade()
		if not doors_open and _crossed_hoop(_previous_centers[index], center):
			_open_doors()
		_previous_centers[index] = center
	$UpgradeButton.apply_weight(button_weight, delta)


func _stands_on_button(player: VerletSlime) -> bool:
	var center: Vector2 = player.get_center()
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var shape: ConvexPolygonShape2D = player.solid_outline.shape as ConvexPolygonShape2D
	for point in shape.points:
		var world_point: Vector2 = player.solid_outline.to_global(point)
		if world_point.y <= center.y:
			continue
		# The solver leaves a small gap above solid surfaces. Probe down from
		# the lower outline and require support from the button's upward face.
		var query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(
			world_point, world_point + Vector2.DOWN * 8.0,
			player.terrain_mask, [player.solid_body.get_rid()])
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty() and hit.collider == $UpgradeButton and hit.normal.y < -0.5:
			return true
	return false


func _crossed_hoop(previous: Vector2, current: Vector2) -> bool:
	# Sweep across the rim plane, so a fast-moving thrown slime can't skip it.
	var travel: float = current.y - previous.y
	if is_zero_approx(travel):
		return false
	var fraction: float = (hoop_height - previous.y) / travel
	if fraction <= 0.0 or fraction > 1.0:
		return false
	var crossing_x: float = lerpf(previous.x, current.x, fraction)
	return crossing_x > hoop_left + 8.0 and crossing_x < hoop_right - 8.0


func _spawn_upgrade() -> void:
	upgrade_spawned = true
	var mushroom: Node2D = Node2D.new()
	mushroom.name = "PlaceholderMushroom"
	mushroom.set_script(MUSHROOM)
	mushroom.position = Vector2(button_bounds.get_center().x, button_bounds.position.y - 110.0)
	mushroom.z_index = 2
	$UpgradeSpawn.add_child(mushroom)
	_update_status()


func _open_doors() -> void:
	doors_open = true
	for door in doors:
		door.set_deferred("collision_layer", 0)
		door.set_deferred("collision_mask", 0)
		door.get_node("Collision").set_deferred("disabled", true)
		var tween: Tween = create_tween()
		tween.tween_property(door.get_node("Visual"), "modulate:a", 0.12, 0.35)
	_update_status()


func _update_status() -> void:
	status.text = "A / D: roll   Space: jump   W: stiffen   E: grab / throw\nLeft / Right: companion   Enter: jump   Up: stiffen   R: reset\nGold quarter: grab area   Arrow: throw direction\nUpgrade: %s   |   Doors: %s" % [
		"spawned (placeholder only)" if upgrade_spawned else "stand on the red button",
		"OPEN" if doors_open else "pass either slime through the hoop",
	]


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_R:
		get_tree().reload_current_scene()
