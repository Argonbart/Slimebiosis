class_name Slime
extends Node2D
## Simulates and draws a deformable slime driven by a ring of rigid bodies.


const POINT_COUNT: int = 16


@export_category("Components")
@export var controls: SlimeControls = null

@export_category("Data")

@export_range(24.0, 100.0) var radius: float = 44.0:
	set(value):
		radius = value
		if _circle != null:
			_update_size.call_deferred()
@export_range(0.5, 20.0) var total_mass: float = 4.0
@export_range(0.0, 1.0) var friction: float = 0.8:
	set(value):
		friction = value
		if _contact_material != null:
			_contact_material.friction = value
@export_range(0.0, 1.0) var bounce: float = 0.15
@export_range(100.0, 700.0) var shape_stiffness: float = 650.0
@export_range(4.0, 30.0) var shape_damping: float = 24.0
@export_flags_2d_physics var floor_mask: int = 1

var _points: Array[RigidBody2D] = []
var _rest_offsets: Array[Vector2] = []
var _center: Vector2 = Vector2.ZERO
var _velocity: Vector2 = Vector2.ZERO
var _circle: CircleShape2D = null
var _collider_radius: float = 0.0
var _contact_material: PhysicsMaterial = null
var _angular_speed: float = 0.0


# -------------------------------- GODOT FUNCTIONS ----------------------------------------


func _ready() -> void:
	_collider_radius = radius * 0.22
	_circle = CircleShape2D.new()
	_circle.radius = _collider_radius
	_contact_material = PhysicsMaterial.new()
	_contact_material.friction = friction
	_contact_material.rough = true
	_contact_material.bounce = bounce
	
	for index: int in POINT_COUNT:
		var offset: Vector2 = Vector2.from_angle(TAU * index / POINT_COUNT) * radius
		_rest_offsets.append(offset)
		var point: RigidBody2D = RigidBody2D.new()
		point.mass = total_mass / POINT_COUNT
		point.collision_layer = 2
		point.collision_mask = floor_mask
		point.physics_material_override = _contact_material
		point.lock_rotation = true
		point.can_sleep = false
		point.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
		point.position = offset
		var collider: CollisionShape2D = CollisionShape2D.new()
		collider.shape = _circle
		point.add_child(collider)
		add_child(point)
		_points.append(point)
	_center = global_position


func _physics_process(delta: float) -> void:
	_update_motion()
	_restore_shape()
	_limit_rim_stretch(delta)
	queue_redraw()


func _draw() -> void:
	if _points.is_empty():
		return
	var outline: PackedVector2Array = PackedVector2Array()
	for point: RigidBody2D in _points:
		outline.append(point.position)
	var expanded: Array[PackedVector2Array] = Geometry2D.offset_polygon(outline, _collider_radius - 1.5, Geometry2D.JOIN_ROUND)
	if expanded.size() == 1 and not Geometry2D.triangulate_polygon(expanded[0]).is_empty():
		outline = expanded[0]
	if Geometry2D.triangulate_polygon(outline).is_empty():
		return
	draw_colored_polygon(outline, Color("#77dc9d"))
	var face: Vector2 = to_local(_center)
	for eye_x: float in [-12.0, 12.0]:
		var eye: Vector2 = face + Vector2(eye_x, -5.0)
		draw_circle(eye, 6.0, Color("#f5fff5"), true, -1.0, true)
		draw_circle(eye + Vector2(1.0, 0.5), 3.0, Color("#194836"), true, -1.0, true)


# -------------------------------- LOCAL FUNCTIONS ----------------------------------------


func _update_size() -> void:
	_collider_radius = radius * 0.22
	_circle.radius = _collider_radius
	for index: int in POINT_COUNT:
		_rest_offsets[index] = Vector2.from_angle(TAU * index / POINT_COUNT) * radius


