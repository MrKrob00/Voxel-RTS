class_name GroundOccluder
extends Node3D
## The engine's own occlusion culling (a small depth picture drawn on the CPU from occluders, and everything behind it is not drawn) with
## one occluder for the whole ground: the lowest ground of every STEP x STEP squares, one block under it, as a mesh. It lies under the
## true ground everywhere, so it never hides anything that can be seen, and it hides what lies behind hills pixel by pixel, which the
## ridge test (HorizonCulling) only does for whole chunks. Needs `rendering/occlusion_culling/use_occlusion_culling` (project settings);
## where the engine has no occlusion culling it does nothing.

const STEP := 4
const UNDER := 1.0
const REBUILD_PAUSE := 2.0

var _world: VoxelWorld
var _occluder := ArrayOccluder3D.new()
var _instance := OccluderInstance3D.new()
var _dirty_at := -1.0
var _busy := false
var _done := false
var _verts := PackedVector3Array()
var _indices := PackedInt32Array()
var _poll := 0.0


func setup(world: VoxelWorld) -> void:
	_world = world
	_instance.occluder = _occluder
	add_child(_instance)
	world.block_changed.connect(func(_p: Vector3i) -> void: _dirty_at = Time.get_ticks_msec() / 1000.0)
	_dirty_at = Time.get_ticks_msec() / 1000.0


func _process(delta: float) -> void:
	if _done:
		_done = false
		_busy = false
		_occluder.set_arrays(_verts, _indices)
	_poll -= delta
	if _poll > 0.0 or _busy or _world == null or not _world.column_levels_ready:
		return
	_poll = 0.5
	if _dirty_at > 0.0 and Time.get_ticks_msec() / 1000.0 - _dirty_at > REBUILD_PAUSE:
		_dirty_at = -1.0
		_busy = true
		WorkerThreadPool.add_task(_build)


func _build() -> void:
	var out := make_arrays(_world.column_levels, _world.size_blocks().x, _world.size_blocks().z)
	_verts = out[0]
	_indices = out[1]
	_done = true


## [vertices, indices] of the occluder over a map of this size. Pure function (see the test).
static func make_arrays(levels: PackedInt32Array, width: int, depth: int) -> Array:
	var cw := width / STEP
	var cd := depth / STEP
	var heights := PackedFloat32Array()
	heights.resize((cw + 1) * (cd + 1))
	for j in cd + 1:
		for i in cw + 1:
			var low := 1.0e9
			for dz in range(-STEP / 2, STEP / 2 + 1):
				for dx in range(-STEP / 2, STEP / 2 + 1):
					var x := clampi(i * STEP + dx, 0, width - 1)
					var z := clampi(j * STEP + dz, 0, depth - 1)
					var level := levels[x + z * width]
					low = 0.0 if level <= 0 else minf(low, float(level) / Blocks.UNIT)
			heights[i + j * (cw + 1)] = maxf(low - UNDER, 0.0)
	var verts := PackedVector3Array()
	verts.resize((cw + 1) * (cd + 1))
	for j in cd + 1:
		for i in cw + 1:
			verts[i + j * (cw + 1)] = Vector3(i * STEP, heights[i + j * (cw + 1)], j * STEP)
	var indices := PackedInt32Array()
	for j in cd:
		for i in cw:
			var a := i + j * (cw + 1)
			var b := a + 1
			var d := a + cw + 1
			var c := d + 1
			if heights[a] > 0.0 and heights[b] > 0.0 and heights[c] > 0.0 and heights[d] > 0.0:   # (where the ground ends there is none)
				indices.append_array([a, b, c, a, c, d])
	return [verts, indices]
