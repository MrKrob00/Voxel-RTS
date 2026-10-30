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
## Off for headless tests that only need the voxel data: no meshes are built, which saves most of the work.
@export var meshing_enabled := true

var generator: WorldGen
## Set before the node enters the tree to pick another map type.
var preset: MapPreset = MapPreset.plains()
## What digging and building do to the ground (stages, slopes). Created in _ready.
var terrain: TerrainEdit
## How much of the grass is gone in each column (under props, buildings, along cliffs); the mesher blends it into the colours.
var cover: GroundCover

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
## The same chunks in a flat array (x + z * cx + y * cx * cz) and the size of the world in blocks: get_block is the most called function
## of the game (every path search, every mesh), so it does no dictionary lookup and builds no vectors.
var _grid: Array[Chunk] = []
var _wx := 0
var _wy := 0
var _wz := 0
var _cxz := 0
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
var _modified := {}                 ## cpos -> true: chunks written to since the world was generated or last restored
var _mesh_holds := 0                ## meshing waits while anything (the cliff pass, the prop scatter) is still painting the ground cover

var _solid_material: ShaderMaterial
var _water_material: ShaderMaterial
## The height of the ground of every column (x + z * width) in quarter-blocks (Blocks.UNIT per block), 0 where there is none: what the
## colliders under falling things are cut from. Worked out in a thread when the world is generated, then kept right by every change.
var column_levels := PackedInt32Array()
var column_levels_ready := false
var _levels_busy := false          # a worker thread is working out the levels (the world must not be torn down meanwhile)
var edit_serial := 0               ## counts every change of a block
var relief_texture: ImageTexture   ## the shade of the high ground on the low (ReliefShadow); every ground material shows it


func _ready() -> void:
	_solid_material = DayCycle.terrain_material(size_blocks())   # the ground: the shader finishes what the mesher merged
	_water_material = DayCycle.world_material(false, true)
	relief_texture = ImageTexture.create_from_image(Image.create(size_blocks().x, size_blocks().z, false, Image.FORMAT_R8))
	_solid_material.set_shader_parameter("relief_tex", relief_texture)
	_solid_material.set_shader_parameter("relief_size", Vector2(size_blocks().x, size_blocks().z))
	terrain = TerrainEdit.new(self)
	cover = GroundCover.new(size_blocks().x, size_blocks().z)
	start()


## Size of the world in blocks.
func size_blocks() -> Vector3i:
	return size_chunks * Blocks.CHUNK_SIZE


func start() -> void:
	generator = WorldGen.new(world_seed, size_blocks(), preset, extra_islands)
	_gen_total = size_chunks.x * size_chunks.y * size_chunks.z
	_wx = size_chunks.x * Blocks.CHUNK_SIZE
	_wy = size_chunks.y * Blocks.CHUNK_SIZE
	_wz = size_chunks.z * Blocks.CHUNK_SIZE
	_cxz = size_chunks.x * size_chunks.z
	_grid.resize(_gen_total)
	hold_meshing()
	WorkerThreadPool.add_task(_cliff_cover_task)
	# Generate from the middle of the map outwards so the visible area appears first.
	var centre := Vector3(size_chunks) * 0.5
	var list: Array[Chunk] = []
	for cy in size_chunks.y:
		for cz in size_chunks.z:
			for cx in size_chunks.x:
				var c := Chunk.new(Vector3i(cx, cy, cz))
				_chunks[c.cpos] = c
				_grid[cx + cz * size_chunks.x + cy * _cxz] = c
				list.append(c)
	list.sort_custom(func(a: Chunk, b: Chunk) -> bool:
		return (Vector3(a.cpos) - centre).length_squared() < (Vector3(b.cpos) - centre).length_squared())
	_gen_queue = list


func is_ready() -> bool:
	return _finished_signalled