func _update_motion() -> void:
	_center = Vector2.ZERO
	_velocity = Vector2.ZERO
	for point: RigidBody2D in _points:
		_center += point.global_position
		_velocity += point.linear_velocity
	_center /= POINT_COUNT
	_velocity /= POINT_COUNT
	
	var angular_momentum: float = 0.0
	var inertia: float = 0.0
	for point: RigidBody2D in _points:
		var offset: Vector2 = point.global_position - _center
		angular_momentum += offset.cross(point.linear_velocity - _velocity)
		inertia += offset.length_squared()
	_angular_speed = angular_momentum / maxf(inertia, 1.0)


func _restore_shape() -> void:
	# Fit the resting ring to the current rotation before restoring its shape.
	var alignment: Vector2 = Vector2.ZERO
	for index: int in POINT_COUNT:
		var offset: Vector2 = _points[index].global_position - _center
		alignment += Vector2(_rest_offsets[index].dot(offset), _rest_offsets[index].cross(offset))
	var rotation_angle: float = alignment.angle()
	
	for index: int in POINT_COUNT:
		var point: RigidBody2D = _points[index]
		var target: Vector2 = _center + _rest_offsets[index].rotated(rotation_angle)
		var acceleration: Vector2 = (target - point.global_position) * shape_stiffness
		var offset: Vector2 = point.global_position - _center
		var spin_velocity: Vector2 = Vector2(-offset.y, offset.x) * _angular_speed
		acceleration -= (point.linear_velocity - _velocity - spin_velocity) * shape_damping
		point.apply_central_force(acceleration * point.mass)


func _limit_rim_stretch(delta: float) -> void:
	var max_length: float = _rest_offsets[0].distance_to(_rest_offsets[1]) * 1.04
	var predicted: PackedVector2Array = PackedVector2Array()
	for point: RigidBody2D in _points:
		predicted.append(point.global_position + point.linear_velocity * delta)
	
	# A slack link bends freely. A taut link pulls both neighbors equally.
	var constrained: PackedVector2Array = predicted.duplicate()
	for iteration: int in 16:
		for index: int in POINT_COUNT:
			var next: int = (index + 1) % POINT_COUNT
			var edge: Vector2 = constrained[next] - constrained[index]
			var length: float = edge.length()
			if length > max_length:
				var correction: Vector2 = edge * (0.5 * (length - max_length) / length)
				constrained[index] += correction
				constrained[next] -= correction
	
	for index: int in POINT_COUNT:
		var point: RigidBody2D = _points[index]
		var correction: Vector2 = constrained[index] - predicted[index]
		point.apply_central_impulse(correction * (point.mass / delta))


func _has_ground_contact() -> bool:
	for point: RigidBody2D in _points:
		var start: Vector2 = point.global_position
		var query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(start, start + Vector2.DOWN * (_collider_radius + 2.0), floor_mask)
		var hit: Dictionary = get_world_2d().direct_space_state.intersect_ray(query)
		if not hit.is_empty() and hit.normal.dot(Vector2.UP) > 0.45:
			return true
	return false


# -------------------------------- EXTERNAL FUNCTIONS ----------------------------------------


func steer(direction: float, speed: float) -> void:
	var grounded: bool = _has_ground_contact()
	var rolling_radius: float = radius + _collider_radius
	var target: float = direction * speed * 3.0 / rolling_radius
	var acceleration: float = clampf((target - _angular_speed) * 7.0, -65.0, 65.0)
	if is_zero_approx(direction) or (grounded and _velocity.x * direction >= speed * 3.0):
		# Rolling resistance scales with grip and fades near a stop.
		acceleration = -clampf(_angular_speed * 4.0, -7.0, 7.0) * friction if grounded else 0.0
	for point: RigidBody2D in _points:
		var offset: Vector2 = point.global_position - _center
		var tangent: Vector2 = Vector2(-offset.y, offset.x)
		point.apply_central_force(tangent * acceleration * point.mass)


func jump(speed: float) -> bool:
	if not _has_ground_contact():
		return false
	for point: RigidBody2D in _points:
		point.apply_central_impulse(Vector2.UP * speed * point.mass)
	return true


func get_center() -> Vector2:
	return _center


