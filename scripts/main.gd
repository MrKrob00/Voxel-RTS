extends Node3D
## Sandbox scene: world + RTS camera + a tiny dig/place tool to exercise voxel editing.

var world: VoxelWorld
var rig: RTSCamera
var placing := false

var _hover: MeshInstance3D
var _info: Label
var _mode_button: Button


func _ready() -> void:
	_setup_environment()

	world = VoxelWorld.new()
	world.name = "World"
	add_child(world)

	rig = RTSCamera.new()
	rig.name = "Camera"
	var s := world.size_blocks()
	rig.bounds = Rect2(0, 0, s.x, s.z)
	rig.focus = Vector3(s.x * 0.5, 24, s.z * 0.5)
	rig.ground_height = world.surface_y
	add_child(rig)
	rig.primary_action.connect(_on_primary)
	rig.secondary_action.connect(_on_secondary)

	_setup_hover()
	_setup_ui()


func _process(_delta: float) -> void:
	_info.text = "%d fps | %s | %s" % [Engine.get_frames_per_second(), world.stats(), "place" if placing else "dig"]
	_update_hover()


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("9cc7ee")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.76, 0.85)
	env.ambient_light_energy = 0.9
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.light_energy = 0.7
	add_child(sun)


func _setup_hover() -> void:
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
	_mode_button.text = "Dig / Place"
	_mode_button.custom_minimum_size = Vector2(150, 56)
	_mode_button.position = Vector2(12, 40)
	_mode_button.pressed.connect(func() -> void: placing = not placing)
	layer.add_child(_mode_button)


func _pick(screen_pos: Vector2) -> Dictionary:
	var cam := rig.camera
	return world.raycast(cam.project_ray_origin(screen_pos), cam.project_ray_normal(screen_pos), 300.0)


func _update_hover() -> void:
	# Hover only makes sense with a mouse; on touch the cursor is parked at the last click.
	var hit := _pick(get_viewport().get_mouse_position())
	_hover.visible = not hit.is_empty()
	if _hover.visible:
		_hover.position = Vector3(hit.cell) + Vector3.ONE * 0.5


func _on_primary(pos: Vector2) -> void:
	var hit := _pick(pos)
	if hit.is_empty():
		return
	if placing:
		world.set_block(hit.cell + hit.normal, Blocks.STONE)
	elif Blocks.is_diggable(hit.id):
		world.set_block(hit.cell, Blocks.AIR)


func _on_secondary(pos: Vector2) -> void:
	var hit := _pick(pos)
	if not hit.is_empty():
		world.set_block(hit.cell + hit.normal, Blocks.STONE)