## Meshing waits while the ground cover is still being painted, so the first picture already has its bare ground and no
## chunk is built twice. Every hold_meshing() needs a release_meshing().
func hold_meshing() -> void:
	_mesh_holds += 1


func release_meshing() -> void:
	_mesh_holds -= 1
	if _mesh_holds == 0:
		for c in _chunks.values():
			_try_mesh(c)


func _cliff_cover_task() -> void:
	var size := size_blocks()
	var tops := PackedInt32Array()
	tops.resize(size.x * size.z)
	for z in size.z:
		for x in size.x:
			tops[x + z * size.x] = generator.column(x, z).x
	cover.paint_cliffs(tops)
	release_meshing.call_deferred()


## Clears grass around something that was just put on the ground and rebuilds the meshes that show it.
func stamp_cover_disc(center: Vector2, inner: float, outer: float, strength := 1.0) -> void:
	_cover_changed(cover.stamp_disc(center, inner, outer, strength))


func stamp_cover_rect(rect: Rect2, margin: float, strength := 1.0) -> void:
	_cover_changed(cover.stamp_rect(rect, margin, strength))


func _cover_changed(area: Rect2i) -> void:
	if _mesh_holds > 0:
		return   # nothing is built yet
	var x0 := (area.position.x - 1) >> 4
	var x1 := (area.end.x) >> 4
	var z0 := (area.position.y - 1) >> 4
	var z1 := (area.end.y) >> 4
	for cz in range(maxi(z0, 0), mini(z1, size_chunks.z - 1) + 1):
		for cx in range(maxi(x0, 0), mini(x1, size_chunks.x - 1) + 1):
			for cy in size_chunks.y:
				var c: Chunk = _chunks.get(Vector3i(cx, cy, cz))
				if c != null and c.generated and not c.data.is_empty():
					c.version += 1
					c.pending = null
					_touched[c.cpos] = c


func in_bounds(p: Vector3i) -> bool:
	var s := size_blocks()
	return p.x >= 0 and p.y >= 0 and p.z >= 0 and p.x < s.x and p.y < s.y and p.z < s.z


## The voxel at a position (see Blocks for the format); AIR outside the world and in chunks not generated yet.
func get_block(p: Vector3i) -> int:
	var x := p.x
	var y := p.y
	var z := p.z
	if x < 0 or y < 0 or z < 0 or x >= _wx or y >= _wy or z >= _wz:
		return Blocks.AIR
	var c: Chunk = _grid[(x >> 4) + (z >> 4) * size_chunks.x + (y >> 4) * _cxz]
	if c == null or not c.generated:
		return Blocks.AIR
	var d := c.data
	if d.is_empty():
		return Blocks.AIR
	return d[(x & 15) + ((z & 15) << 4) + ((y & 15) << 8)]


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
		WorldReaders.wait_none()   # no path search may be reading the array while it is made
		c.data.resize(Blocks.CHUNK_VOLUME)
		c.data.fill(Blocks.AIR)
	var idx := (p.x & 15) + ((p.z & 15) << 4) + ((p.y & 15) << 8)
	if c.data[idx] == raw:
		return false
	c.data[idx] = raw
	_modified[cpos] = true
	edit_serial += 1
	if column_levels_ready:
		_update_column_level(p)
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


## The height of the ground in a column in quarter-blocks, looking from block `from_y` down (the blocks above must be open).
func ground_level(x: int, z: int, from_y := -1) -> int:
	if x < 0 or z < 0 or x >= _wx or z >= _wz:
		return 0
	var y := _wy - 1 if from_y < 0 else mini(from_y, _wy - 1)
	while y >= 0:
		var c: Chunk = _grid[(x >> 4) + (z >> 4) * size_chunks.x + (y >> 4) * _cxz]
		if c == null or c.data.is_empty():
			y = ((y >> 4) << 4) - 1   # nothing but sky in this chunk: the one below
			continue
		var raw := c.data[(x & 15) + ((z & 15) << 4) + ((y & 15) << 8)]
		if Blocks.is_solid(raw):
			if Blocks.is_partial(raw):
				return Blocks.UNIT * y + Blocks.max_height(Blocks.shape(raw))
			return Blocks.UNIT * (y + 1)
		y -= 1
	return 0


