class_name Hud
extends CanvasLayer
## The interface, laid out like the original game's and made for fingers (every button is at least 56 px at the reference size):
##   - at the left, a dark side panel: the info (resources, units) or, when "+" is pressed, the "New Task" palette with every tool
##     in sections (Harvest, Mining, Construction, Sandbox) and a close button; the active tool also shows as a banner across the top;
##   - at the bottom left a dock: "+" (the palette), idle and all units; beside it a ribbon of task cards, each with its workers as
##     dots (tapping a card selects its workers);
##   - the actions of the active tool (level - / +, turn, done) above the ribbon at the right; home at the right edge.
## It adapts to the screen: the window scales it from a 1280 x 720 reference (720 x 1280 in portrait); on a narrow screen the side
## panel takes the width; the display's safe area (notches, rounded corners) is kept clear.
## The HUD knows nothing about the game: it shows what it is told (set_*) and says what the player did (signals).

signal tool_chosen(mode: int)
signal level_changed(level: int)
signal select_all_pressed
signal select_idle_pressed
signal home_pressed
signal probe_pressed
signal turn_pressed
signal task_select(task: WorkTask)
signal task_cancel(task: WorkTask)
signal task_moved(task: WorkTask, to_index: int)   ## a card was dragged to this place among the cards (the priority of the task)

const MIN_TOUCH := 56
const ACCENT := Color("ffc933")
const PANEL := Color(0.03, 0.04, 0.04, 0.95)
const PANEL_LIGHT := Color(0.09, 0.1, 0.1, 0.9)
const SIDE_W := 320.0
const RIBBON_H := 150.0
const RIGHT_W := 72.0

var selection_box: SelectionBox

var _root: Control
var _status: Label
var _info: PanelContainer
var _resources: VBoxContainer
var _units_label: Label
var _clock: Label
var _palette: PanelContainer
var _palette_open := false
var _page := "tasks"                    # "tasks": the New Task panel; "blocks": what can be built
var _tab := "stone"                     # which tab of the build panel: stone, wood, structures
var _palette_title: Label
var _radial: RadialMenu
var _banner: PanelContainer
var _title_name: Label
var _title_hint: Label
var _rotate: RotateButton
var _picker: LevelPicker
var _dock: PanelContainer
var _plus: Button
var _ribbon_scroll: ScrollContainer
var _ribbon: HBoxContainer
var _cards: Array[Control] = []     # the cards of the ribbon, made once (see set_tasks)
var _no_tasks: Label
const HOLD_TIME := 0.4              ## seconds a finger stays on a card before it can be dragged
const HOLD_SLOP := 14.0             ## pixels the finger may move meanwhile (more is a tap that slid, not a hold)
var _hold_card: Control
var _hold_time := 0.0
var _hold_from := Vector2.ZERO
var _drag_card: Control
var _drag_ended := false            # the release that ended a drag must not also be a tap on the card
var _home: Button
var _probe: Button          # measures what a frame costs on this device, layer by layer (FrameProbe)
var _probe_label: Label
var _toast: Label
var _toast_time := 0.0
var _cell_info: Label
var _mode := Tools.Mode.SELECT
var _level := 1
var _level_name := "level"
var _compact := false


func _ready() -> void:
	layer = 10
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = _make_theme()
	add_child(_root)
	selection_box = SelectionBox.new()
	_root.add_child(selection_box)
	_build_side()
	_build_palette()
	_build_banner()
	_build_bottom()
	_radial = RadialMenu.new()
	_root.add_child(_radial)
	_toast = _outlined_label(22)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_toast)
	_cell_info = _outlined_label(13)
	_root.add_child(_cell_info)
	get_window().size_changed.connect(_relayout)
	set_tool(Tools.Mode.SELECT)
	_relayout()


func _process(delta: float) -> void:
	if _hold_card != null and _drag_card == null:
		_hold_time += delta
		if _hold_time >= HOLD_TIME:
			_drag_card = _hold_card   # held long enough: the card can be dragged along the ribbon
			_drag_card.modulate = Color(1.0, 1.0, 1.0, 0.8)
			_drag_card.z_index = 1
	if _toast_time > 0.0:
		_toast_time -= delta
		_toast.modulate.a = clampf(_toast_time / 0.6, 0.0, 1.0)
		if _toast_time <= 0.0:
			_toast.text = ""


