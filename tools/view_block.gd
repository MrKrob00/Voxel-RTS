extends SceneTree
## Renders one block from six sides into PNGs (for looking at a shape and agreeing on its front):
##   godot --path . --rendering-driver opengl3 -s res://tools/view_block.gd -- --id=stairs --out=/some/dir
## front = seen from +z, back = from -z, left = from -x, right = from +x, top, iso. The block lies along x.

const PX := 320


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var id := "stairs"
	var out := "/tmp"
	var turn := 0.0                       # --turn=-90: the block turned about y (degrees)
	var only := ""                        # --only=iso: just that view
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--id="):
			id = a.get_slice("=", 1)
		elif a.begins_with("--out="):
			out = a.get_slice("=", 1)
		elif a.begins_with("--turn="):
			turn = float(a.get_slice("=", 1))
		elif a.begins_with("--only="):
			only = a.get_slice("=", 1)
	var sv := SubViewport.new()
	sv.size = Vector2i(PX, PX)
	sv.transparent_bg = false
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sv)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.14, 0.17)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.75, 0.78)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	sv.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42.0, -38.0, 0.0)
	sv.add_child(key)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 3.0
	sv.add_child(cam)
	var mi := MeshInstance3D.new()
	mi.mesh = load("res://assets/blocks/%s.obj" % id) as Mesh
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.66, 0.66, 0.66)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.rotation_degrees.y = turn
	sv.add_child(mi)
	var views := {
		"front": Vector3(0, 0.0, 1), "back": Vector3(0, 0.0, -1), "left": Vector3(-1, 0.0, 0), "right": Vector3(1, 0.0, 0),
		"top": Vector3(0, 1, 0.001), "iso": Vector3(0.656, 0.375, 0.656),
	}
	for v in views:
		if only != "" and v != only:
			continue
		var up := Vector3.UP if v != "top" else Vector3(0, 0, -1)
		cam.look_at_from_position(views[v].normalized() * 10.0, Vector3.ZERO, up)
		cam.near = 0.1
		cam.far = 30.0
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		sv.get_texture().get_image().save_png("%s/%s_%s%s.png" % [out, id, v, "" if turn == 0.0 else "_turn%d" % int(turn)])
	quit()
