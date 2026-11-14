extends Node2D
## Inert Mario-style upgrade marker. No collision, pickup, or gameplay effects.


func _draw() -> void:
	var outline: Color = Color("332e32")
	draw_style_box(_rounded_box(outline, 8), Rect2(-23, -43, 46, 44))
	draw_style_box(_rounded_box(Color("ffe5be"), 6), Rect2(-19, -41, 38, 39))
	var cap: PackedVector2Array = PackedVector2Array([Vector2(-43, -32)])
	for index in 25:
		var angle: float = PI + PI * float(index) / 24.0
		cap.append(Vector2(cos(angle) * 43.0, -32.0 + sin(angle) * 38.0))
	cap.append(Vector2(43, -32))
	draw_colored_polygon(cap, Color("f14e54"))
	cap.append(cap[0])
	draw_polyline(cap, outline, 3.0, true)
	draw_circle(Vector2(0, -56), 11.0, Color("fff7e9"))
	draw_circle(Vector2(-28, -43), 8.0, Color("fff7e9"))
	draw_circle(Vector2(28, -43), 8.0, Color("fff7e9"))
	draw_line(Vector2(-7, -24), Vector2(-7, -14), outline, 4.0, true)
	draw_line(Vector2(7, -24), Vector2(7, -14), outline, 4.0, true)


func _rounded_box(color: Color, radius: int) -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	return box
