extends Node3D
## Sandbox scene: world + RTS camera + a tiny dig/place tool to exercise voxel editing.

var preset := MapPreset.plains()
var world: VoxelWorld
var props: PropField
var rig: RTSCamera
const START_UNITS := 5

var bricks: BrickWorld
var units: UnitManager
var economy: Economy
var colliders: GroundColliders
var loose: LooseItems
var board: TaskBoard
var _stock_ghost: MeshInstance3D
var _dig_depth := 1
var hud: Hud
var mode: int = Tools.Mode.SELECT
var brick_axis := 0
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D

var _hover: MeshInstance3D


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

	colliders = GroundColliders.new()
	colliders.name = "GroundColliders"
	add_child(colliders)
	colliders.setup(world)
	bricks = BrickWorld.new()
	bricks.name = "Bricks"
	add_child(bricks)
	bricks.setup(world, colliders)
	loose = LooseItems.new()
	loose.name = "LooseItems"
	add_child(loose)
	loose.setup(world, colliders)

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
	rig.box_changed.connect(func(r: Rect2) -> void: hud.selection_box.show_rect(r))
	rig.box_cancelled.connect(func() -> void: hud.selection_box.hide_rect())
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
	units.nav.obstacle = economy.blocks_cell
	board.setup(world, units.nav, economy, props, loose, units)
	board.changed.connect(_refresh_tasks_panel)
	economy.changed.connect(_refresh_stock_label)
	world.generation_finished.connect(_spawn_units, CONNECT_ONE_SHOT)

	_setup_hover()
	_setup_ui()
	add_child(load("res://scripts/tools/screenshot.gd").new())


var _panel_timer := 0.0


func _process(delta: float) -> void:
	_panel_timer -= delta
	if _panel_timer <= 0.0:
		_panel_timer = 0.5
		_refresh_tasks_panel()
		_refresh_units_label()
	hud.set_status("%d fps | %s | bricks %d" % [Engine.get_frames_per_second(), world.stats(), bricks.brick_count()])
	_update_hover()


func _spawn_units() -> void:
	var sp := world.spawn_point()
	var start := units.nav.nearest_standable(Vector3i(sp.x, sp.y + 1, sp.z), 4)
	if start.x >= 0:
		units.spawn_squad(start, START_UNITS, 2)
	_place_starting_buildings(sp)


## The game starts with a plank platform and a stump with an axe near the spawn crystal (nothing pays for them).
func _place_starting_buildings(sp: Vector3i) -> void:
	var was := economy.charge_for_stockpiles
	economy.charge_for_stockpiles = false
	var placed_platform := false
	var placed_stump := false
	for r in range(4, 10):
		for step in 16:
			var a := TAU * step / 16.0
			var cx := sp.x + roundi(cos(a) * r)
			var cz := sp.z + roundi(sin(a) * r)
			var origin := Vector3i(cx, world.surface_y(cx, cz) + 1, cz)
			if not placed_platform and economy.place_stockpile(origin, Stockpile.Style.PLATFORM) != null:
				placed_platform = true
			elif placed_platform and not placed_stump and board.place_station(Station.Kind.STUMP, origin, false) != null:
				placed_stump = true
		if placed_stump:
			break
	economy.charge_for_stockpiles = was


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
	return mode >= Tools.Mode.STONE_BRICK


func _brick_length() -> int:
	return 1 if mode == Tools.Mode.STONE_CUBE or mode == Tools.Mode.WOOD_CUBE else 2


func _brick_kind() -> int:
	return BrickWorld.Kind.STONE if mode == Tools.Mode.STONE_BRICK or mode == Tools.Mode.STONE_CUBE else BrickWorld.Kind.WOOD


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
	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.tool_chosen.connect(_choose_tool)
	hud.level_changed.connect(_set_depth)
	hud.select_all_pressed.connect(func() -> void: units.select_all())
	hud.select_idle_pressed.connect(func() -> void: units.select_idle())
	hud.turn_pressed.connect(_rotate_brick)
	hud.home_pressed.connect(func() -> void:
		var sp := world.spawn_point()
		rig.focus = Vector3(sp.x, sp.y, sp.z))
	hud.task_assign.connect(func(t: WorkTask) -> void: _assign_crew(t))
	hud.task_cancel.connect(_cancel_task)
	hud.task_select.connect(func(t: WorkTask) -> void: units._set_selection(t.workers.duplicate()))
	hud.collect_toggled.connect(func(t: DigTask, kind: int, on: bool) -> void: t.collect[kind] = on)
	units.selection_changed.connect(func(_s: Array) -> void: _refresh_units_label())
	_set_depth(1)
	_refresh_units_label()
	_refresh_stock_label()


