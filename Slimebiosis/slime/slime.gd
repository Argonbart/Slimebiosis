class_name VerletSlime
extends Node2D
## Simulates a soft ring using Verlet integration and an enclosed-area constraint.
##
## The local player's slime is simulated here. Other players' slimes
## (`simulated = false`) run no physics and take the pose their owner sends.


const SOLVER_PASSES: int = 8
## Rim points in the network shape. Mirrors SHAPE_BYTES / 2 on the server.
const SHAPE_POINTS: int = 32
## Rim offsets are sent as signed bytes covering +-(radius * SHAPE_RANGE).
const SHAPE_RANGE: float = 2.0
## Half of the look sector (the face) a slime grabs with. Mirrors LOOK_HALF_ANGLE on the server.
const LOOK_HALF_ANGLE: float = PI / 4.0

## Emitted when another player's slime picks this one up.
signal hold_started
## Emitted when a networked hold on this slime ends (thrown, broke free, holder left).
signal launched(pos: Vector2, vel: Vector2)

## All networked slimes in the scene by identity hex.
static var registry: Dictionary[String, VerletSlime] = {}

@export_category("Components")
@export var solid_body: StaticBody2D = null
@export var solid_outline: CollisionShape2D = null

@export_category("Settings")
@export var body_color: Color = Color("#65d7bf")
## false: no physics; the pose is set from outside with set_pose().
@export var simulated: bool = true
## Keeps the node itself on the ring's centre, so children (camera, label) follow.
@export var follow_center: bool = false
## Draws eyes at the look direction.
@export var show_face: bool = false

@export_category("Data")
@export_range(8, 64) var point_count: int = 32:
	set(value):
		var count: int = clampi(value, 8, 64)
		if count == point_count:
			return
		point_count = count
		if not _points.is_empty():
			_resample_ring()
@export var drive_acceleration: float = 5000.0
@export_range(12.0, 100.0) var radius: float = 100.0:
	set(value):
		var ratio: float = value / radius
		radius = value
		_rest_edge *= ratio
		_rest_area *= ratio * ratio
@export_range(0.0, 1.0) var edge_strength: float = 0.5
@export_range(0.01, 5000.0) var edge_boost_multiplier: float = 50.0
@export_flags_2d_physics var terrain_mask: int = 1
## Upward speed of a jump.
@export var jump_strength: float = 400.0
## Only matters between slimes: a heavy captive slows its carrier (and is thrown less far by the server).
@export var weight: float = 1.0
## Synced for display; the server applies it when this slime throws.
@export var throw_strength: float = 780.0

## Draw the look sector on the rim (the local player's slime).
var show_sector: bool = false
## Centre velocity, body rotation (the look direction) and angular speed.
var velocity: Vector2 = Vector2.ZERO
var angle: float = 0.0
var spin: float = 0.0

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

var _launch_seq: int = -1 # -1: no server state seen yet
var _label: Label = null
var _held_slime: VerletSlime = null
var _grab_offsets: PackedVector2Array = PackedVector2Array()
var _holder: VerletSlime = null
var _move_direction: float = 0.0
var _boosting: bool = false
var _excluded_bodies: Array[RID] = []
var _points: PackedVector2Array = PackedVector2Array()
var _previous: PackedVector2Array = PackedVector2Array()
var _clear_positions: PackedVector2Array = PackedVector2Array()
var _sweep_starts: PackedVector2Array = PackedVector2Array()
var _rest_area: float = 0.0
var _rest_edge: float = 0.0


# -------------------------------- GODOT FUNCTIONS ----------------------------------------


func _ready() -> void:
	if solid_body != null:
		add_to_group("solid_slimes")
		_excluded_bodies.append(solid_body.get_rid())
		solid_outline.shape = ConvexPolygonShape2D.new()
	
	for index: int in point_count:
		_points.append(global_position + Vector2.from_angle(TAU * index / point_count) * radius)
	_previous = _points.duplicate()
	_clear_positions = _points.duplicate()
	_rest_area = _signed_area()
	_rest_edge = _points[0].distance_to(_points[1])
	_update_solid_outline()
	_update_label()


func _exit_tree() -> void:
	if registry.get(net_id) == self:
		registry.erase(net_id)