# --- what the game tells the HUD ---------------------------------------------------------------------------------

func set_status(text: String) -> void:
	_status.text = text


func set_cell_info(text: String) -> void:
	_cell_info.text = text


## The table of the probe (or what it is doing now); empty hides it.
func set_probe_text(text: String) -> void:
	_probe_label.text = text
	_probe_label.visible = text != ""
	_probe_label.reset_size()
	_place_probe()


## The table hangs under the home button, its right edge on the screen's.
func _place_probe() -> void:
	_probe_label.position = Vector2(_home.position.x + _home.custom_minimum_size.x - _probe_label.size.x, _home.position.y + MIN_TOUCH + 8.0)


func show_message(text: String) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	_toast_time = 4.0
	_relayout_toast()


## The time of day.
func set_clock(text: String) -> void:
	_clock.text = text


func set_units(total: int, idle: int, selected: int) -> void:
	_units_label.text = "Units %d   idle %d   selected %d" % [total, idle, selected]


func set_resources(lines: Dictionary) -> void:
	for c in _resources.get_children():
		c.queue_free()
	if lines.is_empty():
		var empty := Label.new()
		empty.text = "Nothing stored yet"
		empty.modulate = Color(1, 1, 1, 0.55)
		_resources.add_child(empty)
	for name in lines:
		var l := Label.new()
		l.text = "%s   %s" % [name, str(lines[name])]
		_resources.add_child(l)


## Fills the ribbon. The cards are made once and kept (a card is a button with three labels and a cross): a task takes the next one of the
## pool and only its texts are changed, so a refresh makes and frees no node.
func set_tasks(tasks: Array) -> void:
	if _drag_card != null:
		return   # a card is in the finger: the order on the screen is its own until it is let go
	var shown := 0
	for t: WorkTask in tasks:
		if not t.shown():
			continue
		if shown == _cards.size():
			_cards.append(_make_card())
		_fill_card(_cards[shown], t)
		shown += 1
	for i in range(shown, _cards.size()):
		_cards[i].visible = false
	if _no_tasks == null:
		_no_tasks = Label.new()
		_no_tasks.text = "No tasks. Press + to start one."
		_no_tasks.modulate = Color(1, 1, 1, 0.55)
		_ribbon.add_child(_no_tasks)
	_no_tasks.visible = shown == 0


func set_tool(mode: int) -> void:
	_mode = mode
	var d := Tools.def_of(mode)
	_title_name.text = d.label
	_title_hint.text = d.hint
	var active := mode != Tools.Mode.SELECT
	_banner.visible = active
	_title_hint.visible = active
	_picker.visible = d.get("level", false)
	_picker.caption = d.get("level_name", "level").capitalize()
	_picker.levels = 12
	_level_name = d.get("level_name", "level")
	_refresh_level()
	_rotate.visible = Tools.is_block(mode) or mode in [Tools.Mode.STONE_BRICK, Tools.Mode.WOOD_BRICK, Tools.Mode.FURNACE]
	_set_palette(false)
	_relayout()
	_relayout.call_deferred()   # the labels settle their height one frame later


## The round menu around a thing in the world (items as RadialMenu.open takes them).
func open_radial(at: Vector2, title: String, description: String, cost: String, items: Array) -> void:
	_radial.open(at, title, description, cost, items)


func set_level(v: int) -> void:
	_level = v
	_refresh_level()


# --- building ------------------------------------------------------------------------------------------------------

func _make_theme() -> Theme:
	var th := Theme.new()
	th.default_font_size = 16
	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL
	panel.set_corner_radius_all(0)
	panel.set_content_margin_all(8)
	th.set_stylebox("panel", "PanelContainer", panel)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(2)
		sb.set_content_margin_all(6)
		sb.bg_color = {"normal": PANEL_LIGHT, "hover": Color(0.16, 0.17, 0.15, 0.97), "pressed": Color(0.18, 0.15, 0.04, 0.97), "hover_pressed": Color(0.22, 0.18, 0.05, 1.0), "disabled": Color(0.1, 0.11, 0.12, 0.6), "focus": PANEL_LIGHT}[state]
		if state in ["pressed", "hover_pressed"]:
			sb.border_color = ACCENT
			sb.set_border_width_all(2)
		th.set_stylebox(state, "Button", sb)
	th.set_color("font_color", "Button", Color(0.93, 0.8, 0.45))
	th.set_color("font_pressed_color", "Button", ACCENT)
	th.set_color("font_hover_pressed_color", "Button", ACCENT)
	th.set_color("font_hover_color", "Button", Color.WHITE)
	th.set_color("font_color", "Label", Color.WHITE)
	return th


