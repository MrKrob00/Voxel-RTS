class_name PropField
extends Node3D
## Scatters trees, boulders, orange crystals and grass over the generated world and draws each kind with one MultiMesh.
## The scatter is a pure function of the seed (same world, same trees) and runs on a worker thread.

const STEP := 2   ## one candidate spot per STEP x STEP blocks

var world: VoxelWorld
var _task_id := -1
var _result := {}
var _mutex := Mutex.new()
var _done := false


func setup(w: VoxelWorld) -> void:
	world = w
	world.generation_finished.connect(_on_world_ready)


func _on_world_ready() -> void:
	_task_id = WorkerThreadPool.add_task(_scatter)


func _process(_delta: float) -> void:
	if not _done:
		return
	_mutex.lock()
	var res := _result
	_mutex.unlock()
	_done = false
	_build(res)
	set_process(false)


func _scatter() -> void:
	var gen := world.generator
	var preset := world.preset
	var size := world.size_blocks()
	var rng := RandomNumberGenerator.new()
	rng.seed = world.world_seed * 7919 + 13
	var forest := WorldGen._make_noise(world.world_seed + 21, 0.045, 2)
	var rocky := WorldGen._make_noise(world.world_seed + 22, 0.06, 1)
	var spawn := world.spawn_point()
	var isl: WorldGen.Island = gen.islands[0]
	var keep_clear := isl.radius * 0.16   # no trees on the first build spot
	var out := {"pine": [], "boulder": [], "crystal": [], "tuft": []}
	var per_cell := float(STEP * STEP) / 100.0
	for z in range(1, size.z - 1, STEP):
		for x in range(1, size.x - 1, STEP):
			var col := gen.column(x, z)
			if col.x < 0:
				continue
			var top := col.x
			var wx := x + rng.randf_range(0.0, STEP)
			var wz := z + rng.randf_range(0.0, STEP)
			var ix := int(wx)
			var iz := int(wz)
			var c := gen.column(ix, iz)
			if c.x < 0:
				continue
			top = c.x
			if gen.block_at(ix, top, iz, top, c.y) != preset.top_block:
				continue
			# Slope: props only on gentle ground.
			var slope := 0
			for d in [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2)]:
				var n := gen.column(ix + d.x, iz + d.y)
				slope = maxi(slope, absi((n.x if n.x >= 0 else top - 9) - top))
			var pos := Vector3(wx, top + 1.0, wz)
			var near_spawn := Vector2(wx - spawn.x, wz - spawn.z).length() < keep_clear
			var f := smoothstep(0.0, 0.4, forest.get_noise_2d(wx, wz))
			if slope <= 1 and not near_spawn and rng.randf() < preset.tree_density * per_cell * f * 3.0:
				out.pine.append(_xform(pos, rng, 0.85, 1.4))
			elif slope <= 2 and not near_spawn and rocky.get_noise_2d(wx, wz) > 0.1 and rng.randf() < preset.boulder_density * per_cell * 5.0:
				out.boulder.append(_xform(pos, rng, 0.7, 1.6))
			elif slope <= 1 and rng.randf() < preset.plant_density * per_cell * (0.6 + f):
				out.tuft.append(_xform(pos, rng, 0.8, 1.3))
			# Orange crystals sit at the foot of a cliff: the ground next to a much higher column.
			if slope >= 3 and not near_spawn and rng.randf() < preset.crystal_density * per_cell * 6.0:
				out.crystal.append(_xform(pos, rng, 0.8, 1.3))
	_mutex.lock()
	_result = out
	_mutex.unlock()
	_done = true


func _xform(pos: Vector3, rng: RandomNumberGenerator, smin: float, smax: float) -> Transform3D:
	var s := rng.randf_range(smin, smax)
	var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.9, 1.15), s))
	return Transform3D(basis, pos)


func _build(res: Dictionary) -> void:
	var specs := {
		"pine": [Props.pine(), Props.material(false)],
		"boulder": [Props.boulder(3), Props.material(false)],
		"crystal": [Props.crystals(), Props.material(false)],
		"tuft": [Props.tuft(), Props.material(true)],
	}
	for kind in specs:
		var list: Array = res.get(kind, [])
		if list.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = specs[kind][0]
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])
		var inst := MultiMeshInstance3D.new()
		inst.name = kind.capitalize()
		inst.multimesh = mm
		inst.material_override = specs[kind][1]
		add_child(inst)


func counts() -> Dictionary:
	var d := {}
	for c in get_children():
		if c is MultiMeshInstance3D:
			d[c.name] = (c as MultiMeshInstance3D).multimesh.instance_count
	return d
