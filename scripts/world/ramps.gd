class_name Ramps
extends RefCounted
## The one set of rules for the pieces whose shape depends on their neighbours, and for cleaning the generated height
## field. Used by the generator and by TerrainEdit, so freshly generated and freshly edited ground always agree.
##
## Two kinds of piece are shaped by their neighbours:
##   - a SLOPE piece fills the cell P above a ground block that is lower than its neighbours (base height 0);
##   - a DUG block, a natural block that was partly dug, stands Blocks.DUG_HEIGHT quarters high and is shaped the same way
##     (base height DUG_HEIGHT), so its corners next to whole blocks rise to meet them and the pit gets sloping sides.
## The shape is decided by the 3x3x3 neighbourhood of the cell:
##   - for a slope piece, a whole block below it (it must rest on ground);
##   - in the cell's layer, the 8 neighbours: how far each one rises into the layer;
##   - in the layer above, the same 8 columns: they tell a 1-block step from a wall.
## A neighbour contributes a RISE in quarter-blocks: UNIT for a whole block that is a step top, DUG_HEIGHT for a half-dug
## block, 0 for a wall (something natural is above it), air or a slope piece. Slope pieces never raise other pieces.
##
## The height of each corner is the highest of the base height and the rises of the three cells that touch the corner (two
## sides and the diagonal). A corner is a vertex shared by up to four pieces and all of them compute it the same way, so
## neighbouring pieces always meet along edges of equal height: the surface has no cracks.

const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
]


# --- the rule -----------------------------------------------------------------------------------

## `rise` maps each of the 8 neighbour offsets (x, z) to a height in quarter-blocks. `base` is 0 for a slope piece (the
## result is -1 when nothing needs filling) and Blocks.DUG_HEIGHT for a dug block (the result is always a shape).
static func shape_from_rises(rise: Dictionary, base := 0) -> int:
	var any := false
	for off in NEIGHBOURS:
		if rise.get(off, 0) > 0:
			any = true
			break
	var dug := base > 0
	if not any and not dug:
		return -1
	if dug:
		return _dug_shape(rise, base)
	var c0 := _corner(rise, base, Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1))   # corner (0,0)
	var c1 := _corner(rise, base, Vector2i(1, 0), Vector2i(0, -1), Vector2i(1, -1))     # (1,0)
	var c2 := _corner(rise, base, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1))       # (1,1)
	var c3 := _corner(rise, base, Vector2i(-1, 0), Vector2i(0, 1), Vector2i(-1, 1))     # (0,1)
	if (c0 > 0 and c2 > 0 and c1 == 0 and c3 == 0) or (c1 > 0 and c3 > 0 and c0 == 0 and c2 == 0):
		return -1   # a saddle (two opposite corners raised): leave it
	var shape := Blocks.shape_from_corners(c0, c1, c2, c3)
	return -1 if shape == Blocks.SHAPE_CUBE else shape   # raised on all corners: nothing to add


## A half-dug block: corners raised to a whole neighbour's height where one touches them, and the middle of every side
## that borders another half-dug block sunk to the dug height, so neighbouring pits merge instead of leaving a ridge.
static func _dug_shape(rise: Dictionary, base: int) -> int:
	var corners := [
		_corner(rise, base, Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)),
		_corner(rise, base, Vector2i(1, 0), Vector2i(0, -1), Vector2i(1, -1)),
		_corner(rise, base, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)),
		_corner(rise, base, Vector2i(-1, 0), Vector2i(0, 1), Vector2i(-1, 1)),
	]
	var corner_mask := 0
	for k in 4:
		if corners[k] >= Blocks.UNIT:
			corner_mask |= 1 << k
	var dip_mask := 0
	var sides := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for s in 4:
		if rise.get(sides[s], 0) == Blocks.DUG_HEIGHT:
			dip_mask |= 1 << s
	return Blocks.dug_shape(corner_mask, dip_mask)


