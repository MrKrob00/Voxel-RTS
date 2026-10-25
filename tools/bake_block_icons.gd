extends SceneTree
## Photographs every block of the catalog (assets/blocks/<id>.obj) in a small studio and saves assets/blocks/icons/<id>.png, which the
## palette shows. Run after changing a block:
##   godot --path . --rendering-driver opengl3 -s res://tools/bake_block_icons.gd      (needs a display: xvfb-run -a ... on a server)
## The pictures are kept in the repository: the palette does not draw anything itself.

const PX := 128
const IDS_FROM := "res://assets/blocks"
const STONE := Color(0.62, 0.62, 0.62)
const WOOD := Color(0.72, 0.50, 0.27)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/blocks/icons"))
	var sv := SubViewport.new()
	sv.size = Vector2i(PX, PX)
	sv.transparent_bg = true
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sv)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.72, 0.75)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	sv.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42.0, -38.0, 0.0)
	key.light_energy = 1.0
	sv.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-14.0, 140.0, 0.0)
	fill.light_energy = 0.35
	sv.add_child(fill)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	sv.add_child(cam)
	var dir := DirAccess.open(IDS_FROM)
	var names: Array[String] = []
	for f in dir.get_files():
		if f.ends_with(".obj"):
			names.append(f.get_basename())
	names.sort()
	for id in names:
		var mesh := load("%s/%s.obj" % [IDS_FROM, id]) as Mesh
		if mesh == null:
			push_error("cannot load " + id)
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var m := StandardMaterial3D.new()
		var wood := id in ["log", "beam", "post", "brace", "board", "plank", "plank_small"]
		m.albedo_color = WOOD if wood else STONE
		m.roughness = 0.9
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = m
		sv.add_child(mi)
		# The same view and the same scale for every block, as the original's panel has: a little from the right of the front, about
		# 28 degrees above the ground, the middle of the block in the middle of the picture.
		var az := deg_to_rad(45.0)
		var el := deg_to_rad(22.0)
		var d := Vector3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
		cam.look_at_from_position(d * 10.0, Vector3.ZERO, Vector3.UP)
		cam.size = 3.1
		cam.near = 0.1
		cam.far = 30.0
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		sv.get_texture().get_image().save_png("res://assets/blocks/icons/%s.png" % id)
		mi.queue_free()
	print("baked %d icons" % names.size())
	quit()
