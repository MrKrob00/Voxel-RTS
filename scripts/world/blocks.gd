class_name Blocks
extends RefCounted
## The voxel format and block palette. A voxel is one int:
##   bits 0-7   material (AIR, GRASS, ...)
##   bits 8-15  shape: 0 is a full cube; any other value is 1 + the heights of the cell's four top corners,
##              each 0, 1 or 2 half-blocks (see corner_heights). (2,2,2,2) is the cube itself and is never stored.
##   bit 16     DUG: a natural block that has been partly dug. This is a primary state of the ground, as opposed to
##              a slope piece, which is derived from the neighbours (see Ramps / TerrainEdit).
## Corners are numbered (0,0), (1,0), (1,1), (0,1) in (x, z).

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

const MAT_MASK := 255
const SHAPE_SHIFT := 8
const DUG_FLAG := 1 << 16

const SHAPE_CUBE := 0
## Flat half-height slab: all four corners at one half-block. A half-dug block looks like this.
const SHAPE_HALF := 41

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


# --- packing ------------------------------------------------------------------------------------

static func mat(raw: int) -> int:
	return raw & MAT_MASK


static func shape(raw: int) -> int:
	return (raw >> SHAPE_SHIFT) & 255


static func is_dug(raw: int) -> bool:
	return (raw & DUG_FLAG) != 0


static func make(material: int, shape_id: int = SHAPE_CUBE, dug := false) -> int:
	return material | (shape_id << SHAPE_SHIFT) | (DUG_FLAG if dug else 0)


## Heights (0, 1 or 2 half-blocks) of the four top corners of a shape.
static func corner_heights(shape_id: int) -> Array[int]:
	if shape_id == SHAPE_CUBE:
		return [2, 2, 2, 2]
	var c := shape_id - 1
	return [c % 3, (c / 3) % 3, (c / 9) % 3, (c / 27) % 3]


## Shape id for four corner heights; SHAPE_CUBE when all are 2, -1 when all are 0 (nothing there).
static func shape_from_corners(h0: int, h1: int, h2: int, h3: int) -> int:
	if h0 == 2 and h1 == 2 and h2 == 2 and h3 == 2:
		return SHAPE_CUBE
	if h0 == 0 and h1 == 0 and h2 == 0 and h3 == 0:
		return -1
	return 1 + h0 + 3 * h1 + 9 * h2 + 27 * h3


## What a block turns into when it is dug: the grass on top is torn up and the earth shows, snow gives way to stone.
## Grass does not grow back on its own.
static func dug_material(material: int) -> int:
	match material:
		GRASS:
			return DIRT
		SNOW:
			return STONE
		_:
			return material


## Highest corner of a shape, in half-blocks (2 for a cube).
static func max_height(shape_id: int) -> int:
	var h := corner_heights(shape_id)
	return maxi(maxi(h[0], h[1]), maxi(h[2], h[3]))


# --- queries ------------------------------------------------------------------------------------

## Hides the faces of neighbours: only full cubes do.
static func is_opaque(raw: int) -> bool:
	var m := raw & MAT_MASK
	return m != AIR and m != WATER and shape(raw) == SHAPE_CUBE


static func is_solid(raw: int) -> bool:
	var m := raw & MAT_MASK
	return m != AIR and m != WATER


## A solid, full cube: the only thing bricks may stand on and the only thing that sets a column's height.
static func is_whole(raw: int) -> bool:
	return is_opaque(raw)


## Ground that is neither whole nor air: a slope piece or a partly dug block.
static func is_partial(raw: int) -> bool:
	return is_solid(raw) and shape(raw) != SHAPE_CUBE


## A slope piece derived from the neighbours (partial, not dug).
static func is_skin(raw: int) -> bool:
	return is_partial(raw) and not is_dug(raw)


static func is_diggable(raw: int) -> bool:
	var m := raw & MAT_MASK
	return m != AIR and m != BEDROCK and m != WATER


static func color_of(raw: int, face: int) -> Color:
	var set: Array = _COLORS.get(raw & MAT_MASK, [Color.MAGENTA, Color.MAGENTA, Color.MAGENTA])
	return set[face]
