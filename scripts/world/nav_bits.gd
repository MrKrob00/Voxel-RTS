class_name NavBits
extends RefCounted
## What the ground alone says about standing in a cell, worked out once and kept up to date when a block changes: Navigation asks this
## for every cell of every step of every search, and each answer would otherwise be several reads of the blocks.
##
## Per cell, 5 bits:
##   FEET  the feet may be in the cell as far as the ground goes (no water; no solid block unless it is a slope or a half-dug one),
##   HEAD  the cell above is free of ground (no solid block, no water),
##   PIECE the cell holds a slope or a half-dug block (the unit stands IN it),
##   FLOOR the block under the cell is a whole one,
##   SOLID the cell blocks a body (solid ground of any shape, or water).
## The chunks that hold nothing but sky have no array: their cells are all FEET | HEAD (and FLOOR only on the bottom layer, which
## looks at the chunk below). Built in a worker thread when the world is generated (until then `ready` is false and nothing asks),
## then every change of a block redoes the three cells it can touch, on the thread that changed it.

const FEET := 1
const HEAD := 2
const PIECE := 4
const FLOOR := 8
const SOLID := 16   # the cell holds any solid ground (a slope too) or water: it blocks a body

var ready := false
var _world: VoxelWorld
var _chunks: Array[PackedByteArray] = []   # like VoxelWorld._grid; empty array: a chunk of sky
var _cx := 0
var _cxz := 0
var _wx := 0
var _wy := 0
var _wz := 0


func setup(world: VoxelWorld) -> void:
	_world = world
	_cx = world.size_chunks.x
	_cxz = world.size_chunks.x * world.size_chunks.z
	_chunks.resize(_cxz * world.size_chunks.y)
	var size := world.size_blocks()
	_wx = size.x
	_wy = size.y
	_wz = size.z


## Works out the bits of every chunk that holds ground. Run from a worker thread, once the world is generated.
func build() -> void:
	ready = false
	var size := _world.size_chunks
	for cy in size.y:
		for cz in size.z:
			for cx in size.x:
				_fill_chunk(cx, cy, cz)
	ready = true


func _fill_chunk(cx: int, cy: int, cz: int) -> void:
	var idx := cx + cz * _cx + cy * _cxz
	if not _world.chunk_has_data(Vector3i(cx, cy, cz)):
		_chunks[idx] = PackedByteArray()
		return
	var arr := PackedByteArray()
	arr.resize(Blocks.CHUNK_VOLUME)
	var base := Vector3i(cx, cy, cz) * Blocks.CHUNK_SIZE
	for ly in 16:
		for lz in 16:
			for lx in 16:
				arr[lx + (lz << 4) + (ly << 8)] = _compute(base.x + lx, base.y + ly, base.z + lz)
	_chunks[idx] = arr


func _compute(x: int, y: int, z: int) -> int:
	var here := _world.get_block(Vector3i(x, y, z))
	var above := _world.get_block(Vector3i(x, y + 1, z))
	var below := _world.get_block(Vector3i(x, y - 1, z))
	var bits := 0
	var is_water := Blocks.mat(here) == Blocks.WATER
	var partial := Blocks.is_partial(here)
	if not is_water and (not Blocks.is_solid(here) or partial):
		bits |= FEET
	if not Blocks.is_solid(above) and Blocks.mat(above) != Blocks.WATER:
		bits |= HEAD
	if partial:
		bits |= PIECE
	if Blocks.is_whole(below):
		bits |= FLOOR
	if Blocks.is_solid(here) or is_water:
		bits |= SOLID
	return bits


## The bits of a cell (inside the world), or -1 while they are not ready.
func get_bits(x: int, y: int, z: int) -> int:
	if not ready:
		return -1
	if x < 0 or z < 0 or y < 0 or x >= _wx or z >= _wz or y >= _wy:
		return FEET | HEAD   # outside the world is open sky
	var arr: PackedByteArray = _chunks[(x >> 4) + (z >> 4) * _cx + (y >> 4) * _cxz]
	if arr.is_empty():
		# a chunk of sky: nothing solid here, nothing above; a floor only if the chunk under it has one at its top
		if (y & 15) == 0:
			return FEET | HEAD | (FLOOR if Blocks.is_whole(_world.get_block(Vector3i(x, y - 1, z))) else 0)
		return FEET | HEAD
	return arr[(x & 15) + ((z & 15) << 4) + ((y & 15) << 8)]


## Chunks whose blocks were all replaced (VoxelWorld.restore): they and the chunks above and below them (whose edge layers look into
## them) are worked out again.
func refresh_chunks(cposes: Array) -> void:
	if not ready:
		return
	var done := {}
	for cp: Vector3i in cposes:
		for dy in [-1, 0, 1]:
			var q := Vector3i(cp.x, cp.y + dy, cp.z)
			if q.y < 0 or q.y >= _world.size_chunks.y or done.has(q):
				continue
			done[q] = true
			_fill_chunk(q.x, q.y, q.z)


## A block at `p` has changed: the cell itself, the one above and the one below look at it.
func block_changed(p: Vector3i) -> void:
	if not ready:
		return
	for dy in [-1, 0, 1]:
		var y: int = p.y + dy
		if y < 0 or y >= _world.size_blocks().y:
			continue
		var idx := (p.x >> 4) + (p.z >> 4) * _cx + (y >> 4) * _cxz
		if _chunks[idx].is_empty():
			if not _world.chunk_has_data(Vector3i(p.x >> 4, y >> 4, p.z >> 4)):
				continue   # still sky
			_fill_chunk(p.x >> 4, y >> 4, p.z >> 4)   # the first block put into it: it gets its array
			continue
		_chunks[idx][(p.x & 15) + ((p.z & 15) << 4) + ((y & 15) << 8)] = _compute(p.x, y, p.z)
