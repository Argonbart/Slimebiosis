class_name VerletSlime
extends Node2D
## Simulates a soft ring using Verlet integration and an enclosed-area constraint.


const SOLVER_PASSES: int = 8
const BURST_EDGE_RATIO: float = 4.0
const BURST_DURATION: float = 2.5
const RIGIDITY_BOOST_MULTIPLIER: float = 50.0

@export_category("Components")
@export var solid_body: StaticBody2D = null
@export var solid_outline: CollisionShape2D = null

@export_category("Settings")
@export var body_color: Color = Color("#65d7bf")

@export_category("Data")
@export_range(8, 64) var points: int = 32:
	set(value):
		var count: int = clampi(value, 8, 64)
		if count == points:
			return
		points = count
		if not _points.is_empty():
			_resample_ring()
@export_range(12.0, 100.0) var size: float = 100.0:
	set(value):
		var ratio: float = value / size
		size = value
		_rest_edge *= ratio
		_rest_area *= ratio * ratio
@export_range(0.0, 1.0) var rigidity: float = 0.5
@export var speed: float = 5000.0
@export_range(0.25, 4.0) var weight: float = 1.0
@export_range(0.0, 1500.0) var strength: float = 420.0
@export_flags_2d_physics var terrain_mask: int = 1

var _burst_remaining: float = 0.0
var _burst_center: Vector2 = Vector2.ZERO
var _droplets: PackedVector2Array = PackedVector2Array()
var _droplet_velocities: PackedVector2Array = PackedVector2Array()
var _held_slime: VerletSlime = null
var _carry_spin: float = 0.0
var _grab_indices: PackedInt32Array = PackedInt32Array()
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
	
	for index: int in points:
		_points.append(global_position + Vector2.from_angle(TAU * index / points) * size)
	_previous = _points.duplicate()
	_clear_positions = _points.duplicate()
	_rest_area = _signed_area()
	_rest_edge = _points[0].distance_to(_points[1])
	_update_solid_outline()


func _physics_process(delta: float) -> void:
	if not _droplets.is_empty():
		_update_burst(delta)
		return
	
	if _has_torn_edges():
		_burst()
		return
	
	var carrying: bool = is_instance_valid(_held_slime)
	var saved_points: PackedVector2Array = _points.duplicate() if carrying else PackedVector2Array()
	_update_collision_exclusions()

	_apply_contact_drive(_move_direction, delta)
	_sweep_starts = _points.duplicate()
	_integrate(delta)
	if is_instance_valid(_holder):
		_follow_holder(delta)
	var effective_rigidity: float = _effective_rigidity()

	var edge_passes: int = maxi(1, ceili(effective_rigidity))
	_solve_terrain(true)
	for _pass: int in SOLVER_PASSES:
		_sweep_starts = _points.duplicate()
		for _edge_pass: int in edge_passes:
			_solve_edges(effective_rigidity / edge_passes)
		_solve_area()
		_solve_terrain()
	_sweep_starts.clear()
	_update_solid_outline()
	for _contact_pass: int in 3:
		_resolve_new_slime_contacts()
		_solve_terrain()
		_update_solid_outline()
	if carrying:
		var center: Vector2 = get_center()
		var angle: float = _ring_angle(center)
		var previous_center: Vector2 = Vector2.ZERO
		for point: Vector2 in saved_points:
			previous_center += point
		previous_center /= points
		var previous_angle: float = _ring_angle(previous_center, saved_points)
		_carry_spin = wrapf(angle - previous_angle, -PI, PI) / delta
	if _has_torn_edges():
		_burst()
	queue_redraw()


func _draw() -> void:
	if not _droplets.is_empty():
		var tint: Color = body_color
		tint.a *= clampf(_burst_remaining * 2.0, 0.0, 1.0)
		for droplet: Vector2 in _droplets:
			draw_circle(to_local(droplet), clampf(size * 0.08, 3.0, 8.0), tint, true, -1.0, true)
		return
	
	var outline: PackedVector2Array = PackedVector2Array()
	for point: Vector2 in _points:
		outline.append(to_local(point))
	if Geometry2D.triangulate_polygon(outline).is_empty():
		outline = _open_hull(outline)
	if outline.size() >= 3:
		draw_colored_polygon(outline, body_color)
		_draw_grab_glow(outline)


# -------------------------------- LOCAL FUNCTIONS ----------------------------------------


