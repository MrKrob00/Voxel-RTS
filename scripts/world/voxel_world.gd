class_name VoxelWorld
extends Node3D
## Finite voxel world split into 16^3 chunks: storage, generation, meshing and picking. It knows nothing about game rules
## (what digging or building means): those live in TerrainEdit, reachable as `terrain`, and in BrickWorld.
##
## Pipeline: generation and meshing run on WorkerThreadPool; the main thread commits finished meshes.
##  - Initial meshes are committed with a per-frame budget (smooth start-up on tablets).
##  - Every edit bumps the version of the chunks it touches. All chunks touched during one frame form an EDIT GROUP
##    whose new meshes are committed together in a single frame, so a changed block and the slopes around it never
##    show up one after the other.
## No physics colliders: picking and unit pathfinding query voxel data directly.

signal generation_finished
signal chunk_meshed(cpos: Vector3i)
signal block_changed(pos: Vector3i)

@export var size_chunks := Vector3i(28, 7, 28)   ## 448 x 112 x 448 blocks, about 3x the area of the first 256 x 256 map
@export var world_seed := 1337
## -1 = random from the seed; 0-4 forces the number of extra islands (the map always has one main island).
@export var extra_islands := -1
## Initial meshes committed to the scene per frame. Lower is smoother on tablets.
@export var meshes_per_frame := 6
@export var max_tasks_in_flight := 48

var generator: WorldGen
## Set before the node enters the tree to pick another map type.
var preset: MapPreset = MapPreset.plains()
## What digging and building do to the ground (stages, slopes). Created in _ready.
var terrain: TerrainEdit

class Chunk extends RefCounted:
	var cpos: Vector3i
	var data := PackedInt32Array()   ## empty = nothing but open sky
	var generated := false
	var version := 0                 ## bumped by every change of this chunk or of a voxel its mesh can see
	var built := -1                  ## the version the displayed mesh was built from
	var meshing := false
	var instance: MeshInstance3D
	var in_group := false            ## member of the open edit group
	var pending: Variant = null      ## finished mesh arrays waiting for the rest of the group

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

var _touched := {}                  ## chunks changed since the last frame: cpos -> Chunk
var _group := {}                    ## the open edit group: Chunk -> true
var _commit_queue: Array = []       ## chunks whose initial mesh waits for the per-frame budget (mesh in Chunk.pending)

var _solid_material: StandardMaterial3D
var _water_material: StandardMaterial3D


func _ready() -> void:
	_solid_material = StandardMaterial3D.new()
	_solid_material.vertex_color_use_as_albedo = true
	_solid_material.roughness = 1.0
	_water_material = StandardMaterial3D.new()
	_water_material.vertex_color_use_as_albedo = true
	_water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_water_material.albedo_color = Color(1, 1, 1, 0.62)
	_water_material.roughness = 0.3
	terrain = TerrainEdit.new(self)
	start()


## Size of the world in blocks.
func size_blocks() -> Vector3i:
	return size_chunks * Blocks.CHUNK_SIZE


func start() -> void:
	generator = WorldGen.new(world_seed, size_blocks(), preset, extra_islands)
	var sc := generator.spawn_column()
	preset.clear_center = Vector2(sc.x + 0.5, sc.y + 0.5)
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


## The voxel at a position (see Blocks for the format); AIR outside the world and in chunks not generated yet.
func get_block(p: Vector3i) -> int:
	if not in_bounds(p):
		return Blocks.AIR
	var c: Chunk = _chunks.get(Vector3i(p.x >> 4, p.y >> 4, p.z >> 4))
	if c == null or not c.generated or c.data.is_empty():
		return Blocks.AIR
	return c.data[(p.x & 15) + ((p.z & 15) << 4) + ((p.y & 15) << 8)]


## Writes one voxel and schedules the remesh of every chunk that can see it. Pure storage: the rules of digging and
## building, and the slopes that depend on neighbours, are TerrainEdit's job.
func set_block(p: Vector3i, raw: int) -> bool:
	if not in_bounds(p):
		return false
	var cpos := Vector3i(p.x >> 4, p.y >> 4, p.z >> 4)
	var c: Chunk = _chunks.get(cpos)
	if c == null or not c.generated:
		return false
	if c.data.is_empty():
		if raw == Blocks.AIR:
			return false
		c.data.resize(Blocks.CHUNK_VOLUME)
		c.data.fill(Blocks.AIR)
	var idx := (p.x & 15) + ((p.z & 15) << 4) + ((p.y & 15) << 8)
	if c.data[idx] == raw:
		return false
	c.data[idx] = raw
	block_changed.emit(p)
	# The chunk and any neighbour whose faces or ambient occlusion can see this voxel need a new mesh.
	var lx := p.x & 15
	var ly := p.y & 15
	var lz := p.z & 15
	for dy in _edge_offsets(ly):
		for dz in _edge_offsets(lz):
			for dx in _edge_offsets(lx):
				var n: Chunk = _chunks.get(cpos + Vector3i(dx, dy, dz))
				if n != null:
					n.version += 1
					n.pending = null
					_touched[n.cpos] = n
	return true


