extends Node
## Debug helper: godot --path . --rendering-driver opengl3 res://scenes/main.tscn -- --shot=/path.png
## Waits for the world, saves one frame and quits. Only active when --shot= is given.

func _ready() -> void:
	var path := ""
	var zoom := 0.0
	var focus := Vector2(-1, -1)
	var digs: Array[Vector3i] = []   # (x, z, stages): dig the top block of that column before the shot
	var pitch := -1.0
	var yaw := -1000.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			path = a.substr(7)
		elif a.begins_with("--focus="):
			var parts := a.substr(8).split(",")
			focus = Vector2(float(parts[0]), float(parts[1]))
		elif a.begins_with("--dig="):
			var d := a.substr(6).split(",")
			digs.append(Vector3i(int(d[0]), int(d[1]), int(d[2]) if d.size() > 2 else 1))
		elif a.begins_with("--pitch="):
			pitch = float(a.substr(8))
		elif a.begins_with("--yaw="):
			yaw = float(a.substr(6))
		elif a.begins_with("--zoom="):
			zoom = float(a.substr(7))
	if path == "":
		queue_free()
		return
	var world: VoxelWorld = get_parent().get("world")
	while not world.is_ready():
		await get_tree().process_frame
	for _i in 10:
		await get_tree().process_frame
	for d in digs:
		var terrain: TerrainEdit = world.terrain
		var lv0 := terrain.level(d.x, d.y)
		var cell := Vector3i(d.x, lv0 / Blocks.UNIT - 1, d.y)   # the top whole block; it stays the same cell through its stages
		for _s in d.z:
			terrain.dig_step(cell)
	if focus.x >= 0.0:
		get_parent().get("rig").focus = Vector3(focus.x, 50, focus.y)
	if pitch >= 0.0:
		get_parent().get("rig").pitch = deg_to_rad(pitch)
	if yaw > -999.0:
		get_parent().get("rig").yaw = deg_to_rad(yaw)
	if zoom > 0.0:
		get_parent().get("rig").distance = zoom
	for i in 400:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