func _choose_tool(m: int) -> void:
	mode = m
	hud.set_tool(m)
	_set_depth(_dig_depth)   # the limit of the level depends on the tool


func _assign_crew(t: WorkTask) -> void:
	var crew: Array = units.selection if not units.selection.is_empty() else units.units.filter(func(u: Unit) -> bool: return u.is_idle())
	for u in crew:
		board.assign(u, t)


func _cancel_task(t: WorkTask) -> void:
	if t is BuildTask:
		board.cancel_blueprint(t.blueprint)
	else:
		board.remove_task(t)   # a wall's plan goes with its job


func _refresh_units_label() -> void:
	var idle := 0
	for u in units.units:
		if u.is_idle() and board.task_of(u) == null:
			idle += 1
	hud.set_units(units.units.size(), idle, units.selection.size())


func _pick(screen_pos: Vector2) -> Dictionary:
	var cam := rig.camera
	return world.raycast(cam.project_ray_origin(screen_pos), cam.project_ray_normal(screen_pos), 300.0, bricks.occupied)


func _update_hover() -> void:
	# The pointer is the mouse or the last finger on the screen (the viewport's mouse position stays at 0,0 on touch).
	var hit := _pick(rig.pointer)
	_hover.visible = not hit.is_empty() and not _is_brick_mode()
	_ghost.visible = false
	_stock_ghost.visible = false
	var info := "" if hit.is_empty() else _describe_cell(hit.cell, hit.brick)
	if (mode == Tools.Mode.STOCKPILE or mode == Tools.Mode.FRAME or mode == Tools.Mode.STUMP or mode == Tools.Mode.ROPE_MACHINE) and not hit.is_empty() and not hit.brick:
		var origin: Vector3i = hit.cell + hit.normal if not Blocks.is_partial(world.get_block(hit.cell)) else hit.cell
		var why := ""
		var gsize := Vector2(Stockpile.SIZE, Stockpile.SIZE)
		if mode == Tools.Mode.STUMP or mode == Tools.Mode.ROPE_MACHINE:
			var sk := Station.Kind.STUMP if mode == Tools.Mode.STUMP else Station.Kind.ROPE_MACHINE
			why = Station.can_place(world, bricks, sk, origin, economy.stockpiles + economy.blueprints, economy.stations)
			gsize = Vector2(Station.DEFS[sk].size)
		else:
			why = Stockpile.can_place(world, bricks, origin, economy.stockpiles + economy.blueprints)
		(_stock_ghost.mesh as BoxMesh).size = Vector3(gsize.x, 0.2, gsize.y)
		_stock_ghost.visible = true
		_stock_ghost.position = Vector3(origin.x + gsize.x * 0.5, origin.y + 0.1, origin.z + gsize.y * 0.5)
		(_stock_ghost.material_override as StandardMaterial3D).albedo_color = Color(0.2, 0.9, 0.3, 0.5) if why == "" else Color(0.95, 0.2, 0.2, 0.5)
		if why != "":
			info += "  |  cannot stand here: " + why
	hud.set_cell_info(info)
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


## The station standing at the tapped cell (or just under the tapped one).
func _station_at(hit: Dictionary) -> Station:
	for st in economy.stations:
		if st.covers(hit.cell) or st.covers(hit.cell + Vector3i(0, 1, 0)):
			return st
	return null


