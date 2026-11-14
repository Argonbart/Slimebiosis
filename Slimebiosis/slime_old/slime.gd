class_name Slime
extends Node2D
## A deformable slime. The local player's slime is simulated as a ring of rigid
## bodies; other players' slimes (`simulated = false`) run no physics and are
## drawn from the shape their owner sends.
##
## The node's position is always the slime's centre.


const POINT_COUNT: int = 16
## Half of the look sector (the face) a slime grabs with. Mirrors LOOK_HALF_ANGLE on the server.
const LOOK_HALF_ANGLE: float = PI / 4.0
## Rim offsets are sent as signed bytes covering +-(radius * SHAPE_RANGE).
const SHAPE_RANGE: float = 2.0
## Mass of a carried captive's lump as a share of the captive's own mass.
const LUMP_MASS_SHARE: float = 0.5

## Emitted when another slime picks this one up.
signal hold_started
## Emitted when a hold on this slime ends (thrown, broke free, holder left).
signal launched(pos: Vector2, vel: Vector2)

## All networked slimes in the scene by identity hex.
static var registry: Dictionary[String, Slime] = {}

@export_category("Data")

@export_range(24.0, 100.0) var radius: float = 44.0:
	set(value):
		radius = value
		if is_node_ready():
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
@export var color: Color = Color("#77dc9d")

## false: no physics bodies; position, angle and shape are set from outside.
## Set before the slime enters the tree.
var simulated: bool = true
## Draw the look sector on the rim (the local player's slime).
var show_sector: bool = false

## Centre velocity, body rotation (the look direction) and angular speed.
var velocity: Vector2 = Vector2.ZERO
var angle: float = 0.0
var spin: float = 0.0
## Per-slime parameters from the server's slime_stats row.
var move_speed: float = 500.0
var jump_speed: float = 400.0

## Identity of the owning player; empty while offline.
var net_identity: PackedByteArray = PackedByteArray()
var net_id: String = ""
## Identity hex of the slime holding this one / held by this one, or "".
var held_by_id: String = ""
var holding_id: String = ""
## Where this slime sticks on its holder, in the holder's body frame.
var hold_angle: float = 0.0
## Shown above the slime; empty hides the label.
var display_name: String = "":
	set(value):
		display_name = value
		_update_label()

var _points: Array[RigidBody2D] = []
var _rest_offsets: Array[Vector2] = []
## Rim points relative to the centre, in the body frame (rotated back by `angle`).
var _rim: PackedVector2Array = PackedVector2Array()
var _center: Vector2 = Vector2.ZERO
var _circle: CircleShape2D = null
var _collider_radius: float = 0.0
var _contact_material: PhysicsMaterial = null
var _frozen: bool = false
var _lump: RigidBody2D = null
var _launch_seq: int = -1 # -1: no server state seen yet
var _label: Label = null


# -------------------------------- GODOT FUNCTIONS ----------------------------------------


func _ready() -> void:
	_collider_radius = radius * 0.22
	for index: int in POINT_COUNT:
		_rest_offsets.append(Vector2.from_angle(TAU * index / POINT_COUNT) * radius)
	_rim = PackedVector2Array(_rest_offsets)
	_center = global_position
	_update_label()
	if not simulated:
		return

	_circle = CircleShape2D.new()
	_circle.radius = _collider_radius
	_contact_material = PhysicsMaterial.new()
	_contact_material.friction = friction
	_contact_material.rough = true
	_contact_material.bounce = bounce

	_build_points(Vector2.ZERO)


func _exit_tree() -> void:
	if registry.get(net_id) == self:
		registry.erase(net_id)


func _physics_process(delta: float) -> void:
	if is_held():
		_follow_holder()
	elif simulated:
		_update_motion()
		_restore_shape()
		_limit_rim_stretch(delta)
		_carry_lump()
		global_position = _center
	queue_redraw()


