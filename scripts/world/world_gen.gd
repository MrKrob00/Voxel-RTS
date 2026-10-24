class_name WorldGen
extends RefCounted
## Procedural terrain. Pure function of (seed, position): touches no scene, so it is safe on worker threads.

const BEDROCK_LEVEL := 0

var sea_level := 20
var base_height := 26.0
var amplitude := 18.0
var cave_depth := 6

var _height: FastNoiseLite
var _detail: FastNoiseLite
var _cave: FastNoiseLite
var _coal: FastNoiseLite
var _iron: FastNoiseLite
var _max_y: int


func _init(world_seed: int, height_blocks: int) -> void:
	_max_y = height_blocks - 2
	_height = _make_noise(world_seed, 0.010, 4, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	_detail = _make_noise(world_seed + 1, 0.045, 2, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	_cave = _make_noise(world_seed + 2, 0.055, 2, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	_coal = _make_noise(world_seed + 3, 0.12, 1, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	_iron = _make_noise(world_seed + 4, 0.14, 1, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)


static func _make_noise(noise_seed: int, freq: float, octaves: int, type: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = noise_seed
	n.noise_type = type
	n.frequency = freq
	if octaves > 1:
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = octaves
	else:
		n.fractal_type = FastNoiseLite.FRACTAL_NONE
	return n


## Surface height (top solid voxel y) of the column at a world point.
func column_height(wx: int, wz: int) -> int:
	var h := base_height + _height.get_noise_2d(wx, wz) * amplitude + _detail.get_noise_2d(wx, wz) * 2.5
	return clampi(int(h), 3, _max_y)


func block_at(wx: int, wy: int, wz: int, h: int) -> int:
	if wy <= BEDROCK_LEVEL:
		return Blocks.BEDROCK
	if wy > h:
		return Blocks.WATER if wy <= sea_level else Blocks.AIR
	var depth := h - wy
	var beach := h <= sea_level + 1
	if depth == 0:
		return Blocks.SAND if beach else Blocks.GRASS
	if depth <= 3:
		return Blocks.SAND if beach else Blocks.DIRT
	if wy > 2 and depth > cave_depth and _cave.get_noise_3d(wx, wy * 1.6, wz) > 0.55:
		return Blocks.AIR
	if _coal.get_noise_3d(wx, wy, wz) > 0.62:
		return Blocks.COAL
	if wy < 24 and _iron.get_noise_3d(wx, wy, wz) > 0.66:
		return Blocks.IRON
	return Blocks.STONE


func generate_chunk(cpos: Vector3i) -> PackedByteArray:
	var cs := Blocks.CHUNK_SIZE
	var data := PackedByteArray()
	data.resize(Blocks.CHUNK_VOLUME)
	var ox := cpos.x * cs
	var oy := cpos.y * cs
	var oz := cpos.z * cs
	for z in cs:
		for x in cs:
			var h := column_height(ox + x, oz + z)
			for y in cs:
				data[x + (z << 4) + (y << 8)] = block_at(ox + x, oy + y, oz + z, h)
	return data