func _physics_process(delta: float) -> void:
	_resolve_partners()
	if is_held():
		return # the holder carries this slime
	if simulated:
		_simulate(delta)
		_measure_motion(delta)
	if is_instance_valid(_held_slime):
		if not net_id.is_empty():
			_held_slime._stick_to(self)
		_held_slime._carry_with(get_center(), angle)
	_sync_node()


func _simulate(delta: float) -> void:
	_update_collision_exclusions()

	_apply_contact_drive(_move_direction, delta)
	_sweep_starts = _points.duplicate()
	_integrate(delta)
	var strength: float = edge_strength
	var boosting: bool = _boosting
	if boosting:
		strength *= edge_boost_multiplier
	var edge_passes: int = maxi(1, ceili(strength))
	_solve_terrain()
	for _pass: int in SOLVER_PASSES:
		_sweep_starts = _points.duplicate()
		for _edge_pass: int in edge_passes:
			_solve_edges(strength / edge_passes)
		_solve_area()
		_solve_terrain()
	_sweep_starts.clear()


func _draw() -> void:
	var outline: PackedVector2Array = PackedVector2Array()
	for point: Vector2 in _points:
		outline.append(to_local(point))
	if Geometry2D.triangulate_polygon(outline).is_empty():
		outline = _open_hull(outline)
	if outline.size() >= 3:
		draw_colored_polygon(outline, body_color)
	
	var center: Vector2 = to_local(get_center())
	if show_sector:
		draw_arc(center, radius + 8.0, angle - LOOK_HALF_ANGLE, angle + LOOK_HALF_ANGLE, 12, Color(1, 1, 1, 0.3), 2.0, true)
	if show_face:
		# The face sits at the look direction and turns with the body.
		var look: Vector2 = Vector2.from_angle(angle)
		var side: Vector2 = look.orthogonal()
		var face: Vector2 = center + look * radius * 0.5
		var scale_factor: float = radius / 40.0
		for eye_side: float in [-1.0, 1.0]:
			var eye: Vector2 = face + side * eye_side * 12.0 * scale_factor
			draw_circle(eye, 6.0 * scale_factor, Color("#f5fff5"), true, -1.0, true)
			draw_circle(eye + look * 1.5 * scale_factor, 3.0 * scale_factor, body_color.darkened(0.7), true, -1.0, true)


# -------------------------------- LOCAL FUNCTIONS ----------------------------------------


## Networked slimes find their hold partners by identity; offline grabs set them directly.
func _resolve_partners() -> void:
	if net_id.is_empty():
		return
	_holder = registry.get(held_by_id)
	_held_slime = registry.get(holding_id)


## Updates velocity, angle and spin from the last simulation step.
func _measure_motion(delta: float) -> void:
	var center: Vector2 = get_center()
	var travel: Vector2 = Vector2.ZERO
	for index: int in point_count:
		travel += _points[index] - _previous[index]
	velocity = travel / (point_count * delta)
	var angular_momentum: float = 0.0
	var inertia: float = 0.0
	for index: int in point_count:
		var offset: Vector2 = _points[index] - center
		angular_momentum += offset.cross((_points[index] - _previous[index]) / delta - velocity)
		inertia += offset.length_squared()
	spin = angular_momentum / maxf(inertia, 1.0)
	angle = _ring_angle(center)


## Brings the node, the solid outline and the drawing in line with the ring.
func _sync_node() -> void:
	if follow_center:
		global_position = get_center()
	_update_solid_outline()
	queue_redraw()


## Sets the grab offsets of a networked captive: resting on the holder's rim at hold_angle.
func _stick_to(holder: VerletSlime) -> void:
	var arm: Vector2 = Vector2.from_angle(hold_angle) * holder.hold_distance(self)
	_grab_offsets.resize(point_count)
	for index: int in point_count:
		_grab_offsets[index] = arm + Vector2.from_angle(hold_angle + TAU * index / point_count) * radius


## How much of its drive and jump a slime keeps while carrying another one.
func _carry_factor() -> float:
	if not is_instance_valid(_held_slime):
		return 1.0
	return weight / maxf(weight + _held_slime.weight, 0.001)