func _button(text: String, min_size := Vector2(MIN_TOUCH, MIN_TOUCH)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE   # a finger does not need a focus ring, and the camera keys must not be eaten
	return b


func _outlined_label(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 8 if size > 16 else 5)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _build_side() -> void:
	_status = _outlined_label(12)
	_status.modulate = Color(1, 1, 1, 0.7)
	_root.add_child(_status)
	_info = PanelContainer.new()
	_root.add_child(_info)
	var col := VBoxContainer.new()
	_info.add_child(col)
	var head := Label.new()
	head.text = "Player"
	head.add_theme_color_override("font_color", ACCENT)
	var head_row := HBoxContainer.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_row.add_child(head)
	_clock = Label.new()
	_clock.add_theme_font_size_override("font_size", 15)
	head_row.add_child(_clock)
	col.add_child(head_row)
	_units_label = Label.new()
	_units_label.add_theme_font_size_override("font_size", 15)
	col.add_child(_units_label)
	col.add_child(HSeparator.new())
	_resources = VBoxContainer.new()
	col.add_child(_resources)


func _build_banner() -> void:
	_banner = PanelContainer.new()
	_root.add_child(_banner)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_child(row)
	_title_name = Label.new()
	_title_name.add_theme_font_size_override("font_size", 20)
	_title_name.add_theme_color_override("font_color", ACCENT)
	_title_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_title_name)
	var leave := Button.new()          # the cross: leave the tool (the way out of "+")
	leave.text = "×"
	leave.add_theme_font_size_override("font_size", 28)
	leave.flat = true
	leave.focus_mode = Control.FOCUS_NONE
	leave.custom_minimum_size = Vector2(MIN_TOUCH - 8, MIN_TOUCH - 8)
	leave.pressed.connect(func() -> void: tool_chosen.emit(Tools.Mode.SELECT))
	row.add_child(leave)
	_title_hint = _outlined_label(13)
	_title_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_title_hint)


func _set_palette(open: bool) -> void:
	_palette_open = open
	_palette.visible = open
	_plus.button_pressed = open
	if open:
		_page = "tasks"
		_fill_palette()
	_relayout()


func _build_palette() -> void:
	_palette = PanelContainer.new()
	_palette.visible = false
	_root.add_child(_palette)
	var col := VBoxContainer.new()
	_palette.add_child(col)
	var head := HBoxContainer.new()
	col.add_child(head)
	_palette_title = Label.new()
	_palette_title.text = "New Task"
	_palette_title.add_theme_font_size_override("font_size", 24)
	_palette_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_palette_title)
	var close := _button("x")
	close.pressed.connect(func() -> void: _set_palette(false))
	head.add_child(close)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var sections := VBoxContainer.new()
	sections.name = "Sections"
	sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(sections)


## The panel's two pages, like the original's: "New Task" (the kinds of task; Construction opens the next page) and "Blocks"
## (what can be built, in sections).
func _fill_palette() -> void:
	var sections: VBoxContainer = _palette.find_child("Sections", true, false)
	for c in sections.get_children():
		c.queue_free()
	if _page == "blocks":
		var tabs := HBoxContainer.new()
		sections.add_child(tabs)
		for t in Tools.TAB_ORDER:
			var tb := Button.new()
			tb.toggle_mode = true
			tb.button_pressed = t == _tab
			tb.custom_minimum_size = Vector2(0, MIN_TOUCH)
			tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tb.focus_mode = Control.FOCUS_NONE
			tb.expand_icon = true
			var icon_id: String = Tools.TABS[t].icon
			tb.icon = BlockCatalog.icon(icon_id) if t != "structures" else load("res://assets/structures/icons/platform.png")
			tb.tooltip_text = Tools.TABS[t].title
			tb.pressed.connect(func() -> void:
				_tab = t
				_fill_palette())
			tabs.add_child(tb)
		_palette_title.text = Tools.TABS[_tab].title
		for section in Tools.TABS[_tab].sections:
			var grid := _section(sections, section)
			for d in Tools.defs():
				if d.get("section", "") == section and d.get("tab", "") == _tab:
					grid.add_child(_tile(d))
		var back := _button("< New Task", Vector2(0, 44))
		back.pressed.connect(func() -> void:
			_page = "tasks"
			_fill_palette())
		sections.add_child(back)
		return
	_palette_title.text = "New Task"
	for category in Tools.CATEGORIES:
		var grid := _section(sections, {"Harvest": "Harvest Tasks", "Mining": "Mining Tasks", "Construction": "Construction Tasks", "Sandbox": "Sandbox (no units)"}[category])
		if category == "Construction":
			var open := ToolTile.new().setup(Tools.OPEN_BLOCKS, "Build")
			open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			open.pressed.connect(func() -> void:
				_page = "blocks"
				_fill_palette())
			grid.add_child(open)
			continue
		for d in Tools.defs():
			if d.category == category:
				grid.add_child(_tile(d))


