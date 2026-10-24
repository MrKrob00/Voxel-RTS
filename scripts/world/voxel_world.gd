class_name VoxelWorld
extends Node3D
## Finite voxel world split into 16^3 chunks. Generation and meshing run on WorkerThreadPool;
## the main thread only commits finished meshes (budgeted per frame) and applies edits.
## No physics colliders: picking and (later) unit pathfinding query voxel data directly.

signal generation_finished
signal chunk_meshed(cpos: Vector3i)

@export var size_chunks := Vector3i(8, 4, 8)
@export var world_seed := 1337
## Meshes committed to the scene per frame. Lower is smoother on tablets.
@export var meshes_per_frame := 6
@export var max_tasks_in_flight := 4

var generator: WorldGen

class Chunk extends RefCounted:
	var cpos: Vector3i
	var data := PackedByteArray()
	var generated := false
	var dirty := true
	var meshing := false
	var instance: MeshInstance3D

	func _init(p: Vector3i) -> void:
		cpos = p


var _chunks := {}
var _gen_queue: Array[Chunk] = []
var _gen_in_flight := 0
var _gen_total := 0
var _gen_done_count := 0
var _finished_signalled := false
var _mesh_in_flight := 0

var _mutex := Mutex.new()
var _gen_results: Array = []
var _mesh_results: Array = []

var _solid_chunk := PackedByteArray()
var _solid_material: StandardMaterial3D
var _water_material: StandardMaterial3D


func _ready() -> void:
	_solid_chunk.resize(Blocks.CHUNK_VOLUME)
	_solid_chunk.fill(Blocks.STONE)
	_solid_material = StandardMaterial3D.new()
	_solid_material.vertex_color_use_as_albedo = true
	_solid_material.roughness = 1.0
	_water_material = StandardMaterial3D.new()
	_water_material.vertex_color_use_as_albedo = true
	_water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_water_material.albedo_color = Color(1, 1, 1, 0.62)
	_water_material.roughness = 0.3
	start()


## Size of the world in blocks.
func size_blocks() -> Vector3i:
	return size_chunks * Blocks.CHUNK_SIZE


func start() -> void:
	generator = WorldGen.new(world_seed, size_blocks().y)
	_gen_total = size_chunks.x * size_chunks.y * size_chunks.z
	# Generate from the middle of the map outwards so the visible area appears first.
	var centre := Vector3(size_chunks) * 0.5
	var list: Array[Chunk] = []
	for cy in size_chunks.y:
		for cz in size_chunks.z:
			for cx in size_chunks.x:
				var c := Chunk.new(Vector3i(cx, cy, cz))
				_chunks[c.cpos] = c
				list.append(c)
	list.sort_custom(func(a: Chunk, b: Chunk) -> bool:
		return (Vector3(a.cpos) - centre).length_squared() < (Vector3(b.cpos) - centre).length_squared())
	_gen_queue = list


func is_ready() -> bool:
	return _finished_signalled


func in_bounds(p: Vector3i) -> bool:
	var s := size_blocks()
	return p.x >= 0 and p.y >= 0 and p.z >= 0 and p.x < s.x and p.y < s.y and p.z < s.z


func get_block(p: Vector3i) -> int:
	if not in_bounds(p):
		return Blocks.AIR
	var c: Chunk = _chunks.get(Vector3i(p.x >> 4, p.y >> 4, p.z >> 4))
	if c == null or not c.generated:
		return Blocks.AIR
	return c.data[(p.x & 15) + ((p.z & 15) << 4) + ((p.y & 15) << 8)]


func set_block(p: Vector3i, id: int) -> bool:
	if not in_bounds(p):
		return false
	var cpos := Vector3i(p.x >> 4, p.y >> 4, p.z >> 4)
	var c: Chunk = _chunks.get(cpos)
	if c == null or not c.generated:
		return false
	var idx := (p.x & 15) + ((p.z & 15) << 4) + ((p.y & 15) << 8)
	if c.data[idx] == id:
		return false
	c.data[idx] = id
	# The chunk and any neighbour whose faces or ambient occlusion can see this voxel need a remesh.
	var lx := p.x & 15
	var ly := p.y & 15
	var lz := p.z & 15
	for dy in _edge_offsets(ly):
		for dz in _edge_offsets(lz):
			for dx in _edge_offsets(lx):
				var n: Chunk = _chunks.get(cpos + Vector3i(dx, dy, dz))
				if n != null:
					n.dirty = true
					_try_mesh(n)
	return true


static func _edge_offsets(local: int) -> Array[int]:
	if local == 0:
		return [0, -1]
	if local == 15:
		return [0, 1]
	return [0]