func _has_ground_contact() -> bool:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	for index: int in point_count:
		var outward: Vector2 = _area_gradient(index).normalized()
		if outward.is_zero_approx():
			continue
		var point: Vector2 = _points[index]
		var query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(point, point + outward * 5.0, terrain_mask, _excluded_bodies)
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty() and (hit.normal as Vector2).dot(Vector2.UP) > 0.45:
			return true
	return false


func _resampled(points: PackedVector2Array, count: int) -> PackedVector2Array:
	var old_count: int = points.size()
	if old_count == count:
		return points
	var result: PackedVector2Array = PackedVector2Array()
	for index: int in count:
		var sample: float = float(index * old_count) / count
		var first: int = floori(sample)
		result.append(points[first].lerp(points[(first + 1) % old_count], sample - first))
	return result


func _update_label() -> void:
	if _label == null:
		if display_name.is_empty() or not is_inside_tree():
			return
		_label = Label.new()
		_label.add_theme_font_size_override("font_size", 14)
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.size = Vector2(200, 20)
		add_child(_label)
	_label.position = Vector2(-100, -radius - 40.0)
	_label.text = display_name


func _update_solid_outline() -> void:
	if solid_outline == null:
		return
	var outline: PackedVector2Array = PackedVector2Array()
	for point: Vector2 in _points:
		outline.append(solid_outline.to_local(point))
	var hull: PackedVector2Array = _open_hull(outline)
	if hull.size() >= 3:
		var convex: ConvexPolygonShape2D = solid_outline.shape as ConvexPolygonShape2D
		convex.points = hull
	


func _open_hull(outline: PackedVector2Array) -> PackedVector2Array:
	var hull: PackedVector2Array = Geometry2D.convex_hull(outline)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
		hull.resize(hull.size() - 1)
	return hull


func _resample_ring() -> void:
	var old_count: int = _points.size()
	var points: PackedVector2Array = PackedVector2Array()
	var previous: PackedVector2Array = PackedVector2Array()
	for index: int in point_count:
		var sample: float = float(index * old_count) / point_count
		var first: int = floori(sample)
		var second: int = (first + 1) % old_count
		var blend: float = sample - first
		points.append(_points[first].lerp(_points[second], blend))
		previous.append(_previous[first].lerp(_previous[second], blend))
	
	if is_instance_valid(_holder):
		var center: Vector2 = _holder.get_center()
		var angle: float = _holder._ring_angle(center)
		_grab_offsets.clear()
		for point: Vector2 in points:
			_grab_offsets.append((point - center).rotated(-angle))
	
	_points = points
	_previous = previous
	_clear_positions = _points.duplicate()
	_rest_edge = 2.0 * radius * sin(PI / point_count)
	_rest_area = 0.5 * point_count * radius * radius * sin(TAU / point_count)


func _apply_contact_drive(direction: float, delta: float) -> void:
	if is_zero_approx(direction):
		return
	
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var reaction: Vector2 = Vector2.ZERO
	for index: int in point_count:
		var outward: Vector2 = _area_gradient(index).normalized()
		if outward.is_zero_approx():
			continue
		var point: Vector2 = _points[index]
		var query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(point, point + outward * 5.0, terrain_mask, _excluded_bodies)
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			continue
		var surface_normal: Vector2 = hit.normal
		var tangent: Vector2 = Vector2(-outward.y, outward.x).slide(surface_normal)
		# Grip holds part of the backward tread motion against the surface.
		var drive: Vector2 = tangent * direction * drive_acceleration * _carry_factor() * delta * delta
		_previous[index] -= drive * 0.35
		reaction -= drive / point_count
	
	for index: int in point_count:
		_previous[index] -= reaction


func _area_gradient(index: int) -> Vector2:
	var chord: Vector2 = _points[(index + 1) % point_count] - _points[posmod(index - 1, point_count)]
	return Vector2(chord.y, -chord.x) * 0.5


func _integrate(delta: float) -> void:
	var gravity: Vector2 = _gravity_offset(delta)
	for index: int in point_count:
		var current: Vector2 = _points[index]
		_points[index] += (current - _previous[index]) * 0.99 + gravity
		_previous[index] = current


func _gravity_offset(delta: float) -> Vector2:
	var strength: float = ProjectSettings.get_setting("physics/2d/default_gravity")
	var direction: Vector2 = ProjectSettings.get_setting("physics/2d/default_gravity_vector")
	return direction * strength * delta * delta


