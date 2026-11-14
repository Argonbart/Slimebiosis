@tool
class_name Solid extends StaticBody2D
## A solid piece of level geometry defined by a convex-or-concave outline.
## Builds its own collision and draws itself, so levels are just lists of outlines.

@export var points := PackedVector2Array():
	set(value):
		points = value
		_rebuild()
@export var color := Color(0.27, 0.3, 0.4):
	set(value):
		color = value
		queue_redraw()

var _shape: CollisionPolygon2D

func _ready() -> void:
	_rebuild()

func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _shape == null:
		_shape = CollisionPolygon2D.new()
		add_child(_shape)
	_shape.polygon = points
	queue_redraw()

func _draw() -> void:
	if points.size() < 3:
		return
	draw_colored_polygon(points, color)
	var outline := points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, color.lightened(0.25), 2.0, true)
