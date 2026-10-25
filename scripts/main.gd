extends Node3D
## Sandbox scene: world + RTS camera + a tiny dig/place tool to exercise voxel editing.

var preset := MapPreset.plains()
var world: VoxelWorld
var props: PropField
var rig: RTSCamera
enum Mode { SELECT, MARK_DIG, STOCKPILE, FRAME, DIG, VOXEL, STONE_BRICK, STONE_CUBE, WOOD_BRICK, WOOD_CUBE }
const MODE_NAMES := ["select / move", "mark dig area", "stockpile: plank platform (wood, ore)", "stockpile: frame (stone, plants)", "dig (instant)", "build ground", "stone brick 2x1x1", "stone cube 1x1x1", "wood brick 2x1x1", "wood cube 1x1x1"]
const START_UNITS := 5

var bricks: BrickWorld
var units: UnitManager
var economy: Economy
var board: TaskBoard
var _tasks_panel: VBoxContainer
var _stock_label: Label
var _stock_ghost: MeshInstance3D
var _dig_depth := 1
var _depth_label: Label
var mode := Mode.SELECT
var brick_axis := 0
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _rotate_button: Button

var _hover: MeshInstance3D
var _info: Label
var _cell_info: Label
var _mode_button: Button
var _selection_box: SelectionBox


func _ready() -> void:
	_setup_environment()

	world = VoxelWorld.new()
	world.name = "World"
	world.preset = preset
	for arg in OS.get_cmdline_user_args():   # debug: --extras=0..4, --seed=N, --noprops
		if arg.begins_with("--extras="):
			world.extra_islands = int(arg.substr(9))
		elif arg.begins_with("--seed="):
			world.world_seed = int(arg.substr(7))
	add_child(world)

	if not OS.get_cmdline_user_args().has("--noprops"):   # debug: terrain only
		props = PropField.new()
		props.name = "Props"
		add_child(props)
		props.setup(world)

	bricks = BrickWorld.new()
	bricks.name = "Bricks"
	add_child(bricks)
	bricks.setup(world)

	rig = RTSCamera.new()
	rig.name = "Camera"
	var s := world.size_blocks()
	var spawn := world.spawn_point()
	rig.bounds = Rect2(0, 0, s.x, s.z)
	rig.focus = Vector3(spawn.x, spawn.y, spawn.z)
	rig.ground_height = world.surface_y
	add_child(rig)
	rig.primary_action.connect(_on_primary)
	rig.secondary_action.connect(_on_secondary)
	rig.double_action.connect(_on_double)
	rig.box_changed.connect(func(r: Rect2) -> void: _selection_box.show_rect(r))
	rig.box_cancelled.connect(func() -> void: _selection_box.hide_rect())
	rig.box_finished.connect(_on_box)

	units = UnitManager.new()
	units.name = "Units"
	add_child(units)
	units.setup(world, bricks)
	economy = Economy.new()
	economy.name = "Economy"
	add_child(economy)
	economy.setup(world, bricks)
	board = TaskBoard.new()
	board.name = "Tasks"
	add_child(board)
	board.setup(world, units.nav, economy)
	board.changed.connect(_refresh_tasks_panel)
	economy.changed.connect(_refresh_stock_label)
	world.generation_finished.connect(_spawn_units, CONNECT_ONE_SHOT)

	_setup_hover()
	_setup_ui()
	add_child(load("res://scripts/tools/screenshot.gd").new())


var _panel_timer := 0.0


func _process(delta: float) -> void:
	_panel_timer -= delta
	if _panel_timer <= 0.0 and not board.tasks.is_empty():
		_panel_timer = 0.5
		_refresh_tasks_panel()
	_info.text = "%d fps | %s | %s | units %d (selected %d) | bricks %d" % [Engine.get_frames_per_second(), world.stats(), MODE_NAMES[mode], units.units.size(), units.selection.size(), bricks.brick_count()]
	_update_hover()


func _spawn_units() -> void:
	var sp := world.spawn_point()
	var start := units.nav.nearest_standable(Vector3i(sp.x, sp.y + 1, sp.z), 4)
	if start.x >= 0:
		units.spawn_squad(start, START_UNITS, 2)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = preset.sky_color
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = preset.ambient_color
	env.ambient_light_energy = 0.9
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.light_energy = 0.7
	add_child(sun)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		_rotate_brick()


