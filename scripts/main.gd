extends Node3D
## Sandbox scene: world + RTS camera + a tiny dig/place tool to exercise voxel editing.

## The game scene (scenes/main.tscn): every part is a node there, with its own settings in the inspector; this script only wires them
## together and carries out what the player does.
@onready var world: VoxelWorld = $World
@onready var colliders: GroundColliders = $GroundColliders
@onready var bricks: BrickWorld = $Bricks
@onready var loose: LooseItems = $LooseItems
@onready var rig: RTSCamera = $Camera
@onready var units: UnitManager = $Units
@onready var economy: Economy = $Economy
@onready var board: TaskBoard = $Tasks
@onready var _aim: AimPreview = $AimPreview
@onready var hud: Hud = $Hud
@onready var day: DayCycle = $DayCycle
var props: PropField          # null when started with --noprops
const START_UNITS := 5

var _stock_ghost: MeshInstance3D
var _dig_depth := 1
var mode: int = Tools.Mode.SELECT
var brick_axis := 0
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D

var _hover: MeshInstance3D


## Debug switches for the command line (after `--`): --extras=0..4 more islands, --seed=N, --noprops. Applied before the world starts.
func _enter_tree() -> void:
	var w := get_node_or_null("World") as VoxelWorld
	if w == null:
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--extras="):
			w.extra_islands = int(arg.substr(9))
		elif arg.begins_with("--seed="):
			w.world_seed = int(arg.substr(7))


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--noprops"):   # debug: terrain only
		$Props.queue_free()
	else:
		props = $Props
		props.setup(world)
	colliders.setup(world)
	bricks.setup(world, colliders)
	loose.setup(world, colliders)

	var s := world.size_blocks()
	var spawn := world.spawn_point()
	rig.bounds = Rect2(0, 0, s.x, s.z)
	rig.focus = Vector3(spawn.x, spawn.y, spawn.z)
	rig.ground_height = world.surface_y
	rig.primary_action.connect(_on_primary)
	rig.secondary_action.connect(_on_secondary)
	rig.double_action.connect(_on_double)
	rig.box_changed.connect(func(r: Rect2) -> void: hud.selection_box.show_rect(r))
	rig.box_cancelled.connect(func() -> void: hud.selection_box.hide_rect())
	rig.box_finished.connect(_on_box)
	rig.drag_changed.connect(_on_aim_changed)
	rig.drag_finished.connect(_on_aim_finished)
	rig.drag_cancelled.connect(func() -> void: _aim.clear())

	units.setup(world, bricks)
	economy.setup(world, bricks)
	units.nav.obstacle = economy.blocks_cell
	board.setup(world, units.nav, economy, props, loose, units)
	board.changed.connect(_refresh_tasks_panel)
	economy.changed.connect(_refresh_stock_label)
	world.generation_finished.connect(_spawn_units, CONNECT_ONE_SHOT)

	_setup_hover()
	_setup_ui()
	day.clock_changed.connect(func(text: String) -> void: hud.set_clock(text))
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
			if not placed_platform and economy.place_stockpile(origin) != null:
				placed_platform = true
			elif placed_platform and not placed_stump and board.place_station(Station.Kind.STUMP, origin, false) != null:
				placed_stump = true
		if placed_stump:
			break
	economy.charge_for_stockpiles = was


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		_rotate_brick()


func _rotate_brick() -> void:
	brick_axis = (brick_axis + 1) % 4   # 0..3: +x, +z, -x, -z (the sandbox bricks use only the axis)


func _is_brick_mode() -> bool:
	return mode in [Tools.Mode.STONE_BRICK, Tools.Mode.STONE_CUBE, Tools.Mode.WOOD_BRICK, Tools.Mode.WOOD_CUBE]


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
	hud.task_radius.connect(func(t: HarvestTask, d: float) -> void:
		t.set_radius(t.radius + d, board)
		_refresh_tasks_panel())
	hud.task_select.connect(func(t: WorkTask) -> void: units._set_selection(t.workers.duplicate()))
	hud.collect_toggled.connect(func(t: DigTask, kind: int, on: bool) -> void: t.collect[kind] = on)
	units.selection_changed.connect(func(_s: Array) -> void: _refresh_units_label())
	_set_depth(1)
	_refresh_units_label()
	_refresh_stock_label()


func _choose_tool(m: int) -> void:
	mode = m
	rig.drag_mode = _is_aim_tool()
	_aim.clear()
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
	if (mode == Tools.Mode.STOCKPILE or mode == Tools.Mode.STUMP or mode == Tools.Mode.ROPE_MACHINE) and not hit.is_empty() and not hit.brick:
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
		var turned := length == 2 and brick_axis % 2 == 1
		_ghost.transform = Transform3D(Basis(Vector3.UP, PI * 0.5 if turned else 0.0), BrickWorld.center_for(origin, brick_axis % 2, length))
		var ok := bricks.can_place(origin, brick_axis % 2, length)
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
	if Tools.is_block(mode):
		_plan_block(hit, _axis_step())
		return
	match mode:
		Tools.Mode.SELECT:
			var st := _station_at(hit)
			if st != null and not st.def().get("auto", true):
				_station_menu(st)   # a stump works by itself: only what is switched on by hand has a menu
			else:
				_command_move(hit)
		Tools.Mode.MARK_DIG:
			_mark_dig(hit.cell.x, hit.cell.z, hit.cell.x, hit.cell.z)
		Tools.Mode.MARK_TREES:
			_mark_harvest(HarvestTask.Kind.TREES, Vector2(hit.cell.x + 0.5, hit.cell.z + 0.5), 4.0)
		Tools.Mode.MARK_GRASS:
			_mark_harvest(HarvestTask.Kind.GRASS, Vector2(hit.cell.x + 0.5, hit.cell.z + 0.5), 4.0)
		Tools.Mode.STOCKPILE:
			_place_stockpile(hit)
		Tools.Mode.STUMP, Tools.Mode.ROPE_MACHINE:
			_place_station(hit)
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
			bricks.place(hit.cell + hit.normal, brick_axis % 2, _brick_kind(), _brick_length())


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
	units.select_rect(rect, rig.camera, Input.is_key_pressed(KEY_SHIFT))


