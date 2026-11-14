class_name VerletSlime
extends Node2D
## Simulates a soft ring using Verlet integration and an enclosed-area constraint.


const SOLVER_PASSES: int = 8

@export_category("Components")
@export var solid_body: StaticBody2D = null
@export var solid_outline: CollisionShape2D = null

@export_category("Settings")
@export var body_color: Color = Color("#65d7bf")

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


func _physics_process(delta: float) -> void:
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
	_update_solid_outline()
	queue_redraw()


func _draw() -> void:
	var outline: PackedVector2Array = PackedVector2Array()
	for point: Vector2 in _points:
		outline.append(to_local(point))
	if Geometry2D.triangulate_polygon(outline).is_empty():
		outline = _open_hull(outline)
	if outline.size() >= 3:
		draw_colored_polygon(outline, body_color)


# -------------------------------- LOCAL FUNCTIONS ----------------------------------------


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
		var drive: Vector2 = tangent * direction * drive_acceleration * delta * delta
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
		solid_outline.shape = ConvexPolygonShape2D.new()
	var center: Vector2 = get_center()
	for other: VerletSlime in get_tree().get_nodes_in_group("solid_slimes"):
		if other == self:
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


func set_controls(direction: float, boosting: bool) -> void:
	_move_direction = direction
	_boosting = boosting


func get_center() -> Vector2:
	var center: Vector2 = Vector2.ZERO
	for point: Vector2 in _points:
		center += point
	return center / point_count