func _draw() -> void:
	var outline: PackedVector2Array = PackedVector2Array()
	for offset: Vector2 in _rim:
		outline.append(offset.rotated(angle))
	var skin: float = radius * 0.22 - 1.5
	var expanded: Array[PackedVector2Array] = Geometry2D.offset_polygon(outline, skin, Geometry2D.JOIN_ROUND)
	if expanded.size() == 1 and not Geometry2D.triangulate_polygon(expanded[0]).is_empty():
		outline = expanded[0]
	if Geometry2D.triangulate_polygon(outline).is_empty():
		return
	draw_colored_polygon(outline, color)
	if show_sector:
		draw_arc(Vector2.ZERO, radius * 1.22 + 6.0, angle - LOOK_HALF_ANGLE, angle + LOOK_HALF_ANGLE, 12, Color(1, 1, 1, 0.3), 2.0, true)
	# The face sits at the look direction and turns with the body.
	var look: Vector2 = Vector2.from_angle(angle)
	var side: Vector2 = look.orthogonal()
	var face: Vector2 = look * radius * 0.5
	var scale_factor: float = radius / 40.0
	for eye_side: float in [-1.0, 1.0]:
		var eye: Vector2 = face + side * eye_side * 12.0 * scale_factor
		draw_circle(eye, 6.0 * scale_factor, Color("#f5fff5"), true, -1.0, true)
		draw_circle(eye + look * 1.5 * scale_factor, 3.0 * scale_factor, color.darkened(0.7), true, -1.0, true)


# -------------------------------- LOCAL FUNCTIONS ----------------------------------------


## Creates the ring's rigid bodies in the resting shape around the centre.
func _build_points(start_velocity: Vector2) -> void:
	for point: RigidBody2D in _points:
		point.queue_free()
	_points.clear()
	for index: int in POINT_COUNT:
		var point: RigidBody2D = RigidBody2D.new()
		point.top_level = true # moves on its own; this node follows the centre
		point.mass = total_mass / POINT_COUNT
		point.collision_layer = 0 if _frozen else 2
		point.collision_mask = 0 if _frozen else floor_mask
		point.physics_material_override = _contact_material
		point.lock_rotation = true
		point.can_sleep = false
		point.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
		point.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
		point.freeze = _frozen
		point.position = _center + _rest_offsets[index].rotated(angle)
		point.linear_velocity = start_velocity
		var collider: CollisionShape2D = CollisionShape2D.new()
		collider.shape = _circle
		point.add_child(collider)
		add_child(point)
		_points.append(point)


func _update_size() -> void:
	_collider_radius = radius * 0.22
	if _circle != null:
		_circle.radius = _collider_radius
	for index: int in POINT_COUNT:
		_rest_offsets[index] = Vector2.from_angle(TAU * index / POINT_COUNT) * radius
	if not simulated or _frozen:
		_rim = PackedVector2Array(_rest_offsets)


func _update_motion() -> void:
	_center = Vector2.ZERO
	velocity = Vector2.ZERO
	for point: RigidBody2D in _points:
		_center += point.global_position
		velocity += point.linear_velocity
	_center /= POINT_COUNT
	velocity /= POINT_COUNT

	var angular_momentum: float = 0.0
	var inertia: float = 0.0
	for point: RigidBody2D in _points:
		var offset: Vector2 = point.global_position - _center
		angular_momentum += offset.cross(point.linear_velocity - velocity)
		inertia += offset.length_squared()
	spin = angular_momentum / maxf(inertia, 1.0)


func _restore_shape() -> void:
	# Fit the resting ring to the current rotation before restoring its shape.
	var alignment: Vector2 = Vector2.ZERO
	for index: int in POINT_COUNT:
		var offset: Vector2 = _points[index].global_position - _center
		alignment += Vector2(_rest_offsets[index].dot(offset), _rest_offsets[index].cross(offset))
	angle = alignment.angle()

	for index: int in POINT_COUNT:
		var point: RigidBody2D = _points[index]
		var target: Vector2 = _center + _rest_offsets[index].rotated(angle)
		var acceleration: Vector2 = (target - point.global_position) * shape_stiffness
		var offset: Vector2 = point.global_position - _center
		var spin_velocity: Vector2 = Vector2(-offset.y, offset.x) * spin
		acceleration -= (point.linear_velocity - velocity - spin_velocity) * shape_damping
		point.apply_central_force(acceleration * point.mass)
		_rim[index] = offset.rotated(-angle)


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