## The round menu of a station: switch its production on or off.
func _station_menu(st: Station) -> void:
	var d := st.def()
	var cost := "%d %s -> %d %s" % [d.input.amount, Resources.label(d.input.kind).to_lower(), d.output.amount, Resources.label(d.output.kind).to_lower()]
	var items := [
		{"mode": Tools.Mode.STUMP if st.kind == Station.Kind.STUMP else Tools.Mode.ROPE_MACHINE, "label": "Produce", "active": st.enabled,
			"call": func() -> void: _set_station(st, true)},
		{"mode": Tools.STOP, "label": "Stop", "active": not st.enabled, "call": func() -> void: _set_station(st, false)},
	]
	hud.open_radial(rig.camera.unproject_position(st.center() + Vector3(0.0, 1.0, 0.0)), d.verb, d.about, cost, items)


func _set_station(st: Station, on: bool) -> void:
	st.enabled = on
	hud.show_message("%s: %s" % [st.def().name, "working while there is stock and room" if on else "stopped"])
	_refresh_tasks_panel()


func _on_primary(pos: Vector2) -> void:
	var u := units.unit_at(pos, rig.camera) if mode == Tools.Mode.SELECT else null
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
		Tools.Mode.SELECT:
			var st := _station_at(hit)
			if st != null:
				_station_menu(st)
			else:
				_command_move(hit)
		Tools.Mode.MARK_DIG:
			_mark_dig(hit.cell.x, hit.cell.z, hit.cell.x, hit.cell.z)
		Tools.Mode.MARK_TREES:
			_mark_harvest(HarvestTask.Kind.TREES, Rect2(hit.cell.x - 1.0, hit.cell.z - 1.0, 3.0, 3.0))
		Tools.Mode.MARK_GRASS:
			_mark_harvest(HarvestTask.Kind.GRASS, Rect2(hit.cell.x - 1.0, hit.cell.z - 1.0, 3.0, 3.0))
		Tools.Mode.STOCKPILE, Tools.Mode.FRAME:
			_place_stockpile(hit)
		Tools.Mode.STUMP, Tools.Mode.ROPE_MACHINE:
			_place_station(hit)
		Tools.Mode.WALL:
			_plan_wall(hit, hit)
		Tools.Mode.CUBE:
			_plan_wall(hit, hit, 1)
		Tools.Mode.BRICK:
			_plan_brick(hit, _axis_step())
		Tools.Mode.STAIRS:
			_plan_stairs(hit, _axis_step())
		Tools.Mode.DIG:
			if hit.brick:
				bricks.remove(bricks.brick_at(hit.cell))
			else:
				world.terrain.dig_step(hit.cell)
		Tools.Mode.VOXEL:
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
	elif mode != Tools.Mode.SELECT:
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
	if mode == Tools.Mode.SELECT and units.unit_at(pos, rig.camera) != null:
		units.select_all()   # double tap on a unit: every unit (there is only one kind so far)


func _on_box(rect: Rect2) -> void:
	hud.selection_box.hide_rect()
	if mode == Tools.Mode.MARK_TREES or mode == Tools.Mode.MARK_GRASS:
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
			var h := _pick(p)
			if not h.is_empty():
				lo = Vector2(minf(lo.x, h.cell.x), minf(lo.y, h.cell.z))
				hi = Vector2(maxf(hi.x, h.cell.x + 1.0), maxf(hi.y, h.cell.z + 1.0))
		if hi.x > lo.x:
			_mark_harvest(HarvestTask.Kind.TREES if mode == Tools.Mode.MARK_TREES else HarvestTask.Kind.GRASS, Rect2(lo, hi - lo))
		return
	if mode == Tools.Mode.WALL or mode == Tools.Mode.BRICK or mode == Tools.Mode.STAIRS:
		var a := _pick(rect.position)
		var b := _pick(rect.end)
		if a.is_empty() or b.is_empty():
			return
		if mode == Tools.Mode.WALL:
			_plan_wall(a, b)
		else:
			# The way of the drag, along the longer side, says how the brick lies / which way the stairs rise.
			var d := Vector2i(b.cell.x - a.cell.x, b.cell.z - a.cell.z)
			var dir := (Vector2i(signi(d.x), 0) if absi(d.x) >= absi(d.y) else Vector2i(0, signi(d.y)))
			if dir == Vector2i.ZERO:
				dir = _axis_step()
			if mode == Tools.Mode.BRICK:
				_plan_brick(a, dir)
			else:
				_plan_stairs(a, dir)
		return
	if mode == Tools.Mode.MARK_DIG:
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
## Marks trees or grass in a rectangle and puts the selected units (or the idle ones) on it.
func _mark_harvest(kind: int, rect: Rect2) -> void:
	var t := board.create_harvest(kind, rect)
	if t == null:
		hud.show_message("Nothing to harvest there")
		return
	var crew: Array = units.selection if not units.selection.is_empty() else units.units.filter(func(u: Unit) -> bool: return u.is_idle())
	for u in crew:
		board.assign(u, t)