static func _edge_offsets(local: int) -> Array[int]:
	if local == 0:
		return [0, -1]
	if local == 15:
		return [0, 1]
	return [0]


## A spot on the start island with the y of the top block, for the camera and the first units.
func spawn_point() -> Vector3i:
	var xz := generator.spawn_column()
	return Vector3i(xz.x, generator.column(xz.x, xz.y).x, xz.y)


## Top solid voxel y of a column, or -1 if the column is not generated / empty.
func surface_y(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= size_blocks().x or z >= size_blocks().z:
		return -1
	for y in range(size_blocks().y - 1, -1, -1):
		if Blocks.is_solid(get_block(Vector3i(x, y, z))):
			return y
	return -1


## Voxel DDA ray. Returns {} on a miss, else {cell, normal, id, brick, distance}.
## `extra_solid(cell) -> bool` lets other systems (bricks) take part in the same ray; such a hit has "brick": true.
func raycast(origin: Vector3, dir: Vector3, max_dist := 200.0, extra_solid := Callable()) -> Dictionary:
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
		var raw := get_block(cell)
		var is_brick: bool = extra_solid.is_valid() and extra_solid.call(cell)
		if is_brick or Blocks.is_solid(raw):
			return {"cell": cell, "normal": normal, "id": Blocks.AIR if is_brick else raw, "brick": is_brick, "distance": dist}
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


## True when no chunk is waiting for, or building, a newer mesh (edits have fully shown up).
func is_settled() -> bool:
	return _touched.is_empty() and _group.is_empty() and _mesh_in_flight == 0 and _commit_queue.is_empty()


# --- pipeline -----------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	_drain_generated()
	_feed_generation()
	_open_edit_group()
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


## Everything edited since the last frame joins the open edit group and gets rebuilt.
func _open_edit_group() -> void:
	if _touched.is_empty():
		return
	for key in _touched:
		var c: Chunk = _touched[key]
		c.in_group = true
		_group[c] = true
	_touched = {}
	for c in _group.keys():
		_try_mesh(c)
	_check_group()


func _try_mesh(c: Chunk) -> void:
	if c.meshing or not c.generated or c.built == c.version:
		return
	if c.pending != null:
		return   # already built for this version, waiting for the rest of its group
	if c.data.is_empty():
		if c.in_group:
			c.pending = [null, null]   # nothing to draw, but the group still waits for every member
		else:
			c.built = c.version
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
					snap[slot] = PackedInt32Array()  # outside the world is open sky
				elif not n.generated:
					return
				else:
					snap[slot] = n.data
	c.meshing = true
	_mesh_in_flight += 1
	WorkerThreadPool.add_task(_mesh_task.bind(c, snap, c.version))


func _mesh_task(c: Chunk, snap: Array, version: int) -> void:
	var out := ChunkMesher.build(snap, c.cpos * Blocks.CHUNK_SIZE, preset)
	_mutex.lock()
	_mesh_results.append([c, out, version])
	_mutex.unlock()


func _drain_meshed() -> void:
	_mutex.lock()
	var results := _mesh_results
	_mesh_results = []
	_mutex.unlock()
	for r in results:
		var c: Chunk = r[0]
		c.meshing = false
		_mesh_in_flight -= 1
		if r[2] != c.version:
			_try_mesh(c)   # edited while it was being built: that mesh is stale
			continue
		c.pending = r[1]
		if not c.in_group:
			_commit_queue.append(c)
	_check_group()
	# Initial meshes, a few per frame.
	var budget := meshes_per_frame
	while budget > 0 and not _commit_queue.is_empty():
		var c: Chunk = _commit_queue.pop_front()
		if c.pending == null or c.in_group:
			continue   # edited meanwhile: its group will commit it
		_commit_mesh(c, c.pending)
		c.built = c.version
		c.pending = null
		chunk_meshed.emit(c.cpos)
		budget -= 1


## Commits the open edit group once every member has its up-to-date mesh, all in the same frame.
func _check_group() -> void:
	if _group.is_empty():
		return
	for c in _group:
		if c.pending == null:
			return
	for c in _group:
		_commit_mesh(c, c.pending)
		c.built = c.version
		c.pending = null
		c.in_group = false
		chunk_meshed.emit(c.cpos)
	_group = {}


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
