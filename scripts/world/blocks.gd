class_name Blocks
extends RefCounted
## The voxel format and block palette. A voxel is one int:
##   bits 0-7    material (AIR, GRASS, ...)
##   bits 8-17   shape: 0 is a full cube; any other value is 1 + the heights of the cell's four top corners, each from
##               0 to 4 quarter-blocks (see corner_heights). (4,4,4,4) is the cube itself and is never stored.
##   bit 19      STAIRS: a slope piece made of four steps instead of a smooth ramp (shape: the wedge it follows). Only workers
##               make it (a quarry leaves one at every second column of its staircase); the generator never does and the
##               neighbour rules never touch it.
##   bit 18      DUG: a natural block that has been partly dug. It keeps its material (a dug grass block still holds its
##               turf), stands DUG_HEIGHT quarters high in the middle and its corners are drawn up to the whole
##               neighbours, so the pit has sloping sides. Its shape is a corner mask (which corners are raised to a full
##               block) and a dip mask (which sides border another dug block, so the pits run into each other).
##               This is a primary state of the ground, as opposed to a slope piece, which is derived from the
##               neighbours (Ramps / TerrainEdit).
## Corners are numbered (0,0), (1,0), (1,1), (0,1) in (x, z). All heights are in quarter-blocks (UNIT per block).

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
const SHAPE_MASK := 1023
const DUG_FLAG := 1 << 18
const STAIRS_FLAG := 1 << 19
const STAIR_STEPS := 4

## Quarter-blocks per block: the unit of every height.
const UNIT := 4
## How high a half-dug block stands in the middle (3 of 4: a small step down, not half the block).
const DUG_HEIGHT := 3

const SHAPE_CUBE := 0
## Shapes from here up belong to dug blocks: DUG_SHAPE_BASE + 16 * corner_mask + dip_mask.
const DUG_SHAPE_BASE := 700
## A dug block whose four corners are all at DUG_HEIGHT: a flat pit floor.
const SHAPE_DUG := DUG_SHAPE_BASE
## A dug block whose four corners are all raised to the full block: a bowl in the middle of whole neighbours.
const SHAPE_BOWL := DUG_SHAPE_BASE + 16 * 15

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
	return (raw >> SHAPE_SHIFT) & SHAPE_MASK


static func is_dug(raw: int) -> bool:
	return (raw & DUG_FLAG) != 0


static func is_stairs(raw: int) -> bool:
	return (raw & STAIRS_FLAG) != 0


static func make(material: int, shape_id: int = SHAPE_CUBE, dug := false, stairs := false) -> int:
	return material | (shape_id << SHAPE_SHIFT) | (DUG_FLAG if dug else 0) | (STAIRS_FLAG if stairs else 0)


## The wedge of a stair piece that rises towards `dir` (a unit step in x or z): the two corners on that side are a full block high.
static func wedge_towards(dir: Vector2i) -> int:
	if dir.x > 0:
		return shape_from_corners(0, UNIT, UNIT, 0)
	if dir.x < 0:
		return shape_from_corners(UNIT, 0, 0, UNIT)
	if dir.y > 0:
		return shape_from_corners(0, 0, UNIT, UNIT)
	return shape_from_corners(UNIT, UNIT, 0, 0)


## Which way a stair piece rises: a unit step (x, z), or (0, 0) if the shape is not a plain wedge.
static func wedge_direction(shape_id: int) -> Vector2i:
	var h := corner_heights(shape_id)
	var hi := [h[0] == UNIT, h[1] == UNIT, h[2] == UNIT, h[3] == UNIT]
	var lo := [h[0] == 0, h[1] == 0, h[2] == 0, h[3] == 0]
	if hi[1] and hi[2] and lo[0] and lo[3]:
		return Vector2i(1, 0)
	if hi[0] and hi[3] and lo[1] and lo[2]:
		return Vector2i(-1, 0)
	if hi[2] and hi[3] and lo[0] and lo[1]:
		return Vector2i(0, 1)
	if hi[0] and hi[1] and lo[2] and lo[3]:
		return Vector2i(0, -1)
	return Vector2i.ZERO


## Heights (0 to 4 quarter-blocks) of the four top corners of a shape.
static func corner_heights(shape_id: int) -> Array[int]:
	if shape_id == SHAPE_CUBE:
		return [UNIT, UNIT, UNIT, UNIT]
	if shape_id >= DUG_SHAPE_BASE:
		var mask := dug_corner_mask(shape_id)
		return [UNIT if mask & 1 else DUG_HEIGHT, UNIT if mask & 2 else DUG_HEIGHT, UNIT if mask & 4 else DUG_HEIGHT, UNIT if mask & 8 else DUG_HEIGHT]
	var c := shape_id - 1
	return [c % 5, (c / 5) % 5, (c / 25) % 5, (c / 125) % 5]


## Shape id of a slope piece for four corner heights; SHAPE_CUBE when all are UNIT, -1 when all are 0 (nothing there).
static func shape_from_corners(h0: int, h1: int, h2: int, h3: int) -> int:
	if h0 == UNIT and h1 == UNIT and h2 == UNIT and h3 == UNIT:
		return SHAPE_CUBE
	if h0 == 0 and h1 == 0 and h2 == 0 and h3 == 0:
		return -1
	return 1 + h0 + 5 * h1 + 25 * h2 + 125 * h3


