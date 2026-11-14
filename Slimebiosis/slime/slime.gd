extends Node2D

const POINT_COUNT := 16

@export_range(24.0, 100.0) var radius := 44.0
@export_range(0.5, 20.0) var total_mass := 4.0
@export_range(0.0, 1.0) var friction := 0.8:
	set(value):
		friction = value
		if contact_material != null:
			contact_material.friction = value
@export_range(0.0, 1.0) var bounce := 0.15
@export_range(100.0, 700.0) var shape_stiffness := 650.0
@export_range(4.0, 30.0) var shape_damping := 24.0
@export_flags_2d_physics var floor_mask := 1

var points: Array[RigidBody2D] = []
var rest_offsets: Array[Vector2] = []
var center := Vector2.ZERO
var velocity := Vector2.ZERO
var collider_radius: float
var contact_material: PhysicsMaterial
var angular_speed := 0.0

func _ready() -> void:
	collider_radius = radius * 0.22
	var circle := CircleShape2D.new()
	circle.radius = collider_radius
	contact_material = PhysicsMaterial.new()
	contact_material.friction = friction
	contact_material.rough = true
	contact_material.bounce = bounce

	for index in POINT_COUNT:
		var offset := Vector2.from_angle(TAU * index / POINT_COUNT) * radius
		rest_offsets.append(offset)
		var point := RigidBody2D.new()
		point.mass = total_mass / POINT_COUNT
		point.collision_layer = 2
		point.collision_mask = floor_mask
		point.physics_material_override = contact_material
		point.lock_rotation = true
		point.can_sleep = false
		point.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
		point.position = offset
		var collider := CollisionShape2D.new()
		collider.shape = circle
		point.add_child(collider)
		add_child(point)
		points.append(point)
	center = global_position

func _physics_process(delta: float) -> void:
	center = Vector2.ZERO
	velocity = Vector2.ZERO
	for point in points:
		center += point.global_position
		velocity += point.linear_velocity
	center /= POINT_COUNT
	velocity /= POINT_COUNT

	var angular_momentum := 0.0
	var inertia := 0.0
	for point in points:
		var offset := point.global_position - center
		angular_momentum += offset.cross(point.linear_velocity - velocity)
		inertia += offset.length_squared()
	angular_speed = angular_momentum / maxf(inertia, 1.0)

	# Fit the resting ring to the current rotation before restoring its shape.
	var alignment := Vector2.ZERO
	for index in POINT_COUNT:
		var offset := points[index].global_position - center
		alignment += Vector2(rest_offsets[index].dot(offset), rest_offsets[index].cross(offset))
	var rotation_angle := alignment.angle()

	for index in POINT_COUNT:
		var point := points[index]
		var target := center + rest_offsets[index].rotated(rotation_angle)
		var acceleration := (target - point.global_position) * shape_stiffness
		var offset := point.global_position - center
		var spin_velocity := Vector2(-offset.y, offset.x) * angular_speed
		acceleration -= (point.linear_velocity - velocity - spin_velocity) * shape_damping
		point.apply_central_force(acceleration * point.mass)
	_limit_rim_stretch(delta)
	queue_redraw()

func _limit_rim_stretch(delta: float) -> void:
	var max_length := rest_offsets[0].distance_to(rest_offsets[1]) * 1.04
	var predicted := PackedVector2Array()
	for point in points:
		predicted.append(point.global_position + point.linear_velocity * delta)

	# A slack link bends freely. A taut link pulls both neighbors equally.
	var constrained := predicted.duplicate()
	for iteration in 16:
		for index in POINT_COUNT:
			var next := (index + 1) % POINT_COUNT
			var edge := constrained[next] - constrained[index]
			var length := edge.length()
			if length > max_length:
				var correction := edge * (0.5 * (length - max_length) / length)
				constrained[index] += correction
				constrained[next] -= correction

	for index in POINT_COUNT:
		var point := points[index]
		var correction := constrained[index] - predicted[index]
		point.apply_central_impulse(correction * (point.mass / delta))

func steer(direction: float, speed: float) -> void:
	var grounded := _has_ground_contact()
	var rolling_radius := radius + collider_radius
	var target := direction * speed * 3.0 / rolling_radius
	var acceleration := clampf((target - angular_speed) * 7.0, -65.0, 65.0)
	if is_zero_approx(direction) or (grounded and velocity.x * direction >= speed * 3.0):
		# Rolling resistance scales with grip and fades near a stop.
		acceleration = -clampf(angular_speed * 4.0, -7.0, 7.0) * friction if grounded else 0.0
	for point in points:
		var offset := point.global_position - center
		var tangent := Vector2(-offset.y, offset.x)
		point.apply_central_force(tangent * acceleration * point.mass)

func _has_ground_contact() -> bool:
	for point in points:
		var start := point.global_position
		var query := PhysicsRayQueryParameters2D.create(
			start, start + Vector2.DOWN * (collider_radius + 2.0), floor_mask
		)
		var hit := get_world_2d().direct_space_state.intersect_ray(query)
		if not hit.is_empty() and hit.normal.dot(Vector2.UP) > 0.45:
			return true
	return false

func jump(speed: float) -> bool:
	if not _has_ground_contact():
		return false
	for point in points:
		point.apply_central_impulse(Vector2.UP * speed * point.mass)
	return true

func _draw() -> void:
	if points.is_empty():
		return
	var outline := PackedVector2Array()
	for point in points:
		outline.append(point.position)
	var expanded := Geometry2D.offset_polygon(outline, collider_radius - 1.5, Geometry2D.JOIN_ROUND)
	if expanded.size() == 1 and not Geometry2D.triangulate_polygon(expanded[0]).is_empty():
		outline = expanded[0]
	if Geometry2D.triangulate_polygon(outline).is_empty():
		return
	draw_colored_polygon(outline, Color("#77dc9d"))
	var face := to_local(center)
	for eye_x in [-12.0, 12.0]:
		var eye := face + Vector2(eye_x, -5.0)
		draw_circle(eye, 6.0, Color("#f5fff5"), true, -1.0, true)
		draw_circle(eye + Vector2(1.0, 0.5), 3.0, Color("#194836"), true, -1.0, true)