func _signed_area() -> float:
	var sum: float = 0.0
	var origin: Vector2 = _points[0]
	for index: int in point_count:
		var a: Vector2 = _points[index] - origin
		var b: Vector2 = _points[(index + 1) % point_count] - origin
		sum += (a.y + b.y) * (a.x - b.x)
	return sum * 0.5


func _solve_area() -> void:
	var gradients: PackedVector2Array = PackedVector2Array()
	var weight: float = 0.0
	for index: int in point_count:
		var outward: Vector2 = _area_gradient(index)
		gradients.append(outward)
		weight += outward.length_squared()
	if weight <= 0.001:
		return
	var pressure: float = (_rest_area - _signed_area()) / weight
	for index: int in point_count:
		var correction: Vector2 = gradients[index] * pressure
		_points[index] += correction


func _ring_angle(center: Vector2) -> float:
	var alignment: Vector2 = Vector2.ZERO
	for index: int in point_count:
		var rest: Vector2 = Vector2.from_angle(TAU * index / point_count)
		var offset: Vector2 = _points[index] - center
		alignment += Vector2(rest.dot(offset), rest.cross(offset))
	return alignment.angle()


func _carry_with(center: Vector2, holder_angle: float) -> void:
	if _grab_offsets.size() != point_count:
		return
	for index: int in point_count:
		_points[index] = center + _grab_offsets[index].rotated(holder_angle)
	_previous = _points.duplicate()
	_clear_positions = _points.duplicate()
	velocity = Vector2.ZERO
	spin = 0.0
	angle = _ring_angle(get_center())
	_sync_node()


func _restore_roundness(strength: float) -> void:
	var center: Vector2 = get_center()
	var alignment: Vector2 = Vector2.ZERO
	for index: int in point_count:
		var rest: Vector2 = Vector2.from_angle(TAU * index / point_count)
		var offset: Vector2 = _points[index] - center
		alignment += Vector2(rest.dot(offset), rest.cross(offset))
	
	var angle: float = alignment.angle()
	var correction: float = 0.65 * strength / (1.0 + strength)
	for index: int in point_count:
		var target: Vector2 = center + Vector2.from_angle(angle + TAU * index / point_count) * radius
		_points[index] = _points[index].lerp(target, correction)


func _solve_edges(strength: float) -> void:
	for index: int in point_count:
		var next: int = (index + 1) % point_count
		var edge: Vector2 = _points[next] - _points[index]
		var length: float = edge.length()
		if length > 0.001:
			var correction: Vector2 = edge * (0.5 * strength * (length - _rest_edge) / length)
			_points[index] += correction
			_points[next] -= correction


func _solve_terrain() -> void:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var overlap: PhysicsPointQueryParameters2D = PhysicsPointQueryParameters2D.new()
	overlap.collision_mask = terrain_mask
	overlap.exclude = _excluded_bodies
	for index: int in point_count:
		var start: Vector2 = _previous[index] if _sweep_starts.is_empty() else _sweep_starts[index]
		var end: Vector2 = _points[index]
		overlap.position = start
		if not space.intersect_point(overlap, 1).is_empty():
			start = _recover_contact(index, start, space, overlap)
			# Recover on the same side before considering further movement.
			end = start
			_previous[index] = start
		
		if not start.is_equal_approx(end):
			var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters2D.create(start, end, terrain_mask, _excluded_bodies))
			if not hit.is_empty():
				var normal: Vector2 = hit.normal
				end = hit.position + normal * 0.5
				var velocity: Vector2 = end - _previous[index]
				_previous[index] += normal * minf(velocity.dot(normal), 0.0)
		
		overlap.position = end
		if not space.intersect_point(overlap, 1).is_empty():
			end = start
			overlap.position = end
			if not space.intersect_point(overlap, 1).is_empty():
				end = _recover_contact(index, end, space, overlap)
			_previous[index] = end
		_points[index] = end
		overlap.position = end
		if space.intersect_point(overlap, 1).is_empty():
			_clear_positions[index] = end


