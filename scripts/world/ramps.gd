class_name Ramps
extends RefCounted
## The one set of rules for slope pieces ("skin") and for pit filling. Used by the generator (levels from noise) and by
## TerrainEdit (levels read from the voxels), so freshly generated and freshly edited ground always agree.
##
## A column's surface LEVEL is measured in half-blocks: 2 * (y of its highest whole cube + 1), plus 1 when the block on
## top of that cube is half dug. A slope piece fills the cell above a column that is lower than a neighbour.

const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
]

## Largest height difference (half-blocks) that a slope piece bridges; more than that is a cliff wall.
const MAX_RISE := 2


static func level_of_top(top: int) -> int:
	return 2 * (top + 1) if top >= 0 else -1


## Shape id of the slope piece for a column at `level` (even, in half-blocks), or -1 for none.
## `around` maps each of the 8 neighbour offsets to that neighbour's level (-1 for no ground).
## A neighbour higher by 1 or 2 half-blocks raises the matching corners of the piece to that height: wedge, inner
## corner or outer corner, full or half height. A corner follows the two side neighbours that touch it; the diagonal
## neighbour only counts when neither side neighbour is higher (an outer corner). A neighbour higher by more is a
## cliff wall: it raises nothing but does not cancel what the other neighbours ask for. Pits and trenches get no
## piece: a hole stays a hole.
static func skin_shape(level: int, around: Dictionary) -> int:
	var rise := {}
	var any := false
	for off in NEIGHBOURS:
		var n: int = around.get(off, -1)
		var d := n - level
		var r := d if (n >= 0 and d >= 1 and d <= MAX_RISE) else 0
		rise[off] = r
		any = any or r > 0
	if not any:
		return -1
	var px: int = rise[Vector2i(1, 0)]
	var nx: int = rise[Vector2i(-1, 0)]
	var pz: int = rise[Vector2i(0, 1)]
	var nz: int = rise[Vector2i(0, -1)]
	var c0 := _corner(nx, nz, rise[Vector2i(-1, -1)])    # corner (0,0)
	var c1 := _corner(px, nz, rise[Vector2i(1, -1)])     # (1,0)
	var c2 := _corner(px, pz, rise[Vector2i(1, 1)])      # (1,1)
	var c3 := _corner(nx, pz, rise[Vector2i(-1, 1)])     # (0,1)
	# Two opposite corners raised and the other two not (a saddle): leave it.
	if (c0 > 0 and c2 > 0 and c1 == 0 and c3 == 0) or (c1 > 0 and c3 > 0 and c0 == 0 and c2 == 0):
		return -1
	var shape := Blocks.shape_from_corners(c0, c1, c2, c3)
	return -1 if shape == Blocks.SHAPE_CUBE else shape   # fully raised on all corners: nothing to add


static func _corner(side_a: int, side_b: int, diagonal: int) -> int:
	var sides := maxi(side_a, side_b)
	return sides if sides > 0 else diagonal


## Removes 1-block pits and 1-wide trenches from the generated height field: a column lower than all four neighbours,
## or lower than both neighbours on one axis, is raised to the lower of those neighbours (only when that is 1-2 blocks).
## `px`, `nx`, `pz`, `nz` are the neighbouring tops (+x, -x, +z, -z), -1 where there is no ground.
## Generation only: players are allowed to dig pits.
static func despeckle(top: int, px: int, nx: int, pz: int, nz: int) -> int:
	if px > top and nx > top and pz > top and nz > top:
		var lo := mini(mini(px, nx), mini(pz, nz))
		if lo - top <= 2:
			return lo
	if px > top and nx > top:
		var lo2 := mini(px, nx)
		if lo2 - top <= 2:
			top = lo2
	if pz > top and nz > top:
		var lo3 := mini(pz, nz)
		if lo3 - top <= 2:
			top = lo3
	return top