## Tools that are aimed by dragging from one point on the ground to another (the camera is moved with two fingers meanwhile).
func _is_aim_tool() -> bool:
	return Tools.is_block(mode) or mode in [Tools.Mode.MARK_DIG, Tools.Mode.MARK_TREES, Tools.Mode.MARK_GRASS]


## The finger moves: what the order would be, drawn through the blocks.
func _on_aim_changed(from: Vector2, to: Vector2) -> void:
	var a := _pick(from)
	var b := _pick(to)
	if a.is_empty() or b.is_empty():
		return
	match mode:
		Tools.Mode.MARK_DIG:
			var n := _aim.show_dig(world, a.cell.x, a.cell.z, b.cell.x, b.cell.z, _dig_depth)
			var w := absi(a.cell.x - b.cell.x) + 1
			var d := absi(a.cell.z - b.cell.z) + 1
			hud.show_message("%d x %d, %d deep: %d blocks" % [w, d, _dig_depth, n])
		Tools.Mode.MARK_TREES, Tools.Mode.MARK_GRASS:
			_aim.show_ring(world, Vector2(a.cell.x + 0.5, a.cell.z + 0.5), _aim_radius(a, b))


func _aim_radius(a: Dictionary, b: Dictionary) -> float:
	return clampf(Vector2(a.cell.x - b.cell.x, a.cell.z - b.cell.z).length(), HarvestTask.MIN_RADIUS, HarvestTask.MAX_RADIUS)


func _on_aim_finished(from: Vector2, to: Vector2) -> void:
	_aim.clear()
	var a := _pick(from)
	var b := _pick(to)
	if a.is_empty() or b.is_empty():
		return
	if Tools.is_block(mode):
		# The way of the drag, along the longer side, says how the block lies / which way it rises.
		var d := Vector2i(b.cell.x - a.cell.x, b.cell.z - a.cell.z)
		var dir := (Vector2i(signi(d.x), 0) if absi(d.x) >= absi(d.y) else Vector2i(0, signi(d.y)))
		_plan_block(a, _axis_step() if dir == Vector2i.ZERO else dir)
		return
	match mode:
		Tools.Mode.MARK_DIG:
			_mark_dig(mini(a.cell.x, b.cell.x), mini(a.cell.z, b.cell.z), maxi(a.cell.x, b.cell.x), maxi(a.cell.z, b.cell.z))
		Tools.Mode.MARK_TREES:
			_mark_harvest(HarvestTask.Kind.TREES, Vector2(a.cell.x + 0.5, a.cell.z + 0.5), _aim_radius(a, b))
		Tools.Mode.MARK_GRASS:
			_mark_harvest(HarvestTask.Kind.GRASS, Vector2(a.cell.x + 0.5, a.cell.z + 0.5), _aim_radius(a, b))


## A standing harvest job over a circle: idle units come to it by themselves, and it stays until it is closed.
func _mark_harvest(kind: int, center: Vector2, radius: float) -> void:
	if board.create_harvest_circle(kind, center, radius) == null:
		hud.show_message("Nothing to harvest here yet")


func _place_station(hit: Dictionary) -> void:
	var origin: Vector3i = hit.cell + hit.normal if not Blocks.is_partial(world.get_block(hit.cell)) else hit.cell
	var kind := Station.Kind.STUMP if mode == Tools.Mode.STUMP else Station.Kind.ROPE_MACHINE
	if not hit.brick and board.place_blueprint("station", kind, origin) == null:
		hud.show_message("Cannot plan it here: " + economy.last_error)


func _set_depth(d: int) -> void:
	_dig_depth = clampi(d, 1, 12)
	hud.set_level(_dig_depth)


## Plans a wall from the cell above the first point to the cell above the second, as many courses high as the level says (at most 3).
func _axis_step() -> Vector2i:
	return [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)][brick_axis]


func _cell_above(hit: Dictionary) -> Vector3i:
	return hit.cell + hit.normal if not Blocks.is_partial(world.get_block(hit.cell)) else hit.cell


## One block of the catalog on the cell above the point, lying along `dir`.
func _plan_block(a: Dictionary, dir: Vector2i) -> void:
	if a.brick and not Tools.is_block(mode):
		return
	var id := Tools.block_of(mode)
	if board.place_block(id, _cell_above(a), dir) == null:
		hud.show_message("Cannot plan it here: " + economy.last_error)


func _mark_dig(x0: int, z0: int, x1: int, z1: int) -> void:
	var t := board.create_dig(x0, z0, x1, z1, _dig_depth)
	if t == null:
		return
	var crew: Array = units.selection if not units.selection.is_empty() else units.units.filter(func(u: Unit) -> bool: return u.is_idle())
	for u in crew:
		board.assign(u, t)


func _place_stockpile(hit: Dictionary) -> void:
	var origin: Vector3i = hit.cell + hit.normal if not Blocks.is_partial(world.get_block(hit.cell)) else hit.cell
	if not hit.brick and board.place_blueprint("stockpile", 0, origin) == null:
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
