extends Node3D
## Sandbox scene: world + RTS camera + a tiny dig/place tool to exercise voxel editing.

var preset := MapPreset.plains()
var world: VoxelWorld
var props: PropField
var rig: RTSCamera
enum Mode { SELECT, DIG, VOXEL, STONE_BRICK, STONE_CUBE, WOOD_BRICK, WOOD_CUBE }
const MODE_NAMES := ["select / move", "dig", "build ground", "stone brick 2x1x1", "stone cube 1x1x1", "wood brick 2x1x1", "wood cube 1x1x1"]
const START_UNITS := 5

var bricks: BrickWorld
var units: UnitManager
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
	world.generation_finished.connect(_spawn_units, CONNECT_ONE_SHOT)

	_setup_hover()
	_setup_ui()
	add_child(load("res://scripts/tools/screenshot.gd").new())


func _process(_delta: float) -> void:
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
	var all_button := Button.new()
	all_button.text = "All units"
	all_button.custom_minimum_size = Vector2(190, 56)
	all_button.position = Vector2(12, 232)
	all_button.pressed.connect(func() -> void: units.select_all())
	layer.add_child(all_button)
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
	_cell_info.text = "" if hit.is_empty() else _describe_cell(hit.cell, hit.brick)
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
	units.select_rect(rect, rig.camera, Input.is_key_pressed(KEY_SHIFT))
