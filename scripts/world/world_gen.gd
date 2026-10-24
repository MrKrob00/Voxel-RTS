class_name WorldGen
extends RefCounted
## Floating-island archipelago. Pure function of (seed, position): touches no scene, so it is safe on worker threads.
## Islands are laid out once from the seed (one large start island in the middle, smaller ones around it),
## then every column is answered independently: a top height and a bottom height, or nothing (open sky).

class Island extends RefCounted:
	var center: Vector2
	var radius: float
	var base_top: int
	var thickness: int

	func _init(c: Vector2, r: float, top: int, thick: int) -> void:
		center = c
		radius = r
		base_top = top
		thickness = thick


const EMPTY := Vector2i(-1, -1)

var islands: Array[Island] = []
var cave_depth := 6

var _shape: FastNoiseLite
var _hills: FastNoiseLite
var _detail: FastNoiseLite
var _under: FastNoiseLite
var _cave: FastNoiseLite
var _coal: FastNoiseLite
var _iron: FastNoiseLite
var _max_y: int


func _init(world_seed: int, size: Vector3i) -> void:
	_max_y = size.y - 2
	_shape = _make_noise(world_seed, 0.018, 3)
	_hills = _make_noise(world_seed + 1, 0.03, 3)
	_detail = _make_noise(world_seed + 2, 0.09, 2)
	_under = _make_noise(world_seed + 3, 0.05, 2)
	_cave = _make_noise(world_seed + 4, 0.055, 2)
	_coal = _make_noise(world_seed + 5, 0.12, 1)
	_iron = _make_noise(world_seed + 6, 0.14, 1)
	_layout_islands(world_seed, size)


static func _make_noise(noise_seed: int, freq: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = noise_seed
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	if octaves > 1:
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = octaves
	else:
		n.fractal_type = FastNoiseLite.FRACTAL_NONE
	return n


func _layout_islands(world_seed: int, size: Vector3i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed
	var mid := Vector2(size.x, size.z) * 0.5
	var scale := minf(size.x, size.z) / 256.0
	var mid_top := int(size.y * 0.5)
	# Start island: big, flat enough to build a first base.
	islands.append(Island.new(mid, 42.0 * scale, mid_top, 30))
	# Outer islands on the diagonals (gaps of ~14 blocks to the start island, needs bridges).
	var outer := 4
	for i in outer:
		var angle := TAU * (float(i) + 0.5) / outer + rng.randf_range(-0.2, 0.2)
		var dist := rng.randf_range(96.0, 104.0) * scale
		var r := rng.randf_range(23.0, 29.0) * scale
		var top := mid_top + rng.randi_range(-8, 8)
		islands.append(Island.new(mid + Vector2.from_angle(angle) * dist, r, top, rng.randi_range(18, 24)))


## The point where the start island has ground, with the surface y measured by the generator.
func spawn_column() -> Vector2i:
	var c := islands[0].center
	return Vector2i(int(c.x), int(c.y))


## Top and bottom (inclusive) of solid ground in a column, or EMPTY for open sky.
func column(wx: int, wz: int) -> Vector2i:
	var best: Island = null
	var best_m := 0.0
	var p := Vector2(wx, wz)
	var n := _shape.get_noise_2d(wx, wz)
	for isl in islands:
		var d := p.distance_to(isl.center) / isl.radius
		d *= 1.0 + n * 0.22
		var m := 1.0 - d
		if m > best_m:
			best_m = m
			best = isl
	if best == null:
		return EMPTY
	var rim := minf(1.0, best_m * 4.0)
	var top := best.base_top + _hills.get_noise_2d(wx, wz) * 5.0 * rim + _detail.get_noise_2d(wx, wz) * 1.5 * rim + best_m * 5.0
	var depth := 3.0 + best.thickness * pow(best_m, 0.75) + _under.get_noise_2d(wx, wz) * 4.0 * best_m
	var top_i := clampi(int(top), 4, _max_y)
	var bottom_i := clampi(top_i - int(depth), 1, top_i)
	return Vector2i(top_i, bottom_i)


func block_at(wx: int, wy: int, wz: int, top: int, bottom: int) -> int:
	if wy > top or wy < bottom:
		return Blocks.AIR
	var depth := top - wy
	if depth == 0:
		return Blocks.GRASS
	if depth <= 3:
		return Blocks.DIRT
	if wy > bottom + 3 and depth > cave_depth and _cave.get_noise_3d(wx, wy * 1.6, wz) > 0.55:
		return Blocks.AIR
	if _coal.get_noise_3d(wx, wy, wz) > 0.62:
		return Blocks.COAL
	if depth > 10 and _iron.get_noise_3d(wx, wy, wz) > 0.66:
		return Blocks.IRON
	return Blocks.STONE


## Returns an empty array when the chunk is entirely open sky (nothing stored, nothing meshed).
func generate_chunk(cpos: Vector3i) -> PackedByteArray:
	var cs := Blocks.CHUNK_SIZE
	var ox := cpos.x * cs
	var oy := cpos.y * cs
	var oz := cpos.z * cs
	var tops := PackedInt32Array()
	var bottoms := PackedInt32Array()
	tops.resize(cs * cs)
	bottoms.resize(cs * cs)
	var any := false
	for z in cs:
		for x in cs:
			var col := column(ox + x, oz + z)
			var i := x + (z << 4)
			tops[i] = col.x
			bottoms[i] = col.y
			if col.x >= 0 and col.x >= oy and col.y <= oy + cs - 1:
				any = true
	if not any:
		return PackedByteArray()
	var data := PackedByteArray()
	data.resize(Blocks.CHUNK_VOLUME)
	for z in cs:
		for x in cs:
			var i := x + (z << 4)
			var top := tops[i]
			if top < 0:
				continue
			var bottom := bottoms[i]
			for y in cs:
				data[x + (z << 4) + (y << 8)] = block_at(ox + x, oy + y, oz + z, top, bottom)
	return data
