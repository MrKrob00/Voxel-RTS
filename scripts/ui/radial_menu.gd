class_name RadialMenu
extends Control
## The round menu that opens around a thing in the world when it is tapped (the original's "Produce Rope" menu): a ring of
## round action buttons above the point, under it the name, a line about what the action does and what it takes, and Close.
## A tap anywhere else closes it. It only reports what was chosen: each item carries the callable to run.

signal closed

const RADIUS := 92.0
const ITEM := 76.0

var _center := Vector2.ZERO
var _items: Array[ToolTile] = []
var _box: PanelContainer
var _span := 0.0           # half the angle of the ring, degrees


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


## items: [{mode: int (the emblem), label: String, active: bool, call: Callable}]
func open(center: Vector2, title: String, description: String, cost: String, items: Array) -> void:
	for c in get_children():
		c.queue_free()
	_items.clear()
	var area := get_viewport_rect().size
	_center = Vector2(clampf(center.x, 150.0, area.x - 150.0), clampf(center.y, RADIUS + ITEM, area.y - 190.0))
	var n := items.size()
	_span = (n - 1) * 24.0 + 34.0
	for i in n:
		var d: Dictionary = items[i]
		var angle := deg_to_rad(-90.0 + (i - (n - 1) * 0.5) * 48.0)
		var tile := ToolTile.new().setup(d.mode, d.label)
		tile.custom_minimum_size = Vector2(ITEM, ITEM)
		tile.size = Vector2(ITEM, ITEM)
		tile.position = _center + Vector2(cos(angle), sin(angle)) * RADIUS - tile.size * 0.5
		tile.toggle_mode = true
		tile.button_pressed = d.get("active", false)
		tile.pressed.connect(func() -> void:
			d.call.call()
			if not d.get("keep", false):   # an item that is pressed again and again (the ingots) leaves the menu open
				close())
		add_child(tile)
		_items.append(tile)
	_box = PanelContainer.new()
	add_child(_box)
	var col := VBoxContainer.new()
	_box.add_child(col)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 22)
	t.add_theme_color_override("font_color", Hud.ACCENT)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(t)
	for line in [description, cost]:
		if line == "":
			continue
		var l := Label.new()
		l.text = line
		l.add_theme_font_size_override("font_size", 13)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 230.0
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.modulate = Color(1, 1, 1, 0.85)
		col.add_child(l)
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.custom_minimum_size = Vector2(0, Hud.MIN_TOUCH)
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close)
	col.add_child(close_button)
	_box.reset_size()
	_box.position = Vector2(_center.x - _box.size.x * 0.5, _center.y + 20.0)
	visible = true
	queue_redraw()


func close() -> void:
	if visible:
		visible = false
		closed.emit()


func _gui_input(event: InputEvent) -> void:
	if visible and event is InputEventMouseButton and event.pressed:
		close()
		accept_event()


func _draw() -> void:
	if not visible:
		return
	draw_arc(_center, RADIUS, deg_to_rad(-90.0 - _span), deg_to_rad(-90.0 + _span), 40, Color(0.03, 0.04, 0.04, 0.8), ITEM + 18.0)
	draw_arc(_center, RADIUS - ITEM * 0.5 - 9.0, deg_to_rad(-90.0 - _span), deg_to_rad(-90.0 + _span), 40, Hud.ACCENT, 2.0)