func _has_torn_edges() -> bool:
	var limit_squared: float = pow(_rest_edge * BURST_EDGE_RATIO, 2.0)
	for index: int in points:
		var next: int = (index + 1) % points
		var following: int = (next + 1) % points
		if _points[index].distance_squared_to(_points[next]) > limit_squared and _points[next].distance_squared_to(_points[following]) > limit_squared:
			return true
	return false


func _burst() -> void:
	_burst_center = get_center()
	_burst_remaining = BURST_DURATION
	_droplets = _points.duplicate()
	_droplet_velocities.clear()
	for point: Vector2 in _droplets:
		_droplet_velocities.append((point - _burst_center).normalized() * 140.0 + Vector2.UP * 65.0)
	
	if is_instance_valid(_holder):
		_holder._held_slime = null
		_holder = null
	if is_instance_valid(_held_slime):
		_held_slime._holder = null
		_held_slime = null
	_grab_indices.clear()
	_grab_offsets.clear()
	_carry_spin = 0.0
	if solid_outline != null:
		solid_outline.disabled = true
	queue_redraw()


func _update_burst(delta: float) -> void:
	_burst_remaining -= delta
	var gravity_step: Vector2 = _gravity_offset(delta) / delta
	for index: int in _droplets.size():
		_droplets[index] += _droplet_velocities[index] * delta
		_droplet_velocities[index] += gravity_step
	if _burst_remaining <= 0.0:
		_try_respawn()
	queue_redraw()


func _try_respawn() -> void:
	_update_collision_exclusions()
	var clearance: CircleShape2D = CircleShape2D.new()
	clearance.radius = size
	var query: PhysicsShapeQueryParameters2D = PhysicsShapeQueryParameters2D.new()
	query.shape = clearance
	query.collision_mask = terrain_mask
	query.exclude = _excluded_bodies
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	for step: int in 16:
		var center: Vector2 = _burst_center + Vector2.UP * (size * 2.0 + 40.0 + step * size)
		query.transform = Transform2D(0.0, center)
		if not space.intersect_shape(query, 1).is_empty():
			continue
		_points.clear()
		for index: int in points:
			_points.append(center + Vector2.from_angle(TAU * index / points) * size)
		_previous = _points.duplicate()
		_clear_positions = _points.duplicate()
		_sweep_starts.clear()
		_rest_area = _signed_area()
		_rest_edge = _points[0].distance_to(_points[1])
		_droplets.clear()
		_update_solid_outline()
		if solid_outline != null:
			solid_outline.disabled = false
		return


func _draw_grab_glow(outline: PackedVector2Array) -> void:
	var held: VerletSlime = self if is_instance_valid(_holder) else _held_slime
	if not is_instance_valid(held) or held._grab_indices.is_empty():
		return
	
	var contact: Vector2 = Vector2.ZERO
	for index: int in held._grab_indices:
		contact += held._points[index]
	contact = to_local(contact / held._grab_indices.size())
	
	for index: int in outline.size():
		var start: Vector2 = outline[index]
		var end: Vector2 = outline[(index + 1) % outline.size()]
		var distance: float = start.lerp(end, 0.5).distance_to(contact)
		var glow: float = 1.0 - smoothstep(8.0, 42.0, distance)
		if glow <= 0.0:
			continue
		draw_line(start, end, Color(0.5, 1.0, 0.9, 0.12 * glow), 12.0, true)
		draw_line(start, end, Color(0.6, 1.0, 0.92, 0.26 * glow), 7.0, true)
		draw_line(start, end, Color(0.85, 1.0, 0.95, 0.95 * glow), 2.5, true)


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
	


func _resolve_new_slime_contacts() -> void:
	if solid_body == null:
		return
	var hull: PackedVector2Array = _open_hull(_points)
	if hull.size() < 3:
		return
	
	for other: VerletSlime in get_tree().get_nodes_in_group("solid_slimes"):
		if other == self or other == _holder or not other._droplets.is_empty():
			continue
		for index: int in other.points:
			var point: Vector2 = other._points[index]
			if not Geometry2D.is_point_in_polygon(point, hull):
				continue
			var closest: Vector2 = point
			var distance: float = INF
			for edge: int in hull.size():
				var surface: Vector2 = Geometry2D.get_closest_point_to_segment(point, hull[edge], hull[(edge + 1) % hull.size()])
				if surface.distance_squared_to(point) < distance:
					closest = surface
					distance = surface.distance_squared_to(point)
			var correction: Vector2 = closest - point
			other._points[index] = closest + correction.normalized() * 0.5
			other._previous[index] += other._points[index] - point
			other._clear_positions[index] = other._points[index]
			other.queue_redraw()
		other._update_solid_outline()


