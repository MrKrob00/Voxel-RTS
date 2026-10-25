extends Node3D
## The scene with the baked map (scenes/map_view.tscn): the ground as it was generated (maps/plains/map.tscn, made by
## tools/bake_map.gd), the sky, the sun and a camera. Nothing is generated when it opens, in the editor or when it runs: run it (F6)
## to fly over the map. Debug (after `--`): --overview=/path.png flies high above the map, saves a picture and quits.

@onready var rig: RTSCamera = $Camera


func _ready() -> void:
	rig.bounds = Rect2(0, 0, 448, 448)
	rig.focus = Vector3(224.0, 48.0, 224.0)
	rig.distance = 120.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--overview="):
			rig.distance = rig.max_distance
			rig.pitch = deg_to_rad(68.0)
			rig.yaw = 0.0
			_save_overview(a.get_slice("=", 1))


func _save_overview(path: String) -> void:
	for i in 60:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