func _update_collision_exclusions() -> void:
	_excluded_bodies.clear()
	if solid_body != null:
		_excluded_bodies.append(solid_body.get_rid())
	for partner: VerletSlime in [_holder, _held_slime]:
		if is_instance_valid(partner) and partner.solid_body != null:
			_excluded_bodies.append(partner.solid_body.get_rid())
	var center: Vector2 = get_center()
	for other: VerletSlime in get_tree().get_nodes_in_group("solid_slimes"):
		if other == self or other == _holder or other == _held_slime:
			continue
		# A smaller rider resolves contact against its support, without deforming the support in return.
		var offset: Vector2 = other.get_center() - center
		if other.radius < radius and offset.y < -radius * 0.35 and absf(offset.x) < -offset.y:
			_excluded_bodies.append(other.solid_body.get_rid())


func _recover_contact(index: int, point: Vector2, space: PhysicsDirectSpaceState2D, overlap: PhysicsPointQueryParameters2D) -> Vector2:
	var anchor: Vector2 = _clear_positions[index]
	overlap.position = anchor
	if not space.intersect_point(overlap, 1).is_empty():
		return _recover_point(point, space, overlap)
	
	var query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(anchor, point, terrain_mask, _excluded_bodies)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return anchor
	var normal: Vector2 = hit.normal
	var candidate: Vector2 = hit.position + normal * 0.5
	overlap.position = candidate
	return candidate if space.intersect_point(overlap, 1).is_empty() else anchor


func _recover_point(point: Vector2, space: PhysicsDirectSpaceState2D, overlap: PhysicsPointQueryParameters2D) -> Vector2:
	# Find open space, then sweep back to the nearest sampled surface.
	var distance: float = 1.0
	while distance <= 4096.0:
		var best: Vector2 = point
		var best_distance: float = INF
		for index: int in 8:
			var outside: Vector2 = point + Vector2.from_angle(TAU * index / 8) * distance
			overlap.position = outside
			if not space.intersect_point(overlap, 1).is_empty():
				continue
			var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters2D.create(outside, point, terrain_mask, _excluded_bodies))
			if hit.is_empty():
				continue
			var surface: Vector2 = hit.position
			var normal: Vector2 = hit.normal
			var candidate: Vector2 = surface + normal * 0.5
			overlap.position = candidate
			var separation: float = point.distance_squared_to(candidate)
			if separation < best_distance and space.intersect_point(overlap, 1).is_empty():
				best = candidate
				best_distance = separation
		if best_distance < INF:
			return best
		distance *= 2.0
	return point


# -------------------------------- EXTERNAL FUNCTIONS ----------------------------------------


func toggle_grab(target: VerletSlime) -> void:
	if is_instance_valid(_held_slime):
		_held_slime._previous = _held_slime._points.duplicate()
		_held_slime._holder = null
		_held_slime = null
		return
	if not is_instance_valid(target) or target == self or is_instance_valid(_holder):
		return
	if is_instance_valid(target._holder) or is_instance_valid(target._held_slime):
		return
	
	var reach: float = 18.0
	for point: Vector2 in _points:
		for target_point: Vector2 in target._points:
			if point.distance_squared_to(target_point) <= reach * reach:
				_held_slime = target
				target._holder = self
				var center: Vector2 = get_center()
				var angle: float = _ring_angle(center)
				target._grab_offsets.clear()
				for held_point: Vector2 in target._points:
					target._grab_offsets.append((held_point - center).rotated(-angle))
				return


func set_controls(direction: float, boosting: bool) -> void:
	_move_direction = direction
	_boosting = boosting


func get_center() -> Vector2:
	var center: Vector2 = Vector2.ZERO
	for point: Vector2 in _points:
		center += point
	return center / point_count


## Pushes off the ground. Returns false in the air or while held.
func jump(strength: float = jump_strength) -> bool:
	if is_held() or not _has_ground_contact():
		return false
	var kick: Vector2 = Vector2.UP * strength * _carry_factor() * get_physics_process_delta_time()
	for index: int in point_count:
		_previous[index] -= kick
	return true


## Moves the whole slime to `center` in its resting shape, moving at `new_velocity`.
func teleport(center: Vector2, new_velocity: Vector2 = Vector2.ZERO) -> void:
	var step: Vector2 = new_velocity * get_physics_process_delta_time()
	for index: int in point_count:
		_points[index] = center + Vector2.from_angle(angle + TAU * index / point_count) * radius
		_previous[index] = _points[index] - step
	_clear_positions = _points.duplicate()
	velocity = new_velocity
	spin = 0.0
	_sync_node()