func _place_station(hit: Dictionary) -> void:
	var origin: Vector3i = hit.cell + hit.normal if not Blocks.is_partial(world.get_block(hit.cell)) else hit.cell
	var kind := Station.Kind.STUMP if mode == Tools.Mode.STUMP else Station.Kind.ROPE_MACHINE
	if not hit.brick and board.place_blueprint("station", kind, origin) == null:
		hud.show_message("Cannot plan it here: " + economy.last_error)


func _set_depth(d: int) -> void:
	var top := WallPlan.MAX_COURSES if mode == Tools.Mode.WALL else 12
	_dig_depth = clampi(d, 1, top)
	hud.set_level(_dig_depth)


## Plans a wall from the cell above the first point to the cell above the second, as many courses high as the level says (at most 3).
func _axis_step() -> Vector2i:
	return Vector2i(1, 0) if brick_axis == 0 else Vector2i(0, 1)


func _cell_above(hit: Dictionary) -> Vector3i:
	return hit.cell + hit.normal if not Blocks.is_partial(world.get_block(hit.cell)) else hit.cell


## One stone brick 2 x 1 x 1, lying along `dir` (a unit step in x or z) from the cell above the point.
func _plan_brick(a: Dictionary, dir: Vector2i) -> void:
	if a.brick:
		return
	var from := _cell_above(a)
	if board.place_wall(from, from + Vector3i(dir.x, 0, dir.y), 1) == null:
		hud.show_message("Cannot plan a brick here: " + economy.last_error)


## A stair block 2 x 1 x 1: steps in the cell above the point, rising `dir` towards a whole stone cube.
func _plan_stairs(a: Dictionary, dir: Vector2i) -> void:
	if a.brick:
		return
	if board.place_stairs(_cell_above(a), dir) == null:
		hud.show_message("Cannot plan stairs here: " + economy.last_error)


func _plan_wall(a: Dictionary, b: Dictionary, height := -1) -> void:
	if a.brick or b.brick:
		return
	var from: Vector3i = a.cell + a.normal if not Blocks.is_partial(world.get_block(a.cell)) else a.cell
	var to_cell: Vector3i = b.cell + b.normal if not Blocks.is_partial(world.get_block(b.cell)) else b.cell
	to_cell.y = from.y
	if board.place_wall(from, to_cell, _dig_depth if height < 0 else height) == null:
		hud.show_message("Cannot plan a wall here: " + economy.last_error)


func _mark_dig(x0: int, z0: int, x1: int, z1: int) -> void:
	var t := board.create_dig(x0, z0, x1, z1, _dig_depth)
	if t == null:
		return
	var crew: Array = units.selection if not units.selection.is_empty() else units.units.filter(func(u: Unit) -> bool: return u.is_idle())
	for u in crew:
		board.assign(u, t)


func _place_stockpile(hit: Dictionary) -> void:
	var origin: Vector3i = hit.cell + hit.normal if not Blocks.is_partial(world.get_block(hit.cell)) else hit.cell
	var style := Stockpile.Style.FRAME if mode == Tools.Mode.FRAME else Stockpile.Style.PLATFORM
	if not hit.brick and board.place_blueprint("stockpile", style, origin) == null:
		hud.show_message("Cannot plan a stockpile here: " + economy.last_error)


func _refresh_tasks_panel() -> void:
	hud.set_tasks(board.tasks)


func _refresh_stock_label() -> void:
	var lines := {}
	var tot := economy.totals()
	for k in tot:
		if k == Resources.Kind.BRICK:
			lines["Stone bricks"] = "%.1f" % (tot[k] / 2.0)
		else:
			lines[Resources.label(k)] = tot[k]
	hud.set_resources(lines)
