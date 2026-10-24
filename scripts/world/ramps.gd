class_name Ramps
extends RefCounted
## Which ramp shape fills the cell above a column, given the surface heights around it.
## Used by the generator (heights from noise) and by the world after edits (heights read from the voxels),
## so freshly generated and freshly dug ground follow the same rules.

const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
]


## `tops` maps each of the 8 neighbour offsets to that column's top height (or -1 for "no ground").
## A neighbour exactly one block higher raises the matching corners of the cell: wedge, inner corner, outer corner.
## A neighbour 2+ higher is a cliff wall: it raises nothing, but it does not cancel ramps that other, 1-higher
## neighbours ask for (a corner where a 1-block step meets a 2-block wall still gets its ramp).
## A 1-wide dip or trench (higher on opposite sides, or on 3+ sides) is half filled with a slab.
static func shape_from(top: int, tops: Dictionary) -> int:
	var hi := {}
	for off in NEIGHBOURS:
		var t: int = tops.get(off, -1)
		if t == top + 1:
			hi[off] = true
	if hi.is_empty():
		return Blocks.SHAPE_CUBE
	var px: bool = hi.has(Vector2i(1, 0))
	var nx: bool = hi.has(Vector2i(-1, 0))
	var pz: bool = hi.has(Vector2i(0, 1))
	var nz: bool = hi.has(Vector2i(0, -1))
	var sides := int(px) + int(nx) + int(pz) + int(nz)
	if sides >= 3 or (px and nx) or (pz and nz):
		return Blocks.SHAPE_SLAB
	var c0: bool = nx or nz or hi.has(Vector2i(-1, -1))    # corner (0,0)
	var c1: bool = px or nz or hi.has(Vector2i(1, -1))     # (1,0)
	var c2: bool = px or pz or hi.has(Vector2i(1, 1))      # (1,1)
	var c3: bool = nx or pz or hi.has(Vector2i(-1, 1))     # (0,1)
	var key := [int(c0), int(c1), int(c2), int(c3)]
	for shape in Blocks.SHAPE_CORNERS:
		if Blocks.SHAPE_CORNERS[shape] == key:
			return shape
	return Blocks.SHAPE_CUBE   # saddle or fully raised: leave it


## True for the shapes the smoothing pass owns (not the slab: that one is also what digging leaves behind).
static func is_managed(raw: int) -> bool:
	var s := Blocks.shape(raw)
	return s != Blocks.SHAPE_CUBE and s != Blocks.SHAPE_SLAB
