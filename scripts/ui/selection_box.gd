class_name SelectionBox
extends Control
## The rubber-band rectangle drawn while the player drags a selection (mouse drag, or long press and drag with a finger).

var rect := Rect2()
var active := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func show_rect(r: Rect2) -> void:
	rect = r
	active = true
	queue_redraw()


func hide_rect() -> void:
	active = false
	queue_redraw()


func _draw() -> void:
	if not active:
		return
	draw_rect(rect, Color(1.0, 0.9, 0.3, 0.14), true)
	draw_rect(rect, Color(1.0, 0.9, 0.3, 0.9), false, 2.0)
