class_name TerrainEdit
extends RefCounted
## The rules of changing the ground. VoxelWorld stores voxels; this decides what digging and building do to them.
##
## A block of ground goes through stages:   whole  ->  half dug  ->  gone. A half-dug block stands 3/4 high and its
## corners rise to meet the whole blocks around it, so the pit has sloping sides instead of a sheer step; a grass block
## keeps its turf at the rim and shows earth towards the middle (and gets its grass back if it is built up again). Where two
## half-dug blocks touch, their pits run into each other.
## Slope pieces (wedges, corners) are ground too and can be dug or filled, but unlike natural blocks they are DERIVED: they
## fill the cell above a column that is lower than its neighbours. Their shape, and the shape of a half-dug block, is
## worked out from the neighbours by Ramps (the same rules the generator uses).
##
## What triggers a recompute: only a change to a *natural* block (whole or half dug), because only those set a column's
## level. Digging or filling a slope piece changes nothing around it, so a slope that was dug stays dug, and no new slope
## appears next to it. When a natural block changes, the pieces of the 3x3 columns around it are re-derived from the new
## state of the block, in the same call, so everything shows up in the same frame.
## After DIGGING, existing slope pieces only change shape or disappear: a pit the player dug is never refilled with
## slopes. After BUILDING (the level rose), new slope pieces may appear beside the new wall, like at generation.
##
## Bricks (BrickWorld) are separate objects and never touch the terrain.

var world: VoxelWorld


func _init(w: VoxelWorld) -> void:
	world = w


# --- queries ------------------------------------------------------------------------------------

## Surface level of a column in quarter-blocks (see Ramps): UNIT * (y of its highest whole block + 1), plus DUG_HEIGHT
## if the block on top of that is half dug. -1 for no ground. `cache` is an optional per-edit dictionary.
func level(x: int, z: int, cache: Dictionary = {}) -> int:
	var key := Vector2i(x, z)
	if cache.has(key):
		return cache[key]
	var result := -1
	var size := world.size_blocks()
	if x >= 0 and z >= 0 and x < size.x and z < size.z:
		for y in range(size.y - 1, -1, -1):
			if Blocks.is_whole(world.get_block(Vector3i(x, y, z))):
				var above := world.get_block(Vector3i(x, y + 1, z)) if y + 1 < size.y else Blocks.AIR
				result = Blocks.UNIT * (y + 1) + (Blocks.DUG_HEIGHT if Blocks.is_dug(above) else 0)
				break
	cache[key] = result
	return result


## The highest piece of ground in a column: a slope piece or half-dug block on top, else the highest whole block. This is what
## a worker digs next. (-1,-1,-1) when the column has no ground.
func surface_target(x: int, z: int) -> Vector3i:
	var lv := level(x, z)
	if lv < 0:
		return Vector3i(-1, -1, -1)
	var y := surface_cell_y(lv)
	if Blocks.is_partial(world.get_block(Vector3i(x, y, z))):
		return Vector3i(x, y, z)
	return Vector3i(x, y - 1, z)


## A worker leaves a stair piece in the cell `cell`, rising towards `rise` (a unit step in x or z): four steps up to the level of the
## next column. Needs open air over a whole block; it takes its material from that block (earth or stone). Not derived from
## anything: the neighbour rules leave it alone.
func make_stairs(cell: Vector3i, rise: Vector2i) -> bool:
	if not world.in_bounds(cell) or world.get_block(cell) != Blocks.AIR:
		return false
	var below := world.get_block(cell + Vector3i(0, -1, 0))
	if not Blocks.is_whole(below):
		return false
	return world.set_block(cell, Blocks.make(Blocks.mat(below), Blocks.wedge_towards(rise), false, true))


## The y of the cell just above a column's highest whole block: where its slope piece or its half-dug block is.
static func surface_cell_y(level_value: int) -> int:
	return level_value / Blocks.UNIT


## What the voxel in the slope cell above a column should be right now (AIR when no slope belongs there).
## Decided from the cells around the slope cell (Ramps.rises_from_cells), the same rule the generator follows.
func expected_skin(x: int, z: int, cache: Dictionary = {}) -> int:
	var lv := level(x, z, cache)
	if lv < 0 or lv % Blocks.UNIT != 0:
		return Blocks.AIR   # no ground, or the top block is half dug and is its own surface
	var y := surface_cell_y(lv)
	var shape := Ramps.shape_from_rises(Ramps.rises_from_cells(_sampler(x, y, z)), 0)
	if shape < 0:
		return Blocks.AIR
	return Blocks.make(Blocks.mat(world.get_block(Vector3i(x, y - 1, z))), shape)