func _rotate_brick() -> void:
	brick_axis = 1 - brick_axis


func _is_brick_mode() -> bool:
	return mode >= Mode.STONE_BRICK


func _brick_length() -> int:
	return 1 if mode == Mode.STONE_CUBE or mode == Mode.WOOD_CUBE else 2


func _brick_kind() -> int:
	return BrickWorld.Kind.STONE if mode == Mode.STONE_BRICK or mode == Mode.STONE_CUBE else BrickWorld.Kind.WOOD


func _setup_hover() -> void:
	_ghost = MeshInstance3D.new()
	var gbox := BoxMesh.new()
	gbox.size = BrickWorld.SIZE * 1.02
	_ghost.mesh = gbox
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.albedo_color = Color(0.2, 0.9, 0.9, 0.45)
	_ghost.material_override = _ghost_mat
	_ghost.visible = false
	add_child(_ghost)
	_stock_ghost = MeshInstance3D.new()
	var sbox := BoxMesh.new()
	sbox.size = Vector3(Stockpile.SIZE, 0.2, Stockpile.SIZE)
	_stock_ghost.mesh = sbox
	_stock_ghost.material_override = _ghost_mat.duplicate()
	_stock_ghost.visible = false
	add_child(_stock_ghost)
	_hover = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 1.02
	_hover.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.28)
	_hover.material_override = mat
	_hover.visible = false
	add_child(_hover)


func _setup_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_info = Label.new()
	_info.position = Vector2(12, 8)
	layer.add_child(_info)
	_cell_info = Label.new()
	_cell_info.position = Vector2(12, 172)
	_cell_info.add_theme_font_size_override("font_size", 14)
	layer.add_child(_cell_info)
	_selection_box = SelectionBox.new()
	layer.add_child(_selection_box)
	_stock_label = Label.new()
	_stock_label.position = Vector2(12, 450)
	_stock_label.add_theme_font_size_override("font_size", 15)
	layer.add_child(_stock_label)
	_tasks_panel = VBoxContainer.new()
	_tasks_panel.position = Vector2(220, 40)
	layer.add_child(_tasks_panel)
	var all_button := Button.new()
	all_button.text = "All units"
	all_button.custom_minimum_size = Vector2(190, 56)
	all_button.position = Vector2(12, 232)
	all_button.pressed.connect(func() -> void: units.select_all())
	layer.add_child(all_button)
	# How deep "mark dig area" digs: 1 clears the surface, more is a quarry that digs layer by layer and leaves a staircase.
	var depth_row := HBoxContainer.new()
	depth_row.position = Vector2(12, 372)
	layer.add_child(depth_row)
	var minus := Button.new()
	minus.text = "-"
	minus.custom_minimum_size = Vector2(56, 56)
	depth_row.add_child(minus)
	_depth_label = Label.new()
	_depth_label.custom_minimum_size = Vector2(78, 56)
	_depth_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_depth_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	depth_row.add_child(_depth_label)
	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(56, 56)
	depth_row.add_child(plus)
	minus.pressed.connect(func() -> void: _set_depth(_dig_depth - 1))
	plus.pressed.connect(func() -> void: _set_depth(_dig_depth + 1))
	_set_depth(1)
	var idle_button := Button.new()
	idle_button.text = "Idle units"
	idle_button.custom_minimum_size = Vector2(190, 56)
	idle_button.position = Vector2(12, 296)
	idle_button.pressed.connect(func() -> void: units.select_idle())
	layer.add_child(idle_button)
	_mode_button = Button.new()
	_mode_button.text = "Mode: select / move"
	_mode_button.custom_minimum_size = Vector2(190, 56)
	_mode_button.position = Vector2(12, 40)
	_mode_button.pressed.connect(func() -> void:
		mode = (mode + 1) % MODE_NAMES.size() as Mode
		_mode_button.text = "Mode: " + MODE_NAMES[mode])
	layer.add_child(_mode_button)
	_rotate_button = Button.new()
	_rotate_button.text = "Rotate (T)"
	_rotate_button.custom_minimum_size = Vector2(190, 56)
	_rotate_button.position = Vector2(12, 104)
	_rotate_button.pressed.connect(_rotate_brick)
	layer.add_child(_rotate_button)


