class_name Blocks
extends RefCounted
## Block ids and their look. A voxel is one byte: material in the low 4 bits, shape in the high 4 bits.
## Shapes (the top surface is described by the heights, 0 or 1, of the cell's four corners):
##   0 cube | 1-4 wedge, high side +X, -X, +Z, -Z | 5 half-height slab
##   6-9 outer corner, one corner raised: (+x,+z), (-x,+z), (+x,-z), (-x,-z)
##   10-13 inner corner, one corner lowered: (+x,+z), (-x,+z), (+x,-z), (-x,-z)
## Ramps fill the gap beside 1-block drops so slopes are not staircases; digging goes cube -> slab -> air.

const CHUNK_SIZE := 16
const CHUNK_VOLUME := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

const AIR := 0
const GRASS := 1
const DIRT := 2
const STONE := 3
const SAND := 4
const WATER := 5
const COAL := 6
const IRON := 7
const BEDROCK := 8
const SNOW := 9
const ORANGE_ORE := 10
const PLANK := 11

const SHAPE_CUBE := 0
const SHAPE_WEDGE_PX := 1
const SHAPE_WEDGE_NX := 2
const SHAPE_WEDGE_PZ := 3
const SHAPE_WEDGE_NZ := 4
const SHAPE_SLAB := 5
const SHAPE_OUTER_PP := 6
const SHAPE_INNER_PP := 10

## Corner heights (0 or 1) of the top surface for corners (0,0), (1,0), (1,1), (0,1) in (x, z), per ramp shape.
const SHAPE_CORNERS := {
	1: [0, 1, 1, 0], 2: [1, 0, 0, 1], 3: [0, 0, 1, 1], 4: [1, 1, 0, 0],
	6: [0, 0, 1, 0], 7: [0, 0, 0, 1], 8: [0, 1, 0, 0], 9: [1, 0, 0, 0],
	10: [1, 1, 0, 1], 11: [1, 1, 1, 0], 12: [1, 0, 1, 1], 13: [0, 1, 1, 1],
}

# Face order used everywhere: top, bottom, side.
const FACE_TOP := 0
const FACE_BOTTOM := 1
const FACE_SIDE := 2

const _COLORS := {
	GRASS: [Color("5fa83a"), Color("7a5a3a"), Color("6b7f3a")],
	DIRT: [Color("7a5a3a"), Color("7a5a3a"), Color("7a5a3a")],
	STONE: [Color("8a8d91"), Color("8a8d91"), Color("8a8d91")],
	SAND: [Color("dccf8f"), Color("dccf8f"), Color("dccf8f")],
	WATER: [Color("3b6fd0"), Color("3b6fd0"), Color("3b6fd0")],
	COAL: [Color("3a3a3e"), Color("3a3a3e"), Color("3a3a3e")],
	IRON: [Color("a9c9dd"), Color("a9c9dd"), Color("a9c9dd")],
	BEDROCK: [Color("2a2a2c"), Color("2a2a2c"), Color("2a2a2c")],
	SNOW: [Color("f2f6fa"), Color("8a8d91"), Color("c9d3dc")],
	ORANGE_ORE: [Color("f08a1c"), Color("c4690f"), Color("e07a14")],
	PLANK: [Color("b98a4e"), Color("7b5630"), Color("9c703b")],
}


static func mat(raw: int) -> int:
	return raw & 15


static func shape(raw: int) -> int:
	return raw >> 4


static func make(material: int, shape_id: int) -> int:
	return material | (shape_id << 4)


## Hides the faces of neighbours: only full cubes do.
static func is_opaque(raw: int) -> bool:
	var m := raw & 15
	return m != AIR and m != WATER and (raw >> 4) == SHAPE_CUBE


static func is_solid(raw: int) -> bool:
	var m := raw & 15
	return m != AIR and m != WATER


static func is_diggable(raw: int) -> bool:
	var m := raw & 15
	return m != AIR and m != BEDROCK and m != WATER


static func color_of(raw: int, face: int) -> Color:
	var set: Array = _COLORS.get(raw & 15, [Color.MAGENTA, Color.MAGENTA, Color.MAGENTA])
	return set[face]
