class_name RotateButton
extends Button
## A round button with a turning arrow, for turning the block that is about to be put down.

const INK := Color("ffc933")
const ICON := preload("res://assets/icons/rotate.svg")


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
	var side := r * 1.2
	draw_texture_rect(ICON, Rect2(c - Vector2(side, side) * 0.5, Vector2(side, side)), false, INK)
