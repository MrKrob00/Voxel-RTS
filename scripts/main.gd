extends Node3D
## Sandbox scene: world + RTS camera + a tiny dig/place tool to exercise voxel editing.

var preset := MapPreset.plains()
var world: VoxelWorld
var props: PropField
var rig: RTSCamera
enum Mode { DIG, VOXEL, STONE_BRICK, STONE_CUBE, WOOD_BRICK, WOOD_CUBE }
const MODE_NAMES := ["dig", "voxel", "stone brick 2x1x1", "stone cube 1x1x1", "wood brick 2x1x1", "wood cube 1x1x1"]

var bricks: BrickWorld
var mode := Mode.DIG
var brick_axis := 0
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _rotate_button: Button

var _hover: MeshInstance3D
var _info: Label
var _mode_button: Button


func _ready() -> void:
	_setup_environment()

	world = VoxelWorld.new()
	world.name = "World"
	world.preset = preset
	add_child(world)

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

	_setup_hover()
	_setup_ui()
	add_child(load("res://scripts/tools/screenshot.gd").new())


func _process(_delta: float) -> void:
	_info.text = "%d fps | %s | %s | bricks %d, debris %d" % [Engine.get_frames_per_second(), world.stats(), MODE_NAMES[mode], bricks.brick_count(), bricks.debris_count()]
	_update_hover()


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
	_mode_button = Button.new()
	_mode_button.text = "Mode: dig"
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
	# Hover only makes sense with a mouse; on touch the cursor is parked at the last click.
	var hit := _pick(get_viewport().get_mouse_position())
	_hover.visible = not hit.is_empty() and not _is_brick_mode()
	_ghost.visible = false
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


func _on_primary(pos: Vector2) -> void:
	var hit := _pick(pos)
	if hit.is_empty():
		return
	match mode:
		Mode.DIG:
			if hit.brick:
				bricks.remove(bricks.brick_at(hit.cell))
			elif Blocks.is_diggable(hit.id):
				world.set_block(hit.cell, Blocks.AIR)
		Mode.VOXEL:
			world.place_block(hit.cell + hit.normal, Blocks.STONE)
		_:
			bricks.place(hit.cell + hit.normal, brick_axis, _brick_kind(), _brick_length())


func _on_secondary(pos: Vector2) -> void:
	# Right click always removes what is under the cursor (a brick or a voxel), dig mode or not.
	var hit := _pick(pos)
	if hit.is_empty():
		return
	if hit.brick:
		bricks.remove(bricks.brick_at(hit.cell))
	elif Blocks.is_diggable(hit.id):
		world.set_block(hit.cell, Blocks.AIR)