## While held, the slime sits on its holder's rim in its resting shape.
func _follow_holder() -> void:
	var holder: Slime = registry.get(held_by_id)
	if holder == null:
		return
	_center = holder.hold_point(self)
	angle = holder.angle + hold_angle
	velocity = Vector2.ZERO
	spin = 0.0
	global_position = _center
	_rim = PackedVector2Array(_rest_offsets)
	for index: int in _points.size():
		_points[index].global_position = _center + _rest_offsets[index].rotated(angle)


## Keeps the carried captive's lump pinned to the rim. The lump collides with
## the level, so a big captive is a stone in the way and a small one a bump.
func _carry_lump() -> void:
	var captive: Slime = registry.get(holding_id)
	if captive == null:
		_drop_lump()
		return
	var arm: Vector2 = Vector2.from_angle(angle + captive.hold_angle) * hold_distance(captive)
	if _lump == null:
		_lump = RigidBody2D.new()
		_lump.top_level = true
		_lump.mass = captive.total_mass * LUMP_MASS_SHARE
		_lump.collision_layer = 2
		_lump.collision_mask = floor_mask
		_lump.physics_material_override = _contact_material
		_lump.lock_rotation = true
		_lump.can_sleep = false
		_lump.position = _center + arm
		_lump.linear_velocity = velocity
		var shape: CircleShape2D = CircleShape2D.new()
		shape.radius = captive.radius
		var collider: CollisionShape2D = CollisionShape2D.new()
		collider.shape = shape
		_lump.add_child(collider)
		add_child(_lump)
		return
	# Spring toward the rim point, damped against the ring's own motion there.
	var rim_velocity: Vector2 = velocity + Vector2(-arm.y, arm.x) * spin
	var force: Vector2 = ((_center + arm - _lump.global_position) * shape_stiffness \
		- (_lump.linear_velocity - rim_velocity) * shape_damping) * _lump.mass
	_lump.apply_central_force(force)
	# Equal and opposite on the ring: a push on the centre plus a torque.
	var inertia: float = 0.0
	for point: RigidBody2D in _points:
		inertia += (point.global_position - _center).length_squared()
	var twist: float = (_lump.global_position - _center).cross(-force) / maxf(inertia, 1.0)
	for point: RigidBody2D in _points:
		var offset: Vector2 = point.global_position - _center
		point.apply_central_force(-force / POINT_COUNT + Vector2(-offset.y, offset.x) * twist)


func _drop_lump() -> void:
	if _lump != null:
		_lump.queue_free()
		_lump = null


func _set_frozen(value: bool) -> void:
	if _frozen == value:
		return
	_frozen = value
	for point: RigidBody2D in _points:
		point.freeze = value
		point.collision_layer = 0 if value else 2
		point.collision_mask = 0 if value else floor_mask


func _update_label() -> void:
	if _label == null:
		if display_name.is_empty() or not is_inside_tree():
			return
		_label = Label.new()
		_label.add_theme_font_size_override("font_size", 14)
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.size = Vector2(200, 20)
		add_child(_label)
	_label.position = Vector2(-100, -radius * 1.22 - 30.0)
	_label.text = display_name


# -------------------------------- EXTERNAL FUNCTIONS ----------------------------------------


func steer(direction: float, speed: float) -> void:
	var grounded: bool = _has_ground_contact()
	var rolling_radius: float = radius + _collider_radius
	var target: float = direction * speed * 3.0 / rolling_radius
	var acceleration: float = clampf((target - spin) * 7.0, -65.0, 65.0)
	if is_zero_approx(direction) or (grounded and velocity.x * direction >= speed * 3.0):
		# Rolling resistance scales with grip and fades near a stop.
		acceleration = -clampf(spin * 4.0, -7.0, 7.0) * friction if grounded else 0.0
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


