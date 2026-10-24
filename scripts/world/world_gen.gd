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
var preset: MapPreset

## Heights above the island's base_top where bare rock and then snow start (set from the world height).
var rock_y := 70
var snow_y := 88

var _shape: FastNoiseLite
var _ridge: FastNoiseLite
var _pass: FastNoiseLite
var _region: FastNoiseLite
var _hills: FastNoiseLite
var _detail: FastNoiseLite
var _under: FastNoiseLite
var _cave: FastNoiseLite
var _coal: FastNoiseLite
var _iron: FastNoiseLite
var _orange: FastNoiseLite
var _max_y: int


func _init(world_seed: int, size: Vector3i, map_preset: MapPreset) -> void:
	preset = map_preset
	_max_y = size.y - 2
	rock_y = int(size.y * 0.62)
	snow_y = int(size.y * 0.78)
	_shape = _make_noise(world_seed, 0.018, 3)
	_hills = _make_noise(world_seed + 1, 0.021, 2)
	_ridge = _make_noise(world_seed + 7, 0.024, 3)
	_pass = _make_noise(world_seed + 8, 0.016, 2)
	_region = _make_noise(world_seed + 9, 0.013, 2)
	_detail = _make_noise(world_seed + 2, 0.045, 2)
	_under = _make_noise(world_seed + 3, 0.05, 2)
	_cave = _make_noise(world_seed + 4, 0.055, 2)
	_coal = _make_noise(world_seed + 5, 0.12, 1)
	_iron = _make_noise(world_seed + 6, 0.14, 1)
	_orange = _make_noise(world_seed + 10, 0.16, 1)
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
	var mid_top := int(size.y * 0.42)
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
	# Flat build area in the middle of each island, fading into the wild terrain.
	var flat := 1.0 - smoothstep(preset.flat_share, preset.flat_share + 0.25, 1.0 - best_m)
	flat *= 0.92 if best == islands[0] else 0.4
	var hills := _hills.get_noise_2d(wx, wz) * preset.hills_amp
	# Mountains: ridged noise, only inside "mountain regions", cut by winding passes (valleys) where the pass noise crosses 0.
	var ridge_line := pow(1.0 - absf(_ridge.get_noise_2d(wx, wz)), 1.4)
	var bulk := _ridge.get_noise_2d(wx * 0.45 + 500.0, wz * 0.45) * 0.5 + 0.5
	var ridge := ridge_line * 0.6 + bulk * 0.4
	var mountain_mask := smoothstep(preset.mountain_region.x, preset.mountain_region.y, _region.get_noise_2d(wx, wz))
	var corridor := smoothstep(preset.pass_width.x, preset.pass_width.y, absf(_pass.get_noise_2d(wx, wz)))
	var amp := clampf(float(_max_y - best.base_top) - 14.0, 10.0, preset.mountain_amp)
	var mountains := ridge * amp * mountain_mask * corridor
	var rel := (hills + mountains) * (1.0 - flat) * rim
	# Plateaus: snap to the nearest level, but let the ground slope inside passes so levels connect.
	var step := preset.terrace_step
	var level := floorf(rel / step + 0.5) * step
	var slope := 1.0 - smoothstep(preset.pass_ramp.x, preset.pass_ramp.y, absf(_pass.get_noise_2d(wx, wz)))
	# Gentle undulation inside a plateau: 1-block steps that the ramp wedges smooth out.
	var bumps := roundf(_detail.get_noise_2d(wx, wz) * 1.7) * rim * (1.0 - flat * 0.85)
	var top := best.base_top + lerpf(level, rel, slope) + bumps
	var depth := 3.0 + best.thickness * pow(best_m, 0.75) + _under.get_noise_2d(wx, wz) * 4.0 * best_m
	var top_i := clampi(int(top), 4, _max_y)
	var bottom_i := clampi(top_i - int(depth), 1, top_i)
	return Vector2i(top_i, bottom_i)


func block_at(wx: int, wy: int, wz: int, top: int, bottom: int) -> int:
	if wy > top or wy < bottom:
		return Blocks.AIR
	var depth := top - wy
	if depth == 0:
		if wy >= snow_y:
			return Blocks.SNOW
		return Blocks.STONE if wy >= rock_y else preset.top_block
	if depth <= preset.dirt_depth:
		return Blocks.STONE if wy >= rock_y else preset.sub_block
	if wy > bottom + 3 and depth > cave_depth and _cave.get_noise_3d(wx, wy * 1.6, wz) > 0.55:
		return Blocks.AIR
	if depth > 2 and _orange.get_noise_3d(wx, wy, wz) > 0.70:
		return Blocks.ORANGE_ORE
	if _coal.get_noise_3d(wx, wy, wz) > 0.62:
		return Blocks.COAL
	if depth > 10 and _iron.get_noise_3d(wx, wy, wz) > 0.66:
		return Blocks.IRON
	return Blocks.STONE


## Shape of the cell right above a column's top: a ramp wedge when exactly one neighbouring column is one block higher
## (and none is higher still), so a 1-block drop becomes a slope: the high side of the wedge leans on that neighbour.
func ramp_shape(wx: int, wz: int, top: int) -> int:
	var found := 0
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for i in 4:
		var n := column(wx + dirs[i].x, wz + dirs[i].y)
		if n.x < 0:
			continue
		if n.x >= top + 2:
			return Blocks.SHAPE_CUBE
		if n.x == top + 1:
			if found != 0:
				return Blocks.SHAPE_CUBE
			found = i + 1
	return found   # 0 none, 1..4 = wedge high side +X, -X, +Z, -Z


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
			if col.x >= 0 and col.x + 1 >= oy and col.y <= oy + cs - 1:
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
			var ramp_y := top + 1 - oy
			if ramp_y >= 0 and ramp_y < cs and top + 1 <= _max_y:
				var shape := ramp_shape(ox + x, oz + z, top)
				if shape != Blocks.SHAPE_CUBE:
					data[x + (z << 4) + (ramp_y << 8)] = Blocks.make(block_at(ox + x, top, oz + z, top, bottom), shape)
	return data