## Top solid voxel y of a column, or -1 if the column is not generated / empty.
func surface_y(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= size_blocks().x or z >= size_blocks().z:
		return -1
	for y in range(size_blocks().y - 1, -1, -1):
		if Blocks.is_solid(get_block(Vector3i(x, y, z))):
			return y
	return -1


## Voxel DDA ray. Returns {} on a miss, else {cell, normal, id, distance}.
func raycast(origin: Vector3, dir: Vector3, max_dist := 200.0) -> Dictionary:
	dir = dir.normalized()
	var cell := Vector3i(floori(origin.x), floori(origin.y), floori(origin.z))
	var step := Vector3i(int(signf(dir.x)), int(signf(dir.y)), int(signf(dir.z)))
	var t_max := Vector3(INF, INF, INF)
	var t_delta := Vector3(INF, INF, INF)
	for a in 3:
		if dir[a] != 0.0:
			var next_bound: float = float(cell[a] + (1 if step[a] > 0 else 0))
			t_max[a] = (next_bound - origin[a]) / dir[a]
			t_delta[a] = absf(1.0 / dir[a])
	var normal := Vector3i.ZERO
	var dist := 0.0
	while dist <= max_dist:
		var id := get_block(cell)
		if Blocks.is_solid(id):
			return {"cell": cell, "normal": normal, "id": id, "distance": dist}
		var axis := 0
		if t_max.y < t_max.x:
			axis = 1
		if t_max.z < t_max[axis]:
			axis = 2
		dist = t_max[axis]
		cell[axis] += step[axis]
		t_max[axis] += t_delta[axis]
		normal = Vector3i.ZERO
		normal[axis] = -step[axis]
	return {}


func stats() -> String:
	return "chunks %d/%d gen, tasks %d" % [_gen_done_count, _gen_total, _gen_in_flight + _mesh_in_flight]


# --- pipeline -----------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	_drain_generated()
	_feed_generation()
	_drain_meshed()


func _feed_generation() -> void:
	while _gen_in_flight + _mesh_in_flight < max_tasks_in_flight and not _gen_queue.is_empty():
		var c: Chunk = _gen_queue.pop_front()
		_gen_in_flight += 1
		WorkerThreadPool.add_task(_gen_task.bind(c))


func _gen_task(c: Chunk) -> void:
	var d := generator.generate_chunk(c.cpos)
	_mutex.lock()
	_gen_results.append([c, d])
	_mutex.unlock()


func _drain_generated() -> void:
	_mutex.lock()
	var results := _gen_results
	_gen_results = []
	_mutex.unlock()
	for r in results:
		var c: Chunk = r[0]
		c.data = r[1]
		c.generated = true
		_gen_in_flight -= 1
		_gen_done_count += 1
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var n: Chunk = _chunks.get(c.cpos + Vector3i(dx, dy, dz))
					if n != null:
						_try_mesh(n)
	if not _finished_signalled and _gen_done_count == _gen_total:
		_finished_signalled = true
		generation_finished.emit()


func _try_mesh(c: Chunk) -> void:
	if c.meshing or not c.dirty or not c.generated:
		return
	# Wait for every neighbour so border faces are not drawn against ungenerated (empty) space.
	var snap := []
	snap.resize(27)
	for dy in range(-1, 2):
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var np := c.cpos + Vector3i(dx, dy, dz)
				var slot := (dx + 1) + (dz + 1) * 3 + (dy + 1) * 9
				var n: Chunk = _chunks.get(np)
				if n == null:
					# Below the world counts as solid (hides bottom faces), everywhere else as open air.
					snap[slot] = _solid_chunk if np.y < 0 else PackedByteArray()
				elif not n.generated:
					return
				else:
					snap[slot] = n.data
	c.dirty = false
	c.meshing = true
	_mesh_in_flight += 1
	WorkerThreadPool.add_task(_mesh_task.bind(c, snap))


func _mesh_task(c: Chunk, snap: Array) -> void:
	var out := ChunkMesher.build(snap, c.cpos * Blocks.CHUNK_SIZE)
	_mutex.lock()
	_mesh_results.append([c, out])
	_mutex.unlock()


func _drain_meshed() -> void:
	_mutex.lock()
	var take := mini(meshes_per_frame, _mesh_results.size())
	var results := _mesh_results.slice(0, take)
	_mesh_results = _mesh_results.slice(take)
	_mutex.unlock()
	for r in results:
		var c: Chunk = r[0]
		var out: Array = r[1]
		c.meshing = false
		_mesh_in_flight -= 1
		_commit_mesh(c, out)
		chunk_meshed.emit(c.cpos)
		if c.dirty:
			_try_mesh(c)


func _commit_mesh(c: Chunk, out: Array) -> void:
	if out[0] == null and out[1] == null:
		if c.instance != null:
			c.instance.queue_free()
			c.instance = null
		return
	var mesh := ArrayMesh.new()
	if out[0] != null:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out[0])
		mesh.surface_set_material(mesh.get_surface_count() - 1, _solid_material)
	if out[1] != null:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out[1])
		mesh.surface_set_material(mesh.get_surface_count() - 1, _water_material)
	if c.instance == null:
		c.instance = MeshInstance3D.new()
		c.instance.position = Vector3(c.cpos * Blocks.CHUNK_SIZE)
		c.instance.name = "Chunk_%d_%d_%d" % [c.cpos.x, c.cpos.y, c.cpos.z]
		add_child(c.instance)
	c.instance.mesh = mesh