## Moves the whole slime to `center` in its resting shape, moving at `new_velocity`.
func teleport(center: Vector2, new_velocity: Vector2 = Vector2.ZERO) -> void:
	_center = center
	velocity = new_velocity
	spin = 0.0
	global_position = center
	_rim = PackedVector2Array(_rest_offsets)
	if simulated:
		# New bodies instead of moved ones: a moved body with continuous
		# collision sweeps from its old place and stops at anything in between.
		_build_points(new_velocity)
	_drop_lump() # rebuilt at the new place on the next physics frame


## Centre-to-centre distance at which `captive` sticks to this slime's rim.
## Mirrors hold_distance() on the server.
func hold_distance(captive: Slime) -> float:
	return radius + captive.radius


## Where `captive` sits while this slime holds it.
func hold_point(captive: Slime) -> Vector2:
	if _lump != null:
		return _lump.global_position
	return global_position + Vector2.from_angle(angle + captive.hold_angle) * hold_distance(captive)


## The rim as 2 signed bytes per point, in the body frame. Mirrors SHAPE_BYTES on the server.
func pack_shape() -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(POINT_COUNT * 2)
	var unit: float = 127.0 / (radius * SHAPE_RANGE)
	for index: int in POINT_COUNT:
		bytes.encode_s8(index * 2, clampi(roundi(_rim[index].x * unit), -127, 127))
		bytes.encode_s8(index * 2 + 1, clampi(roundi(_rim[index].y * unit), -127, 127))
	return bytes


## Decodes pack_shape() output; an invalid array gives the resting ring.
func unpack_shape(bytes: PackedByteArray) -> PackedVector2Array:
	if bytes.size() != POINT_COUNT * 2:
		return PackedVector2Array(_rest_offsets)
	var rim: PackedVector2Array = PackedVector2Array()
	var unit: float = radius * SHAPE_RANGE / 127.0
	for index: int in POINT_COUNT:
		rim.append(Vector2(bytes.decode_s8(index * 2), bytes.decode_s8(index * 2 + 1)) * unit)
	return rim


## The resting ring in the body frame.
func rest_shape() -> PackedVector2Array:
	return PackedVector2Array(_rest_offsets)


## Sets the drawn rim of a slime that is not simulated here.
func apply_shape(rim: PackedVector2Array) -> void:
	if rim.size() == POINT_COUNT:
		_rim = rim


func set_identity(identity: PackedByteArray) -> void:
	registry.erase(net_id)
	net_identity = identity
	net_id = identity.hex_encode()
	registry[net_id] = self


func is_held() -> bool:
	return held_by_id != ""


## Applies the server-owned interaction row and emits hold_started / launched on changes.
func apply_state(row: GameSlimeState) -> void:
	var new_held: String = (row.held_by.unwrap() as PackedByteArray).hex_encode() if row.held_by.is_some() else ""
	holding_id = (row.holding.unwrap() as PackedByteArray).hex_encode() if row.holding.is_some() else ""
	hold_angle = row.hold_angle
	var launched_now: bool = _launch_seq >= 0 and row.launch_seq != _launch_seq
	_launch_seq = row.launch_seq
	var started: bool = new_held != "" and new_held != held_by_id
	held_by_id = new_held
	_set_frozen(is_held())
	if started:
		hold_started.emit()
	if launched_now:
		launched.emit(row.launch_pos, row.launch_vel)


## Applies the server-owned physics parameters.
func apply_stats(row: GameSlimeStats) -> void:
	if not is_equal_approx(radius, row.radius):
		radius = row.radius
	friction = row.friction
	move_speed = row.move_speed
	jump_speed = row.jump_speed
	_update_label()


## Forget all server state, e.g. when the connection drops.
func clear_state() -> void:
	held_by_id = ""
	holding_id = ""
	_launch_seq = -1
	_set_frozen(false)