func _update_column_level(p: Vector3i) -> void:
	var idx := p.x + p.z * _wx
	var top_block := (column_levels[idx] - 1) / Blocks.UNIT if column_levels[idx] > 0 else -1
	if p.y >= top_block:   # a change under the top block cannot change the ground; here the column is looked at again from p down
		column_levels[idx] = ground_level(p.x, p.z, p.y)


## All the columns, in a worker thread. Done again when something was changed while it ran (the edits of those moments were not kept).
func _levels_job() -> void:
	var out := PackedInt32Array()
	out.resize(_wx * _wz)
	var before := -1
	while before != edit_serial:
		before = edit_serial
		fill_column_levels(out)
	column_levels = out
	column_levels_ready = true
	_levels_busy = false


func fill_column_levels(out: PackedInt32Array) -> void:
	var cs := Blocks.CHUNK_SIZE
	for cz in size_chunks.z:
		for cx in size_chunks.x:
			for lz in cs:
				for lx in cs:
					out[(cx * cs + lx) + (cz * cs + lz) * _wx] = ground_level(cx * cs + lx, cz * cs + lz)


## For every column (x + z * width): y + 1 of its highest solid block, 0 when there is none. Reads the chunks directly; call it from a
## thread only while nothing is being generated.
func fill_column_tops(out: PackedInt32Array) -> void:
	var cs := Blocks.CHUNK_SIZE
	for cz in size_chunks.z:
		for cx in size_chunks.x:
			var found := PackedByteArray()
			found.resize(cs * cs)
			var open := cs * cs
			for cy in range(size_chunks.y - 1, -1, -1):
				if open == 0:
					break
				var c: Chunk = _grid[cx + cz * size_chunks.x + cy * _cxz]
				if c == null or c.data.is_empty():
					continue
				for lz in cs:
					for lx in cs:
						if found[lx + lz * cs] != 0:
							continue
						for ly in range(cs - 1, -1, -1):
							if Blocks.is_solid(c.data[lx + (lz << 4) + (ly << 8)]):
								out[(cx * cs + lx) + (cz * cs + lz) * _wx] = cy * cs + ly + 1
								found[lx + lz * cs] = 1
								open -= 1
								break


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


## True when the world is generated and no chunk is waiting for, or building, a newer mesh (edits have fully shown up), and
## nothing is holding meshing back. Safe to tear the world down then: no worker task is still running.
func is_settled() -> bool:
	if _mesh_holds > 0 or not _finished_signalled or _gen_in_flight > 0 or not _gen_queue.is_empty() or _levels_busy:
		return false
	if not _touched.is_empty() or not _group.is_empty() or _mesh_in_flight > 0 or not _commit_queue.is_empty():
		return false
	if meshing_enabled:
		for c in _chunks.values():
			if c.generated and c.built != c.version:
				return false
	return true


## A copy of everything that edits can change (voxels and the grass cover), to go back to with restore(). For tests, which
## generate one world and give every suite a fresh copy of it.
func snapshot() -> Dictionary:
	var chunks := {}
	for key in _chunks:
		var c: Chunk = _chunks[key]
		chunks[key] = c.data.duplicate()
	_modified = {}
	return {"chunks": chunks, "cover": cover.bare.duplicate()}


## Puts the world back as it was at snapshot() time. Only the chunks that were written to are touched.
func restore(snap: Dictionary) -> void:
	for key in _modified:
		var c: Chunk = _chunks[key]
		c.data = snap.chunks[key].duplicate()
		c.version += 1
		c.pending = null
		_touched[key] = c
	_modified = {}
	edit_serial += 1
	column_levels_ready = false   # worked out again (the colliders look at the blocks until then)
	if _finished_signalled and not _levels_busy:
		_levels_busy = true
		WorkerThreadPool.add_task(_levels_job)
	cover.bare = snap.cover.duplicate()


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
		_levels_busy = true
		WorkerThreadPool.add_task(_levels_job)
		generation_finished.emit()