func _pick(screen_pos: Vector2) -> Dictionary:
	var cam := rig.camera
	return world.raycast(cam.project_ray_origin(screen_pos), cam.project_ray_normal(screen_pos), 300.0, bricks.occupied)


func _update_hover() -> void:
	# The pointer is the mouse or the last finger on the screen (the viewport's mouse position stays at 0,0 on touch).
	var hit := _pick(rig.pointer)
	_hover.visible = not hit.is_empty() and not _is_brick_mode()
	_ghost.visible = false
	_stock_ghost.visible = false
	_cell_info.text = "" if hit.is_empty() else _describe_cell(hit.cell, hit.brick)
	if (mode == Mode.STOCKPILE or mode == Mode.FRAME) and not hit.is_empty() and not hit.brick:
		var origin: Vector3i = hit.cell + hit.normal if not Blocks.is_partial(world.get_block(hit.cell)) else hit.cell
		var why := Stockpile.can_place(world, bricks, origin, economy.stockpiles)
		_stock_ghost.visible = true
		_stock_ghost.position = Vector3(origin.x + 1.0, origin.y + 0.1, origin.z + 1.0)
		(_stock_ghost.material_override as StandardMaterial3D).albedo_color = Color(0.2, 0.9, 0.3, 0.5) if why == "" else Color(0.95, 0.2, 0.2, 0.5)
		if why != "":
			_cell_info.text += "  |  stockpile: " + why
	if hit.is_empty():
		return
	if _hover.visible:
		_hover.position = Vector3(hit.cell) + Vector3.ONE * 0.5
	if _is_brick_mode():
		var origin: Vector3i = hit.cell + hit.normal
		_ghost.visible = true
		var length := _brick_length()
		(_ghost.mesh as BoxMesh).size = Vector3(length, 1, 1) * 1.02
		var turned := length == 2 and brick_axis == 1
		_ghost.transform = Transform3D(Basis(Vector3.UP, PI * 0.5 if turned else 0.0), BrickWorld.center_for(origin, brick_axis, length))
		var ok := bricks.can_place(origin, brick_axis, length)
		_ghost_mat.albedo_color = Color(0.2, 0.9, 0.9, 0.45) if ok else Color(0.95, 0.2, 0.2, 0.5)


## For bug reports: where the cursor is and what the ground there is.
func _describe_cell(cell: Vector3i, brick: bool) -> String:
	if brick:
		return "cell %s: brick" % str(cell)
	var raw := world.get_block(cell)
	var kind := "whole"
	if Blocks.is_dug(raw):
		kind = "half dug"
	elif Blocks.is_partial(raw):
		kind = "slope " + str(Blocks.corner_heights(Blocks.shape(raw)))
	return "cell %s: material %d, %s, column level %d" % [str(cell), Blocks.mat(raw), kind, world.terrain.level(cell.x, cell.z)]


func _on_primary(pos: Vector2) -> void:
	var u := units.unit_at(pos, rig.camera) if mode == Mode.SELECT else null
	if u != null:
		# Tapping the only selected unit again puts it away; any other tap picks that unit.
		if units.selection.size() == 1 and units.selection[0] == u:
			units.clear_selection()
		else:
			units.select_only(u)
		return
	var hit := _pick(pos)
	if hit.is_empty():
		return
	match mode:
		Mode.SELECT:
			_command_move(hit)
		Mode.MARK_DIG:
			_mark_dig(hit.cell.x, hit.cell.z, hit.cell.x, hit.cell.z)
		Mode.STOCKPILE, Mode.FRAME:
			_place_stockpile(hit)
		Mode.DIG:
			if hit.brick:
				bricks.remove(bricks.brick_at(hit.cell))
			else:
				world.terrain.dig_step(hit.cell)
		Mode.VOXEL:
			# Clicking a slope or a half-dug block fills that very cell up to a whole block; anything else builds next to it.
			var target: Vector3i = hit.cell if not Blocks.is_whole(world.get_block(hit.cell)) else hit.cell + hit.normal
			world.terrain.build(target, Blocks.STONE)
		_:
			bricks.place(hit.cell + hit.normal, brick_axis, _brick_kind(), _brick_length())