func _section(parent: Control, title: String) -> GridContainer:
	var head := Label.new()
	head.text = title
	head.add_theme_color_override("font_color", ACCENT)
	head.add_theme_font_size_override("font_size", 14)
	parent.add_child(head)
	parent.add_child(HSeparator.new())
	var grid := GridContainer.new()
	grid.columns = 4
	parent.add_child(grid)
	return grid


func _tile(d: Dictionary) -> ToolTile:
	var b := ToolTile.new().setup(d.mode, d.get("short", d.label))
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = d.label + ": " + d.hint
	b.disabled = not d.get("enabled", true)
	b.pressed.connect(func() -> void: tool_chosen.emit(d.mode))
	return b


func _build_bottom() -> void:
	_dock = PanelContainer.new()
	_root.add_child(_dock)
	var row := HBoxContainer.new()
	_dock.add_child(row)
	_plus = _button("+", Vector2(MIN_TOUCH, 48))
	_plus.toggle_mode = true
	_plus.add_theme_font_size_override("font_size", 28)
	_plus.toggled.connect(func(on: bool) -> void:
		if on != _palette_open:
			_set_palette(on))
	row.add_child(_plus)
	var idle := _button("Idle", Vector2(96, 48))
	idle.icon = load("res://assets/icons/idle.svg")
	idle.expand_icon = true
	idle.pressed.connect(func() -> void: select_idle_pressed.emit())
	row.add_child(idle)
	var all := _button("All", Vector2(88, 48))
	all.icon = load("res://assets/icons/all_units.svg")
	all.expand_icon = true
	all.pressed.connect(func() -> void: select_all_pressed.emit())
	row.add_child(all)
	_ribbon_scroll = ScrollContainer.new()
	_ribbon_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root.add_child(_ribbon_scroll)
	_ribbon = HBoxContainer.new()
	_ribbon_scroll.add_child(_ribbon)
	_rotate = RotateButton.new()
	_rotate.visible = false
	_rotate.pressed.connect(func() -> void: turn_pressed.emit())
	_root.add_child(_rotate)
	_picker = LevelPicker.new()
	_picker.visible = false
	_picker.chosen.connect(func(l: int) -> void: level_changed.emit(l))
	_root.add_child(_picker)
	_home = _button("", Vector2(MIN_TOUCH + 8, MIN_TOUCH))
	_home.icon = load("res://assets/icons/home.svg")
	_home.expand_icon = true
	_home.tooltip_text = "Home"
	_home.pressed.connect(func() -> void: home_pressed.emit())
	_root.add_child(_home)
	_probe = _button("Probe", Vector2(MIN_TOUCH + 24, MIN_TOUCH))
	_probe.tooltip_text = "Measure what each layer of the picture costs on this device (the table is copied)"
	_probe.pressed.connect(func() -> void: probe_pressed.emit())
	_root.add_child(_probe)
	_probe_label = _outlined_label(12)
	_probe_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_probe_label.visible = false
	_root.add_child(_probe_label)


