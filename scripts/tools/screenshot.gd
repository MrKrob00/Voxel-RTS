extends Node
## Debug helper: godot --path . --rendering-driver opengl3 res://scenes/main.tscn -- --shot=/path.png
## Waits for the world, saves one frame and quits. Only active when --shot= is given.

func _ready() -> void:
	var path := ""
	var zoom := 0.0
	var focus := Vector2(-1, -1)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			path = a.substr(7)
		elif a.begins_with("--focus="):
			var parts := a.substr(8).split(",")
			focus = Vector2(float(parts[0]), float(parts[1]))
		elif a.begins_with("--zoom="):
			zoom = float(a.substr(7))
	if path == "":
		queue_free()
		return
	var world: VoxelWorld = get_parent().get("world")
	while not world.is_ready():
		await get_tree().process_frame
	if focus.x >= 0.0:
		get_parent().get("rig").focus = Vector3(focus.x, 50, focus.y)
	if zoom > 0.0:
		get_parent().get("rig").distance = zoom
	for i in 400:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