## Long press / right click: the command. Move the selection there; with nothing selected, in any tool mode, remove what is there.
func _on_secondary(pos: Vector2) -> void:
	var hit := _pick(pos)
	if hit.is_empty():
		return
	if not units.selection.is_empty():
		_command_move(hit)
	elif mode != Mode.SELECT:
		if hit.brick:
			bricks.remove(bricks.brick_at(hit.cell))
		else:
			world.terrain.dig_step(hit.cell)


func _command_move(hit: Dictionary) -> void:
	if units.selection.is_empty() or hit.brick:
		return
	var goal := units.nav.standing_for_hit(hit)
	if goal.x >= 0:
		units.command_move(goal)


func _on_double(pos: Vector2) -> void:
	if mode == Mode.SELECT and units.unit_at(pos, rig.camera) != null:
		units.select_all()   # double tap on a unit: every unit (there is only one kind so far)


func _on_box(rect: Rect2) -> void:
	_selection_box.hide_rect()
	if mode == Mode.MARK_DIG:
		# The corners of the box on the ground give the area to dig.
		var lo := Vector2i(1 << 30, 1 << 30)
		var hi := Vector2i(-(1 << 30), -(1 << 30))
		for p in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
			var h := _pick(p)
			if not h.is_empty():
				lo = Vector2i(mini(lo.x, h.cell.x), mini(lo.y, h.cell.z))
				hi = Vector2i(maxi(hi.x, h.cell.x), maxi(hi.y, h.cell.z))
		if hi.x >= lo.x:
			_mark_dig(lo.x, lo.y, hi.x, hi.y)
		return
	units.select_rect(rect, rig.camera, Input.is_key_pressed(KEY_SHIFT))


## Marks ground to be dug and puts the selected units (or, with nothing selected, the idle ones) on it.
func _set_depth(d: int) -> void:
	_dig_depth = clampi(d, 1, 12)
	_depth_label.text = "depth %d" % _dig_depth


func _mark_dig(x0: int, z0: int, x1: int, z1: int) -> void:
	var t := board.create_dig(x0, z0, x1, z1, _dig_depth)
	if t == null:
		return
	var crew: Array = units.selection if not units.selection.is_empty() else units.units.filter(func(u: Unit) -> bool: return u.is_idle())
	for u in crew:
		board.assign(u, t)


func _place_stockpile(hit: Dictionary) -> void:
	var origin: Vector3i = hit.cell + hit.normal if not Blocks.is_partial(world.get_block(hit.cell)) else hit.cell
	var style := Stockpile.Style.FRAME if mode == Mode.FRAME else Stockpile.Style.PLATFORM
	if not hit.brick and economy.place_stockpile(origin, style) == null:
		_cell_info.text = "Cannot place a stockpile here: " + economy.last_error


func _refresh_tasks_panel() -> void:
	for c in _tasks_panel.get_children():
		c.queue_free()
	for t in board.tasks:
		var row := HBoxContainer.new()
		if t is DigTask:
			for kind in Resources.DIGGABLE:
				var f := Button.new()
				f.toggle_mode = true
				f.button_pressed = t.collects(kind)
				f.text = Resources.label(kind)
				f.tooltip_text = "Bring %s home (off: break it and throw it away)" % Resources.label(kind).to_lower()
				f.custom_minimum_size = Vector2(0, 48)
				f.toggled.connect(func(on: bool) -> void: t.collect[kind] = on)
				row.add_child(f)
		var b := Button.new()
		b.text = t.summary() + ("" if t.persistent else "  (assign selected)")
		b.custom_minimum_size = Vector2(0, 48)
		b.disabled = t.persistent
		b.pressed.connect(func() -> void:
			var crew: Array = units.selection if not units.selection.is_empty() else units.units.filter(func(u: Unit) -> bool: return u.is_idle())
			for u in crew:
				board.assign(u, t))
		row.add_child(b)
		var x := Button.new()
		x.text = "X"
		x.custom_minimum_size = Vector2(48, 48)
		x.pressed.connect(func() -> void: board.remove_task(t))
		row.add_child(x)
		_tasks_panel.add_child(row)


func _refresh_stock_label() -> void:
	var lines := PackedStringArray(["Stockpiles: %d" % economy.stockpiles.size()])
	var tot := economy.totals()
	for k in tot:
		lines.append("%s: %d bags" % [Resources.label(k), tot[k]])
	if economy.packed_bricks > 0:
		lines.append("Stone bricks stacked: %d" % economy.packed_bricks)
	_stock_label.text = "\n".join(lines)