func _open_hull(outline: PackedVector2Array) -> PackedVector2Array:
	var hull: PackedVector2Array = Geometry2D.convex_hull(outline)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
		hull.resize(hull.size() - 1)
	return hull


func _resample_ring() -> void:
	var old_count: int = _points.size()
	var resampled: PackedVector2Array = PackedVector2Array()
	var previous: PackedVector2Array = PackedVector2Array()
	for index: int in points:
		var sample: float = float(index * old_count) / points
		var first: int = floori(sample)
		var second: int = (first + 1) % old_count
		var blend: float = sample - first
		resampled.append(_points[first].lerp(_points[second], blend))
		previous.append(_previous[first].lerp(_previous[second], blend))
	
	if is_instance_valid(_holder):
		var center: Vector2 = _holder.get_center()
		var angle: float = _holder._ring_angle(center)
		for slot: int in _grab_indices.size():
			var index: int = roundi(float(_grab_indices[slot] * points) / old_count) % points
			_grab_indices[slot] = index
			_grab_offsets[slot] = (resampled[index] - center).rotated(-angle)
	
	_points = resampled
	_previous = previous
	_clear_positions = _points.duplicate()
	_rest_edge = 2.0 * size * sin(PI / points)
	_rest_area = 0.5 * points * size * size * sin(TAU / points)


func _loaded_speed() -> float:
	if is_instance_valid(_held_slime):
		return speed * (strength / 420.0) / maxf(_held_slime.weight, 0.25)
	return speed


func _apply_contact_drive(direction: float, delta: float) -> void:
	if is_zero_approx(direction):
		return
	
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var reaction: Vector2 = Vector2.ZERO
	var acceleration: float = _loaded_speed()
	for index: int in points:
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
		var drive: Vector2 = tangent * direction * acceleration * delta * delta
		_previous[index] -= drive * 0.35
		reaction -= drive / points
	
	for index: int in points:
		_previous[index] -= reaction


func _area_gradient(index: int) -> Vector2:
	var chord: Vector2 = _points[(index + 1) % points] - _points[posmod(index - 1, points)]
	return Vector2(chord.y, -chord.x) * 0.5


func _integrate(delta: float) -> void:
	var gravity: Vector2 = _gravity_offset(delta)
	for index: int in points:
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
	for index: int in points:
		var a: Vector2 = _points[index] - origin
		var b: Vector2 = _points[(index + 1) % points] - origin
		sum += (a.y + b.y) * (a.x - b.x)
	return sum * 0.5


func _solve_area() -> void:
	var gradients: PackedVector2Array = PackedVector2Array()
	var weight: float = 0.0
	for index: int in points:
		var outward: Vector2 = _area_gradient(index)
		gradients.append(outward)
		weight += outward.length_squared()
	if weight <= 0.001:
		return
	var pressure: float = (_rest_area - _signed_area()) / weight
	for index: int in points:
		var correction: Vector2 = gradients[index] * pressure
		_points[index] += correction


func _ring_angle(center: Vector2, ring: PackedVector2Array = PackedVector2Array()) -> float:
	if ring.is_empty():
		ring = _points
	var alignment: Vector2 = Vector2.ZERO
	for index: int in points:
		var rest: Vector2 = Vector2.from_angle(TAU * index / points)
		var offset: Vector2 = ring[index] - center
		alignment += Vector2(rest.dot(offset), rest.cross(offset))
	return alignment.angle()


func _effective_rigidity() -> float:
	if is_instance_valid(_holder):
		return 1.0
	return rigidity * RIGIDITY_BOOST_MULTIPLIER if _boosting else rigidity


func _follow_holder(delta: float) -> void:
	var center: Vector2 = _holder.get_center()
	var angle: float = _holder._ring_angle(center)
	var response: float = 1.0 - exp(-12.0 * delta)
	for slot: int in _grab_indices.size():
		var index: int = _grab_indices[slot]
		var target: Vector2 = center + _grab_offsets[slot].rotated(angle)
		_points[index] = _points[index].lerp(target, response)


func _restore_roundness(strength: float) -> void:
	var center: Vector2 = get_center()
	var alignment: Vector2 = Vector2.ZERO
	for index: int in points:
		var rest: Vector2 = Vector2.from_angle(TAU * index / points)
		var offset: Vector2 = _points[index] - center
		alignment += Vector2(rest.dot(offset), rest.cross(offset))
	
	var angle: float = alignment.angle()
	var correction: float = 0.65 * strength / (1.0 + strength)
	for index: int in points:
		var target: Vector2 = center + Vector2.from_angle(angle + TAU * index / points) * size
		_points[index] = _points[index].lerp(target, correction)