## What a half-dug block's voxel should be right now: same material, flag set, corners following the neighbours.
func expected_dug(x: int, z: int, cache: Dictionary = {}) -> int:
	var lv := level(x, z, cache)
	if lv < 0 or lv % Blocks.UNIT != Blocks.DUG_HEIGHT:
		return Blocks.AIR
	var y := surface_cell_y(lv)
	var cur := world.get_block(Vector3i(x, y, z))
	var shape := Ramps.shape_from_rises(Ramps.rises_from_cells(_sampler(x, y, z)), Blocks.DUG_HEIGHT)
	return Blocks.make(Blocks.mat(cur), shape, true)


func _sampler(x: int, y: int, z: int) -> Callable:
	return func(dx: int, dy: int, dz: int) -> int:
		return world.get_block(Vector3i(x + dx, y + dy, z + dz))


func can_dig(cell: Vector3i) -> bool:
	return world.in_bounds(cell) and Blocks.is_diggable(world.get_block(cell))


## Ground may be built on: a slope piece or half-dug block fills up to a whole block; free space needs solid ground
## next to it (no building in mid-air).
func can_build(cell: Vector3i) -> bool:
	if not world.in_bounds(cell):
		return false
	var raw := world.get_block(cell)
	if Blocks.is_whole(raw):
		return false
	if Blocks.is_solid(raw):
		return true
	for n in ChunkMesher.FACE_NORMALS:
		if Blocks.is_solid(world.get_block(cell + n)):
			return true
	return false


# --- edits --------------------------------------------------------------------------------------

## One stage of digging. A whole block with open air above becomes half dug; a half-dug block or a slope piece is gone.
## A block covered by other ground (a cliff face, a tunnel wall) has no half-way state and just goes.
## A worker repeats this while its task runs, so pits take shape gradually.
func dig_step(cell: Vector3i) -> bool:
	if not can_dig(cell):
		return false
	var raw := world.get_block(cell)
	if Blocks.is_whole(raw) and not _is_natural(world.get_block(cell + Vector3i(0, 1, 0))):
		# The corners are filled in by the re-derive right after (they depend on the neighbours).
		return _apply(cell, Blocks.make(Blocks.mat(raw), Blocks.SHAPE_DUG, true))
	return _apply(cell, Blocks.AIR)


## Fills a cell up to a whole block. A slope piece or half-dug block keeps its own material; free space gets `material`.
func build(cell: Vector3i, material: int) -> bool:
	if not can_build(cell):
		return false
	var raw := world.get_block(cell)
	var m := Blocks.mat(raw) if Blocks.is_solid(raw) else material
	return _apply(cell, Blocks.make(m))


## Writes the cell, then, if a natural block changed, re-derives the pieces around it from the new state.
func _apply(cell: Vector3i, raw: int) -> bool:
	var old := world.get_block(cell)
	var natural := _is_natural(old) or _is_natural(raw)
	var before := level(cell.x, cell.z) if natural else 0
	if not world.set_block(cell, raw):
		return false
	if natural:
		_rederive_around(cell.x, cell.z, level(cell.x, cell.z) > before)
	return true


## Whole or half-dug blocks decide a column's level; slope pieces do not.
static func _is_natural(raw: int) -> bool:
	return Blocks.is_whole(raw) or Blocks.is_dug(raw)


func _rederive_around(cx: int, cz: int, allow_create: bool) -> void:
	var cache := {}
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			_rederive_column(cx + dx, cz + dz, cache, allow_create)


func _rederive_column(x: int, z: int, cache: Dictionary, allow_create: bool) -> void:
	var lv := level(x, z, cache)
	if lv < 0:
		return
	var first_free := surface_cell_y(lv)   # the cell above the highest whole block
	var size := world.size_blocks()
	if first_free < size.y:
		var cell := Vector3i(x, first_free, z)
		var cur := world.get_block(cell)
		if lv % Blocks.UNIT == 0:
			if Blocks.is_skin(cur) or (cur == Blocks.AIR and allow_create):
				var want := expected_skin(x, z, cache)
				if want != cur:
					world.set_block(cell, want)
		elif Blocks.is_dug(cur):
			var want_dug := expected_dug(x, z, cache)
			if want_dug != cur:
				world.set_block(cell, want_dug)
	first_free += 1   # the dug block itself, or the slope cell, is handled: what is left above is floating
	# Slope pieces left floating above the surface by a lower level are removed.
	for y in range(first_free, mini(first_free + 4, size.y)):
		var c := Vector3i(x, y, z)
		var above := world.get_block(c)
		if Blocks.is_skin(above) or Blocks.is_stairs(above):
			world.set_block(c, Blocks.AIR)
