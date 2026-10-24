class_name Blocks
extends RefCounted
## Block ids and their look. Ids are stored as one byte per voxel.

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
}


static func is_opaque(id: int) -> bool:
	return id != AIR and id != WATER


static func is_solid(id: int) -> bool:
	return id != AIR and id != WATER


static func is_diggable(id: int) -> bool:
	return id != AIR and id != BEDROCK and id != WATER


static func color_of(id: int, face: int) -> Color:
	var set: Array = _COLORS.get(id, [Color.MAGENTA, Color.MAGENTA, Color.MAGENTA])
	return set[face]