static func _corner(rise: Dictionary, base: int, side_a: Vector2i, side_b: Vector2i, diagonal: Vector2i) -> int:
	return maxi(base, maxi(maxi(rise.get(side_a, 0), rise.get(side_b, 0)), rise.get(diagonal, 0)))


# --- samplers: where the rises come from -------------------------------------------------------------------

## Surface height of a column in quarter-blocks from the y of its top whole block.
static func level_of_top(top: int) -> int:
	return Blocks.UNIT * (top + 1) if top >= 0 else -1


## From column levels (quarter-blocks; -1 = no ground), used by the generator, which knows heights, not cells.
## `cell_base` is the height of the bottom of the piece's cell.
static func rises_from_levels(cell_base: int, around: Dictionary) -> Dictionary:
	var rise := {}
	for off in NEIGHBOURS:
		var n: int = around.get(off, -1)
		var d := n - cell_base
		rise[off] = d if (n >= 0 and d >= 1 and d <= Blocks.UNIT) else 0
	return rise


## From the cells themselves, used by TerrainEdit. `raw_at(dx, dy, dz)` returns the voxel at an offset from the piece's cell.
static func rises_from_cells(raw_at: Callable) -> Dictionary:
	var rise := {}
	for off in NEIGHBOURS:
		var here: int = raw_at.call(off.x, 0, off.y)
		var above: int = raw_at.call(off.x, 1, off.y)
		var r := 0
		if Blocks.is_whole(here):
			r = Blocks.UNIT if not _natural(above) else 0   # a step top, or a wall
		elif Blocks.is_dug(here):
			r = Blocks.DUG_HEIGHT
		rise[off] = r
	return rise


static func _natural(raw: int) -> bool:
	return Blocks.is_whole(raw) or Blocks.is_dug(raw)


## Level-based shortcut for a slope piece in the cell whose bottom is at `level`.
static func skin_shape(level: int, around: Dictionary) -> int:
	return shape_from_rises(rises_from_levels(level, around), 0)


## Level-based shortcut for a dug block whose top is at `level` (its cell starts DUG_HEIGHT lower).
static func dug_shape(level: int, around: Dictionary) -> int:
	return shape_from_rises(rises_from_levels(level - Blocks.DUG_HEIGHT, around), Blocks.DUG_HEIGHT)


# --- generated height field ---------------------------------------------------------------------------------

## Cleans the generated height field of features one block wide, which would only produce a ring of shard-like slopes:
## pits and 1-wide trenches are filled, 1-block pillars and 1-wide ridges are cut, each only when the difference is 1-2
## blocks. `px`, `nx`, `pz`, `nz` are the neighbouring tops (+x, -x, +z, -z), -1 where there is no ground (such columns,
## at an island edge, are left alone). Generation only: players are allowed to dig and build whatever they like.
static func despeckle(top: int, px: int, nx: int, pz: int, nz: int) -> int:
	var changed := top
	# Pits and trenches: raise.
	if px > top and nx > top and pz > top and nz > top:
		var lo := mini(mini(px, nx), mini(pz, nz))
		if lo - top <= 2:
			return lo
	if px > top and nx > top:
		var lo2 := mini(px, nx)
		if lo2 - top <= 2:
			changed = maxi(changed, lo2)
	if pz > top and nz > top:
		var lo3 := mini(pz, nz)
		if lo3 - top <= 2:
			changed = maxi(changed, lo3)
	if changed != top:
		return changed
	# Pillars and ridges: cut.
	if px >= 0 and nx >= 0 and pz >= 0 and nz >= 0 and top > px and top > nx and top > pz and top > nz:
		var hi := maxi(maxi(px, nx), maxi(pz, nz))
		if top - hi <= 2:
			return hi
	if px >= 0 and nx >= 0 and top > px and top > nx:
		var hi2 := maxi(px, nx)
		if top - hi2 <= 2:
			changed = mini(changed, hi2) if changed != top else hi2
	if pz >= 0 and nz >= 0 and top > pz and top > nz:
		var hi3 := maxi(pz, nz)
		if top - hi3 <= 2:
			changed = mini(changed, hi3) if changed != top else hi3
	return changed