## One card of the ribbon, like the original's: the kind of task, its workers as dots, and what can be done with it. It belongs to no task
## yet: `_fill_card` gives it one (the task it shows is in its meta "task").
func _make_card() -> Control:
	# The whole card is one button (it selects the task: its workers, its ring in the world); the only other thing on it is the cross
	# that closes the task.
	var card := Button.new()
	card.custom_minimum_size = Vector2(132, 96)
	card.focus_mode = Control.FOCUS_NONE
	card.pressed.connect(func() -> void:
		if _drag_ended:
			_drag_ended = false
			return
		task_select.emit(card.get_meta("task")))
	card.gui_input.connect(_card_input.bind(card))
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 8.0
	col.offset_top = 4.0
	col.offset_right = -34.0
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(col)
	var head := Label.new()
	head.name = "Head"
	head.add_theme_color_override("font_color", ACCENT)
	head.add_theme_font_size_override("font_size", 15)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(head)
	var dots := Label.new()
	dots.name = "Dots"
	dots.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(dots)
	var detail := Label.new()
	detail.name = "Detail"
	detail.add_theme_font_size_override("font_size", 12)
	detail.modulate = Color(1, 1, 1, 0.8)
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(detail)
	var close := Button.new()
	close.text = "×"
	close.add_theme_font_size_override("font_size", 24)
	close.flat = true
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(32, 32)
	close.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close.offset_left = -34.0
	close.offset_bottom = 32.0
	close.pressed.connect(func() -> void: task_cancel.emit(card.get_meta("task")))
	card.add_child(close)
	_ribbon.add_child(card)
	return card


## Holding a card for HOLD_TIME lets it be dragged left and right: it changes places with the card it passes, and where it is let go is its
## place in the order of the tasks (the first has the first call on idle units).
func _card_input(e: InputEvent, card: Control) -> void:
	# a finger gives touches and drags, a mouse gives buttons and motion: both are the same here (the position is the card's own)
	var pressed := false
	var released := false
	var moved := false
	var at := Vector2.ZERO
	var button := e as InputEventMouseButton
	var touch := e as InputEventScreenTouch
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		pressed = button.pressed
		released = not button.pressed
		at = button.position
	elif touch != null:
		pressed = touch.pressed
		released = not touch.pressed
		at = touch.position
	elif e is InputEventMouseMotion:
		moved = true
		at = (e as InputEventMouseMotion).position
	elif e is InputEventScreenDrag:
		moved = true
		at = (e as InputEventScreenDrag).position
	var global := card.get_global_transform() * at
	if pressed:
		_drag_ended = false
		_hold_card = card
		_hold_time = 0.0
		_hold_from = global
	elif released:
		_release_card(card)
	elif moved and _hold_card == card:
		if _drag_card == card:
			_drag_over(card, global.x)
			card.accept_event()   # the ribbon must not scroll with it
		elif global.distance_to(_hold_from) > HOLD_SLOP:
			_hold_card = null   # it slid before the hold was long enough: not a hold


func _release_card(card: Control) -> void:
	if _drag_card == card:
		var index := _shown_cards().find(card)
		card.modulate = Color.WHITE
		card.z_index = 0
		_drag_card = null
		_drag_ended = true
		task_moved.emit(card.get_meta("task"), index)
	_hold_card = null


func _shown_cards() -> Array[Control]:
	var out: Array[Control] = []
	for c in _ribbon.get_children():
		if c.visible and _cards.has(c):
			out.append(c)
	return out


## The card in the finger passes its neighbours: it takes their place when its middle is past theirs.
func _drag_over(card: Control, x: float) -> void:
	var cards := _shown_cards()
	var i := cards.find(card)
	while i > 0 and x < cards[i - 1].get_global_rect().get_center().x:
		_ribbon.move_child(card, cards[i - 1].get_index())
		cards = _shown_cards()
		i = cards.find(card)
	while i < cards.size() - 1 and x > cards[i + 1].get_global_rect().get_center().x:
		_ribbon.move_child(card, cards[i + 1].get_index())
		cards = _shown_cards()
		i = cards.find(card)


func _fill_card(card: Control, t: WorkTask) -> void:
	card.set_meta("task", t)
	card.visible = true
	var col := card.get_child(0)
	(col.get_node("Head") as Label).text = _short_title(t)
	var n := t.workers.size()
	(col.get_node("Dots") as Label).text = "●".repeat(n) + "○".repeat(maxi(mini(t.max_workers, 6) - n, 0)) + ("  +%d" % (n - 6) if n > 6 else "")
	(col.get_node("Detail") as Label).text = t.detail()


