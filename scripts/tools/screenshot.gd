extends Node
## Debug helper: godot --path . --rendering-driver opengl3 res://scenes/main.tscn -- --shot=/path.png
## Waits for the world, saves one frame and quits. Only active when --shot= is given.

func _ready() -> void:
	var path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			path = a.substr(7)
	if path == "":
		queue_free()
		return
	var world: VoxelWorld = get_parent().get("world")
	while not world.is_ready():
		await get_tree().process_frame
	for i in 240:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
