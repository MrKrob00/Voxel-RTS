class_name Ramps
extends RefCounted
## The one set of rules for slope pieces ("skin") and for cleaning the generated height field. Used by the generator and by
## TerrainEdit, so freshly generated and freshly edited ground always agree.
##
## A slope piece fills the cell P above a ground block that is lower than its neighbours. It is decided by the 3x3x3
## neighbourhood of P:
##   - below P: a whole block (the piece must rest on ground);
##   - in P's layer, the 8 neighbours: how much of each one rises into the layer;
##   - in the layer above, the same 8 columns: they tell a 1-block step (nothing natural above it) from a wall.
## A neighbour contributes a RISE, in half-blocks: 2 for a whole block that is a step top, 1 for a half-dug block, 0 for a
## wall (something natural is above it), air or another slope piece. Slope pieces never raise other slope pieces.
##
## The height of each corner of P is the highest rise among the three cells that touch that corner (two sides and the
## diagonal). The same corner is computed identically by the neighbouring pieces that share it, so neighbouring pieces
## always meet along edges of equal height: the surface has no cracks.

const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
]

## Largest height difference (half-blocks) that a slope piece bridges.
const MAX_RISE := 2


# --- the rule -----------------------------------------------------------------------------------

## `rise` maps each of the 8 neighbour offsets (x, z) to 0, 1 or 2. Returns the shape id of the piece, or -1 for none.
static func shape_from_rises(rise: Dictionary) -> int:
	var any := false
	for off in NEIGHBOURS:
		if rise.get(off, 0) > 0:
			any = true
			break
	if not any:
		return -1
	var c0 := _corner(rise, Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1))   # corner (0,0)
	var c1 := _corner(rise, Vector2i(1, 0), Vector2i(0, -1), Vector2i(1, -1))     # (1,0)
	var c2 := _corner(rise, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1))       # (1,1)
	var c3 := _corner(rise, Vector2i(-1, 0), Vector2i(0, 1), Vector2i(-1, 1))     # (0,1)
	# Two opposite corners raised and the other two not (a saddle): leave it.
	if (c0 > 0 and c2 > 0 and c1 == 0 and c3 == 0) or (c1 > 0 and c3 > 0 and c0 == 0 and c2 == 0):
		return -1
	var shape := Blocks.shape_from_corners(c0, c1, c2, c3)
	return -1 if shape == Blocks.SHAPE_CUBE else shape   # raised on all corners: nothing to add


static func _corner(rise: Dictionary, side_a: Vector2i, side_b: Vector2i, diagonal: Vector2i) -> int:
	return maxi(maxi(rise.get(side_a, 0), rise.get(side_b, 0)), rise.get(diagonal, 0))


# --- samplers: where the rises come from -------------------------------------------------------------------

static func level_of_top(top: int) -> int:
	return 2 * (top + 1) if top >= 0 else -1


## From column levels (half-blocks; -1 = no ground), used by the generator, which knows heights, not cells.
static func rises_from_levels(level: int, around: Dictionary) -> Dictionary:
	var rise := {}
	for off in NEIGHBOURS:
		var n: int = around.get(off, -1)
		var d := n - level
		rise[off] = d if (n >= 0 and d >= 1 and d <= MAX_RISE) else 0
	return rise


## From the cells themselves, used by TerrainEdit. `raw_at(dx, dy, dz)` returns the voxel at an offset from P.
static func rises_from_cells(raw_at: Callable) -> Dictionary:
	var rise := {}
	for off in NEIGHBOURS:
		var here: int = raw_at.call(off.x, 0, off.y)
		var above: int = raw_at.call(off.x, 1, off.y)
		var r := 0
		if Blocks.is_whole(here):
			r = 2 if not _natural(above) else 0   # a step top, or a wall
		elif Blocks.is_dug(here):
			r = 1
		rise[off] = r
	return rise


static func _natural(raw: int) -> bool:
	return Blocks.is_whole(raw) or Blocks.is_dug(raw)


## Level-based shortcut for `shape_from_rises(rises_from_levels(...))`.
static func skin_shape(level: int, around: Dictionary) -> int:
	return shape_from_rises(rises_from_levels(level, around))


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