func _solve_edges(strength: float) -> void:
	for index: int in points:
		var next: int = (index + 1) % points
		var edge: Vector2 = _points[next] - _points[index]
		var length: float = edge.length()
		if length > 0.001:
			var correction: Vector2 = edge * (0.5 * strength * (length - _rest_edge) / length)
			_points[index] += correction
			_points[next] -= correction


func _solve_terrain(transfer_load: bool = false) -> void:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var overlap: PhysicsPointQueryParameters2D = PhysicsPointQueryParameters2D.new()
	overlap.collision_mask = terrain_mask
	overlap.exclude = _excluded_bodies
	for index: int in points:
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
				var surface: Vector2 = hit.position
				if transfer_load and normal.dot(Vector2.UP) > 0.5:
					_transfer_contact_load(hit.collider, surface, normal, end - start)
				var contact: Vector2 = surface + normal * 0.5
				var slide: Vector2 = (end - surface).slide(normal)
				end = contact
				if not slide.is_zero_approx():
					var slide_query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(contact, contact + slide, terrain_mask, _excluded_bodies)
					var obstruction: Dictionary = space.intersect_ray(slide_query)
					if obstruction.is_empty():
						end += slide
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


func _transfer_contact_load(body: Object, contact: Vector2, normal: Vector2, travel: Vector2) -> void:
	for support: VerletSlime in get_tree().get_nodes_in_group("solid_slimes"):
		if support.solid_body != body or not support._droplets.is_empty():
			continue
		
		var closest: int = 0
		for index: int in support.points:
			if support._points[index].distance_squared_to(contact) < support._points[closest].distance_squared_to(contact):
				closest = index
		var impact: float = clampf(-travel.dot(normal), 0.0, 8.0)
		var mass_ratio: float = weight * support.points / (maxf(support.weight, 0.25) * points)
		support._previous[closest] += normal * impact * mass_ratio * 0.5
		return


func _update_collision_exclusions() -> void:
	_excluded_bodies.clear()
	if solid_body != null:
		_excluded_bodies.append(solid_body.get_rid())
	# The held slime resolves contact against the grabber.
	if is_instance_valid(_held_slime) and _held_slime.solid_body != null:
		_excluded_bodies.append(_held_slime.solid_body.get_rid())



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
		var offset: Vector2 = _held_slime.get_center() - get_center()
		var tangent: Vector2 = Vector2(-offset.y, offset.x)
		var impulse: Vector2 = offset.normalized() * strength
		var launch_velocity: Vector2 = impulse / maxf(_held_slime.weight, 0.25) + tangent * _carry_spin
		var recoil: Vector2 = -impulse / maxf(weight, 0.25) * get_physics_process_delta_time()
		for index: int in points:
			_previous[index] -= recoil
		var displacement: Vector2 = launch_velocity * get_physics_process_delta_time()
		for index: int in _held_slime.points:
			var point: Vector2 = _held_slime._points[index]
			_held_slime._previous[index] = point - displacement
			_held_slime._clear_positions[index] = point
		_held_slime._holder = null
		_held_slime = null
		return
	if not is_instance_valid(target) or target == self or is_instance_valid(_holder):
		return
	if not _droplets.is_empty() or not target._droplets.is_empty():
		return
	if is_instance_valid(target._holder) or is_instance_valid(target._held_slime):
		return
	
	_update_collision_exclusions()
	
	var reach: float = 2.0
	var center: Vector2 = get_center()
	var angle: float = _ring_angle(center)
	var hull: PackedVector2Array = _open_hull(_points)
	target._grab_indices.clear()
	target._grab_offsets.clear()
	for index: int in target.points:
		var point: Vector2 = target._points[index]
		for edge: int in hull.size():
			var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, hull[edge], hull[(edge + 1) % hull.size()])
			if point.distance_squared_to(closest) <= reach * reach:
				target._grab_indices.append(index)
				target._grab_offsets.append((point - center).rotated(-angle))
				break
	
	if not target._grab_indices.is_empty():
		_carry_spin = 0.0
		_held_slime = target
		target._holder = self


func set_controls(direction: float, boosting: bool) -> void:
	_move_direction = direction
	_boosting = boosting


func get_center() -> Vector2:
	var center: Vector2 = Vector2.ZERO
	for point: Vector2 in _points:
		center += point
	return center / points
