class_name LevelPicker
extends Control
## A column of squares at the screen edge to choose a depth (or the height of a wall) with one touch: the square you touch, or the
## one the finger slides to, is the level. Drawn as layers of ground, with the chosen ones lit, so that "3 deep" looks like 3 deep.

signal chosen(level: int)

const CELL := 36.0
const GAP := 3.0

var levels := 12:
	set(v):
		levels = v
		custom_minimum_size = Vector2(60.0, levels * (CELL + GAP) + 26.0)
		size = custom_minimum_size
		queue_redraw()
var level := 1:
	set(v):
		level = v
		queue_redraw()
var caption := "Depth":
	set(v):
		caption = v
		queue_redraw()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	levels = 12


func _gui_input(event: InputEvent) -> void:
	var pos := Vector2.ZERO
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		pos = event.position
	elif event is InputEventScreenTouch and event.pressed:
		pos = event.position
	elif event is InputEventScreenDrag:
		pos = event.position
	else:
		return
	accept_event()
	var l := clampi(int((pos.y - 22.0) / (CELL + GAP)) + 1, 1, levels)
	if l != level:
		level = l
		chosen.emit(l)


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.04, 0.04, 0.9))
	draw_string(font, Vector2(4.0, 15.0), caption, HORIZONTAL_ALIGNMENT_CENTER, size.x - 8.0, 12, Color(1, 1, 1, 0.7))
	for i in levels:
		var r := Rect2(6.0, 22.0 + i * (CELL + GAP), size.x - 12.0, CELL)
		var on := i < level
		var shade := 0.55 + 0.45 * float(i) / maxf(levels - 1, 1)
		draw_rect(r, Color(1.0, 0.72, 0.18).darkened(1.0 - shade) if on else Color(0.2, 0.2, 0.2, 0.8))
		if i == level - 1:
			draw_rect(r, Color.WHITE, false, 2.0)
			draw_string(font, r.position + Vector2(0.0, CELL * 0.68), str(level), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 20, Color.BLACK)
