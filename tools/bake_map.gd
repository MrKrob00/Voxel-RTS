extends SceneTree
## Generates the map and saves it as a scene of meshes that opens in the editor ready made (no generation when it is opened):
##   godot --headless --path . -s res://tools/bake_map.gd -- --seed=1337 --out=res://maps/plains
## Writes <out>/chunks/Chunk_x_y_z.res (the meshes), <out>/solid.tres and <out>/water.tres (the two materials) and <out>/map.tscn.
## Only the look of the ground is kept (no game data); `scenes/map_view.tscn` shows it.

const WORLD_SCRIPT := preload("res://scripts/world/voxel_world.gd")

var _world: Node3D
var _seed := 1337
var _out := "res://maps/plains"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.get_slice("=", 1))
		elif a.begins_with("--out="):
			_out = a.get_slice("=", 1)
	_run.call_deferred()


func _run() -> void:
	_world = WORLD_SCRIPT.new()
	_world.world_seed = _seed
	root.add_child(_world)
	var frames := 0
	while not _world.is_settled() and frames < 60000:
		await process_frame
		frames += 1
	print("generated after %d frames: %s" % [frames, _world.stats()])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out + "/chunks"))
	var solid: Material = DayCycle.world_material()
	var water: Material = DayCycle.world_material(false, true)
	ResourceSaver.save(solid, _out + "/solid.tres")
	ResourceSaver.save(water, _out + "/water.tres")
	var solid_res := load(_out + "/solid.tres")
	var water_res := load(_out + "/water.tres")
	var map := Node3D.new()
	map.name = "BakedMap"
	var n := 0
	var bytes := 0
	for child in _world.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var mesh := mi.mesh as ArrayMesh
		var surface_materials: Array[Material] = []
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i)
			surface_materials.append(m)
			mesh.surface_set_material(i, null)        # the materials are shared files, not copies inside every mesh
		var path := "%s/chunks/%s.res" % [_out, mi.name]
		ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
		bytes += FileAccess.get_file_as_bytes(path).size()
		var node := MeshInstance3D.new()
		node.name = mi.name
		node.mesh = load(path)
		node.position = mi.position
		for i in surface_materials.size():
			var is_water: bool = surface_materials[i] != null and (surface_materials[i] as ShaderMaterial).get_shader_parameter("alpha") != null
			node.set_surface_override_material(i, water_res if is_water else solid_res)
		map.add_child(node)
		node.owner = map
		n += 1
	var scene := PackedScene.new()
	scene.pack(map)
	ResourceSaver.save(scene, _out + "/map.tscn")
	print("baked %d chunks, %.1f MB of meshes" % [n, bytes / 1048576.0])
	quit()