## Shape id of a dug block. `corner_mask` bit k: corner k is raised to a full block (otherwise DUG_HEIGHT).
## `dip_mask` bit s: side s borders another dug block, so its middle sinks to DUG_HEIGHT (sides: +x, -x, +z, -z).
static func dug_shape(corner_mask: int, dip_mask: int) -> int:
	return DUG_SHAPE_BASE + 16 * corner_mask + dip_mask


static func dug_corner_mask(shape_id: int) -> int:
	return ((shape_id - DUG_SHAPE_BASE) >> 4) & 15


static func dug_dip_mask(shape_id: int) -> int:
	return (shape_id - DUG_SHAPE_BASE) & 15


## The material that shows at the bottom of a half-dug block: the turf is torn up and the earth shows, snow gives way to
## stone. The block itself keeps its material, so building it up again brings the grass back.
static func dug_bottom_material(material: int) -> int:
	match material:
		GRASS:
			return DIRT
		SNOW:
			return STONE
		_:
			return material


## Which diagonal splits the top of a slope piece into two triangles: 0 joins corners 0-2, 1 joins corners 1-3. A ridge (one
## corner highest) or a valley (one corner lowest) is split through that corner, so the surface does not fold the wrong way.
## The mesher and surface_height agree on it.
static func top_diagonal(h: Array[int]) -> int:
	var s02: int = h[0] + h[2]
	var s13: int = h[1] + h[3]
	if s02 == s13:
		return 0
	var hi: int = maxi(maxi(h[0], h[1]), maxi(h[2], h[3]))
	var lo: int = mini(mini(h[0], h[1]), mini(h[2], h[3]))
	var hi_idx: Array[int] = []
	var lo_idx: Array[int] = []
	for k in 4:
		if h[k] == hi:
			hi_idx.append(k)
		if h[k] == lo:
			lo_idx.append(k)
	if hi_idx.size() == 1:
		return 0 if hi_idx[0] % 2 == 0 else 1
	if lo_idx.size() == 1:
		return 0 if lo_idx[0] % 2 == 0 else 1
	return 0 if s02 > s13 else 1


## Height of the top surface of a piece at (u, v) inside its cell (both 0..1, x and z), in blocks (0..1): what a unit
## standing there has under its feet. Follows the same triangles as the mesh, and for a half-dug block its flat floor.
static func surface_height(shape_id: int, u: float, v: float, stairs := false) -> float:
	if shape_id == SHAPE_CUBE:
		return 1.0
	if stairs:
		var smooth := surface_height(shape_id, u, v, false)
		return minf(1.0, (floorf(smooth * STAIR_STEPS - 0.0001) + 1.0) / STAIR_STEPS) if smooth > 0.0 else 1.0 / STAIR_STEPS
	var h := corner_heights(shape_id)
	var q := 1.0 / UNIT
	if shape_id >= DUG_SHAPE_BASE:
		# Flat floor in the middle, slopes out to the rim: blend from the floor height to the bilinear rim height.
		var edge := maxf(absf(u - 0.5), absf(v - 0.5))
		var t := clampf((edge - 0.25) / 0.25, 0.0, 1.0)
		var bil: float = lerpf(lerpf(h[0], h[1], u), lerpf(h[3], h[2], u), v)
		return lerpf(float(DUG_HEIGHT), minf(bil, float(UNIT)), t) * q
	var hh: float
	if top_diagonal(h) == 0:
		if u >= v:
			hh = h[0] + (h[1] - h[0]) * u + (h[2] - h[1]) * v
		else:
			hh = h[0] + (h[2] - h[3]) * u + (h[3] - h[0]) * v
	else:
		if u + v <= 1.0:
			hh = h[0] + (h[1] - h[0]) * u + (h[3] - h[0]) * v
		else:
			hh = h[2] + (h[3] - h[2]) * (1.0 - u) + (h[1] - h[2]) * (1.0 - v)
	return hh * q


## Highest corner of a shape, in quarter-blocks (UNIT for a cube).
static func max_height(shape_id: int) -> int:
	var h := corner_heights(shape_id)
	return maxi(maxi(h[0], h[1]), maxi(h[2], h[3]))


# --- queries ------------------------------------------------------------------------------------

## Hides the faces of neighbours: only full cubes do.
static func is_opaque(raw: int) -> bool:
	var m := raw & MAT_MASK
	return m != AIR and m != WATER and (raw >> SHAPE_SHIFT) & SHAPE_MASK == SHAPE_CUBE


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
	return is_partial(raw) and not is_dug(raw) and not is_stairs(raw)


static func is_diggable(raw: int) -> bool:
	var m := raw & MAT_MASK
	return m != AIR and m != BEDROCK and m != WATER


static func color_of(raw: int, face: int) -> Color:
	var set: Array = _COLORS.get(raw & MAT_MASK, [Color.MAGENTA, Color.MAGENTA, Color.MAGENTA])
	return set[face]
