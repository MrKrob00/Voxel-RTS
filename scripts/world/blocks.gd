class_name Blocks
extends RefCounted
## Block ids and their look. A voxel is one byte: material in the low 5 bits, shape in the high 3 bits.
## Shape 0 is a full cube; 1-4 are ramp wedges (the high side faces +X, -X, +Z, -Z); 5 is a half-height slab.
## A wedge fills the gap next to a 1-block drop; digging goes cube -> slab -> air so pits are not all squares.

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

const SHAPE_CUBE := 0
const SHAPE_WEDGE_PX := 1
const SHAPE_WEDGE_NX := 2
const SHAPE_WEDGE_PZ := 3
const SHAPE_WEDGE_NZ := 4
const SHAPE_SLAB := 5

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
	IRON: [Color("b89478"), Color("b89478"), Color("b89478")],
	BEDROCK: [Color("2a2a2c"), Color("2a2a2c"), Color("2a2a2c")],
	SNOW: [Color("f2f6fa"), Color("8a8d91"), Color("c9d3dc")],
	ORANGE_ORE: [Color("f08a1c"), Color("c4690f"), Color("e07a14")],
}


static func mat(raw: int) -> int:
	return raw & 31


static func shape(raw: int) -> int:
	return raw >> 5


static func make(material: int, shape_id: int) -> int:
	return material | (shape_id << 5)


## Hides the faces of neighbours: only full cubes do.
static func is_opaque(raw: int) -> bool:
	var m := raw & 31
	return m != AIR and m != WATER and (raw >> 5) == SHAPE_CUBE


static func is_solid(raw: int) -> bool:
	var m := raw & 31
	return m != AIR and m != WATER


static func is_diggable(raw: int) -> bool:
	var m := raw & 31
	return m != AIR and m != BEDROCK and m != WATER


static func color_of(raw: int, face: int) -> Color:
	var set: Array = _COLORS.get(raw & 31, [Color.MAGENTA, Color.MAGENTA, Color.MAGENTA])
	return set[face]