## Everything edited since the last frame joins the open edit group and gets rebuilt.
func _open_edit_group() -> void:
	if _touched.is_empty():
		return
	if not meshing_enabled:
		_touched = {}
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
	if not meshing_enabled or _mesh_holds > 0 or c.meshing or not c.generated or c.built == c.version:
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
					snap[slot] = n.data.duplicate()   # a copy: the live array is only ever written in place, which the path searches rely on
	c.meshing = true
	_mesh_in_flight += 1
	var grass := cover.slice(c.cpos.x * Blocks.CHUNK_SIZE, c.cpos.z * Blocks.CHUNK_SIZE, Blocks.CHUNK_SIZE)
	WorkerThreadPool.add_task(_mesh_task.bind(c, snap, grass, c.version))


func _mesh_task(c: Chunk, snap: Array, grass: PackedByteArray, version: int) -> void:
	var out := ChunkMesher.build(snap, c.cpos * Blocks.CHUNK_SIZE, preset, grass)
	# The images of the textures of the ground are made here, off the main thread; it only has to hand them to the renderer.
	var ao_data: PackedByteArray = out[2]
	var layers: Array[Image] = []
	if not ao_data.is_empty():
		var size := ChunkMesher.AO_TEX_SIZE
		var layer_bytes := size.x * size.y * 4
		for y in size.z:
			layers.append(Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, ao_data.slice(y * layer_bytes, (y + 1) * layer_bytes)))
	var cover_slice: PackedByteArray = out[3]
	var n := Blocks.CHUNK_SIZE + 2 * GroundCover.SLICE_BORDER
	out[2] = layers
	out[3] = Image.create_from_data(n, n, false, Image.FORMAT_R8, cover_slice) if not cover_slice.is_empty() else null
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


## The material of the ground of one chunk: the shared one, or a copy with the light of the corners of this chunk's faces in a 3D texture.
## `layers`: the 16 images of its 3D texture, `cover_image`: the worn grass of the chunk (both made by the mesh task).
func _solid_material_for(layers: Array, cover_image: Image) -> ShaderMaterial:
	if layers.is_empty():
		return _solid_material
	var size := ChunkMesher.AO_TEX_SIZE
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGBA8, size.x, size.y, size.z, false, layers)
	var m := _solid_material.duplicate() as ShaderMaterial
	m.set_shader_parameter("ao_tex", tex)
	if cover_image != null:
		m.set_shader_parameter("cover_tex", ImageTexture.create_from_image(cover_image))
		m.set_shader_parameter("cover_size", Vector2(cover_image.get_width(), GroundCover.SLICE_BORDER))
	return m


func _commit_mesh(c: Chunk, out: Array) -> void:
	if out[0] == null and out[1] == null:
		if c.instance != null:
			c.instance.queue_free()
			c.instance = null
		return
	var mesh := ArrayMesh.new()
	if out[0] != null:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out[0])
		mesh.surface_set_material(mesh.get_surface_count() - 1, _solid_material_for(out[2] if out.size() > 2 else [], out[3] if out.size() > 3 else null))
	if out[1] != null:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out[1])
		mesh.surface_set_material(mesh.get_surface_count() - 1, _water_material)
	if c.instance == null:
		c.instance = MeshInstance3D.new()
		c.instance.position = Vector3(c.cpos * Blocks.CHUNK_SIZE)
		c.instance.name = "Chunk_%d_%d_%d" % [c.cpos.x, c.cpos.y, c.cpos.z]
		add_child(c.instance)
	c.instance.mesh = mesh
