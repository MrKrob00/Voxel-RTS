class_name RotateButton
extends Button
## A round button with a turning arrow, for turning the block that is about to be put down.

const INK := Color("ffc933")


func _init() -> void:
	custom_minimum_size = Vector2(Hud.MIN_TOUCH + 8, Hud.MIN_TOUCH + 8)
	focus_mode = Control.FOCUS_NONE
	flat = true
	tooltip_text = "Turn (R)"


func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.5
	draw_circle(c, r - 2.0, Color(0.04, 0.05, 0.05, 0.92))
	draw_arc(c, r - 2.0, 0.0, TAU, 40, Color(INK, 0.75 if not is_pressed() else 1.0), 2.0)
	var ar := r * 0.5
	draw_arc(c, ar, deg_to_rad(-60.0), deg_to_rad(200.0), 24, INK, 4.0)
	var tip := c + Vector2(cos(deg_to_rad(200.0)), sin(deg_to_rad(200.0))) * ar     # the arrowhead at the end of the arc
	var dir := Vector2(sin(deg_to_rad(200.0)), -cos(deg_to_rad(200.0)))
	var side := Vector2(-dir.y, dir.x)
	draw_colored_polygon([tip + dir * 9.0, tip + side * 8.0, tip - side * 8.0], INK)
