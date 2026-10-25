extends Node3D
## The scene with just the generated map (scenes/map_view.tscn): the world, the sky, the sun and the camera, no game on top. Run it
## (F6) to fly over the map: change `world_seed`, `extra_islands` or the size on the World node first to see another one.
## Debug (after `--`): --overview=/path.png flies high above the map, saves a picture when it is built, and quits.

@onready var world: VoxelWorld = $World
@onready var rig: RTSCamera = $Camera


func _ready() -> void:
	var s := world.size_blocks()
	rig.bounds = Rect2(0, 0, s.x, s.z)
	rig.ground_height = world.surface_y
	world.generation_finished.connect(_on_built, CONNECT_ONE_SHOT)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			world.world_seed = int(a.get_slice("=", 1))


func _on_built() -> void:
	var sp := world.spawn_point()
	rig.focus = Vector3(sp.x, sp.y, sp.z)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--overview="):
			rig.focus = Vector3(s_half(world.size_blocks().x), 40.0, s_half(world.size_blocks().z))
			rig.distance = rig.max_distance
			rig.pitch = deg_to_rad(68.0)
			rig.yaw = 0.0
			_save_overview(a.get_slice("=", 1))


func s_half(v: int) -> float:
	return v * 0.5


func _save_overview(path: String) -> void:
	for i in 240:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