## Poses a slime that is not simulated here. `rim` is in the body frame, relative to `center`.
func set_pose(center: Vector2, new_angle: float, rim: PackedVector2Array) -> void:
	if rim.is_empty():
		return
	angle = new_angle
	var fitted: PackedVector2Array = _resampled(rim, point_count)
	for index: int in point_count:
		_points[index] = center + fitted[index].rotated(new_angle)
	_previous = _points.duplicate()
	_clear_positions = _points.duplicate()
	_sync_node()


## The rim as 2 signed bytes per point, in the body frame. Mirrors SHAPE_BYTES on the server.
func pack_shape() -> PackedByteArray:
	var center: Vector2 = get_center()
	var rim: PackedVector2Array = _resampled(_points, SHAPE_POINTS)
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(SHAPE_POINTS * 2)
	var unit: float = 127.0 / (radius * SHAPE_RANGE)
	for index: int in SHAPE_POINTS:
		var offset: Vector2 = (rim[index] - center).rotated(-angle)
		bytes.encode_s8(index * 2, clampi(roundi(offset.x * unit), -127, 127))
		bytes.encode_s8(index * 2 + 1, clampi(roundi(offset.y * unit), -127, 127))
	return bytes


## Decodes pack_shape() output; an invalid array gives the resting ring.
func unpack_shape(bytes: PackedByteArray) -> PackedVector2Array:
	if bytes.size() != SHAPE_POINTS * 2:
		return rest_shape()
	var rim: PackedVector2Array = PackedVector2Array()
	var unit: float = radius * SHAPE_RANGE / 127.0
	for index: int in SHAPE_POINTS:
		rim.append(Vector2(bytes.decode_s8(index * 2), bytes.decode_s8(index * 2 + 1)) * unit)
	return rim


## The resting ring in the body frame.
func rest_shape() -> PackedVector2Array:
	var rim: PackedVector2Array = PackedVector2Array()
	for index: int in SHAPE_POINTS:
		rim.append(Vector2.from_angle(TAU * index / SHAPE_POINTS) * radius)
	return rim


## Centre-to-centre distance at which `captive` sticks to this slime's rim.
## Mirrors hold_distance() on the server.
func hold_distance(captive: VerletSlime) -> float:
	return radius + captive.radius


## Where `captive` sits while this slime holds it.
func hold_point(captive: VerletSlime) -> Vector2:
	return get_center() + Vector2.from_angle(angle + captive.hold_angle) * hold_distance(captive)


func set_identity(identity: PackedByteArray) -> void:
	registry.erase(net_id)
	net_identity = identity
	net_id = identity.hex_encode()
	registry[net_id] = self


func is_held() -> bool:
	return held_by_id != "" or is_instance_valid(_holder)


## Applies the server-owned interaction row and emits hold_started / launched on changes.
func apply_state(row: GameSlimeState) -> void:
	var new_held: String = (row.held_by.unwrap() as PackedByteArray).hex_encode() if row.held_by.is_some() else ""
	holding_id = (row.holding.unwrap() as PackedByteArray).hex_encode() if row.holding.is_some() else ""
	hold_angle = row.hold_angle
	var launched_now: bool = _launch_seq >= 0 and row.launch_seq != _launch_seq
	_launch_seq = row.launch_seq
	var started: bool = new_held != "" and new_held != held_by_id
	held_by_id = new_held
	_resolve_partners()
	if started:
		hold_started.emit()
	if launched_now:
		launched.emit(row.launch_pos, row.launch_vel)


## Applies the server-owned parameters.
func apply_stats(row: GameSlimeStats) -> void:
	if not is_equal_approx(radius, row.size):
		radius = row.size
	weight = row.weight
	drive_acceleration = row.rotation_speed
	throw_strength = row.throw_strength
	jump_strength = row.jump_strength
	# Softness is the inverse of the rim's edge stiffness; a little stiffness keeps the ring intact.
	edge_strength = maxf(1.0 - row.softness, 0.02)
	_update_label()


## Forget all server state, e.g. when the connection drops.
func clear_state() -> void:
	held_by_id = ""
	holding_id = ""
	_launch_seq = -1
	_resolve_partners()