static func _short_title(t: WorkTask) -> String:
	return "%s #%d" % [t.title, t.id]


func _refresh_level() -> void:
	_picker.level = _level


# --- layout for the screen it is on -----------------------------------------------------------------------------

## Sizes and places everything for the window. Cheap: called when the window changes and when something opens or closes.
func _relayout() -> void:
	if _root == null:
		return
	var win := get_window()
	var px := Vector2(win.size)
	var portrait := px.x < px.y
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	win.content_scale_size = Vector2i(720, 1280) if portrait else Vector2i(1280, 720)
	var size := _root.get_viewport_rect().size
	_compact = size.x < 760
	var scale := size.x / maxf(px.x, 1.0)
	var il := 8.0
	var it := 8.0
	var ir := 8.0
	var ib := 8.0
	var safe := DisplayServer.get_display_safe_area()
	var screen := Vector2(DisplayServer.screen_get_size())
	if safe.size.x > 0 and screen.x > 0 and win.mode == Window.MODE_FULLSCREEN:   # keep clear of notches and rounded corners
		il = maxf(il, safe.position.x * scale)
		it = maxf(it, safe.position.y * scale)
		ir = maxf(ir, (screen.x - safe.end.x) * scale)
		ib = maxf(ib, (screen.y - safe.end.y) * scale)

	# The banner of the active tool across the top; the side panel under it.
	_banner.custom_minimum_size = Vector2(220.0, 48.0)
	_banner.reset_size()
	var side_right := il + (SIDE_W if not _compact else 0.0) + 8.0
	_banner.position = Vector2(maxf((size.x - _banner.size.x) * 0.5, side_right if not _compact else 0.0), it)
	_title_hint.custom_minimum_size.x = minf(size.x * 0.6, 560.0)
	_title_hint.reset_size()
	_title_hint.position = Vector2((size.x - _title_hint.size.x) * 0.5, it + 48.0)
	var top := it
	_status.position = Vector2(size.x - ir - _status.size.x - RIGHT_W, size.y - ib - 18.0)
	var side_w := minf(SIDE_W, size.x - il - ir - RIGHT_W)
	if _compact:
		side_w = size.x - il - ir - RIGHT_W

	# Bottom: the dock; the ribbon of task cards beside it.
	_dock.reset_size()
	_dock.position = Vector2(il, size.y - ib - _dock.size.y)
	var ribbon_x := il + _dock.size.x + 8.0 if _compact else il + maxf(_dock.size.x, side_w) + 8.0   # (beside the dock, at the bottom, in both layouts)
	var ribbon_y := size.y - ib - RIBBON_H
	_ribbon_scroll.custom_minimum_size = Vector2(size.x - ribbon_x - ir - (0.0 if _compact else RIGHT_W), RIBBON_H)
	_ribbon_scroll.size = _ribbon_scroll.custom_minimum_size
	_ribbon_scroll.position = Vector2(ribbon_x, ribbon_y)

	# The side panel: info, or the palette over the whole height down to the dock.
	var bottom_of_side := _dock.position.y - 8.0
	_info.custom_minimum_size.x = side_w
	_info.reset_size()
	_info.position = Vector2(il, top)
	_info.visible = not _palette_open
	_palette.custom_minimum_size = Vector2(side_w, 0.0)
	_palette.size = Vector2(side_w, maxf(bottom_of_side - top, 160.0))
	_palette.position = Vector2(il, top)

	# Actions of the tool: above the ribbon, at the right.
	_rotate.position = Vector2(size.x - ir - _rotate.size.x - 4.0, ribbon_y - _rotate.size.y - 12.0)
	_home.position = Vector2(size.x - ir - _home.custom_minimum_size.x, top)
	_probe.position = Vector2(_home.position.x - _probe.custom_minimum_size.x - 6.0, top)
	_place_probe()
	_picker.position = Vector2(size.x - ir - _picker.size.x, minf(top + 76.0, size.y - _picker.size.y - ib - 90.0))
	_cell_info.position = Vector2(il + (0.0 if _compact else side_w + 8.0), ribbon_y - 24.0)
	_relayout_toast()


func _relayout_toast() -> void:
	if _toast == null:
		return
	var size := _root.get_viewport_rect().size
	_toast.custom_minimum_size.x = size.x * 0.8
	_toast.position = Vector2(size.x * 0.1, size.y * 0.3)
