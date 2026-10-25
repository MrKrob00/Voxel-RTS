class_name WorldGen
extends RefCounted
## Floating-island archipelago. Pure function of (seed, position): touches no scene, so it is safe on worker threads.
## Islands are laid out once from the seed: ONE main island in the middle (the start) and 0-4 extra islands around it
## (at most 5 in all), each joined to the nearest earlier island by a plank bridge. After that every column is
## answered independently: a top height and a bottom height, or nothing (open sky).

class Island extends RefCounted:
	var center: Vector2
	var radius: float
	var base_top: int
	var thickness: int
	var anchor := 0   ## index of the island this one hangs off (for bridges)
	var shape_amp := 0.22   ## how ragged the outline is: bays and peninsulas

	func _init(c: Vector2, r: float, top: int, thick: int) -> void:
		center = c
		radius = r
		base_top = top
		thickness = thick


class Bridge extends RefCounted:
	var a: Vector2          ## first end, at the rim of one island
	var b: Vector2          ## last end, at the rim of the other island
	var ha: int             ## ground height at a
	var hb: int
	var style := 0          ## 0: grassy neck, 1: bare stone arch
	var sway := 0.0         ## sideways S-curve amplitude, blocks
	var waves := 1          ## half-waves of the curve (1 or 2)
	var hump := 0.0         ## how much the middle rises above the straight ramp, blocks
	var width_phase := 0.0
	var base_width := 2.2   ## half-width of the strip before the pinches, blocks

	func _init(pa: Vector2, pb: Vector2, ya: int, yb: int) -> void:
		a = pa
		b = pb
		ha = ya
		hb = yb

	func length() -> float:
		return a.distance_to(b)

	## Where the centre line of the bridge is at parameter t (0..1): a chord that swings sideways in an S-curve.
	func centre(t: float) -> Vector2:
		var ab := b - a
		var perp := Vector2(-ab.y, ab.x).normalized()
		return a + ab * t + perp * lateral_offset(t)

	## The curve is straight near both islands (so the landings are clean) and swings out in the middle.
	func lateral_offset(t: float) -> float:
		return sway * sin(PI * t * waves) * smoothstep(0.0, 0.3, minf(t, 1.0 - t))


const EMPTY := Vector2i(-1, -1)
const MAX_EXTRA_ISLANDS := 4

var islands: Array[Island] = []   ## [0] is the main (start) island
var bridges: Array[Bridge] = []
var extra_count := 0
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
var _pocket: FastNoiseLite
var _dirt_extra: FastNoiseLite
var _max_y: int
var _region_cache := {}
var _region_mutex := Mutex.new()


func _init(world_seed: int, size: Vector3i, map_preset: MapPreset, forced_extra := -1) -> void:
	preset = map_preset
	_max_y = size.y - 2
	rock_y = int(size.y * 0.62)
	snow_y = int(size.y * 0.78)
	_shape = _make_noise(world_seed, 0.018, 3)
	_hills = _make_noise(world_seed + 1, 0.014, 2)
	_ridge = _make_noise(world_seed + 7, 0.024, 3)
	_pass = _make_noise(world_seed + 8, 0.016, 2)
	_region = _make_noise(world_seed + 9, 0.013, 2)
	_detail = _make_noise(world_seed + 2, 0.045, 2)
	_under = _make_noise(world_seed + 3, 0.05, 2)
	_cave = _make_noise(world_seed + 4, 0.055, 2)
	_coal = _make_noise(world_seed + 5, 0.12, 1)
	_iron = _make_noise(world_seed + 6, 0.14, 1)
	_orange = _make_noise(world_seed + 10, 0.16, 1)
	_pocket = _make_noise(world_seed + 11, 0.11, 1)
	_dirt_extra = _make_noise(world_seed + 12, 0.05, 2)
	_layout_islands(world_seed, size, forced_extra)
	_build_bridges()


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


func _layout_islands(world_seed: int, size: Vector3i, forced_extra: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed
	var mid := Vector2(size.x, size.z) * 0.5
	var scale := minf(size.x, size.z) / 256.0
	var mid_top := int(size.y * 0.42)
	# The main island: big, with a flat build area in the middle.
	islands.append(Island.new(mid, 46.0 * scale, mid_top, 30))
	extra_count = clampi(forced_extra, 0, MAX_EXTRA_ISLANDS) if forced_extra >= 0 else rng.randi_range(0, MAX_EXTRA_ISLANDS)
	var placed := 0
	var tries := 0
	while placed < extra_count and tries < 400:
		tries += 1
		var r := rng.randf_range(18.0, 28.0) * scale
		var anchor: Island = islands[rng.randi() % islands.size()]
		var dist := (anchor.radius + r) * 1.05 + rng.randf_range(10.0, 16.0)
		var c := anchor.center + Vector2.from_angle(rng.randf() * TAU) * dist
		var margin := r * 1.15 + 4.0
		if c.x < margin or c.y < margin or c.x > size.x - margin or c.y > size.z - margin:
			continue
		var clear := true
		for other in islands:
			if c.distance_to(other.center) < (other.radius + r) * 1.05 + 8.0:
				clear = false
				break
		# The straight line to the anchor must not cut through a third island.
		for k in islands.size():
			var third := islands[k]
			if third == anchor:
				continue
			var seg := Geometry2D.get_closest_point_to_segment(third.center, c, anchor.center)
			if seg.distance_to(third.center) < third.radius * 1.3 + 6.0:
				clear = false
				break
		if not clear:
			continue
		# Neighbouring islands sit at similar heights so the bridge between them stays walkable.
		var top := clampi(anchor.base_top + rng.randi_range(-3, 3), mid_top - 6, mid_top + 6)
		var isl := Island.new(c, r, top, rng.randi_range(16, 22))
		isl.shape_amp = 0.34   # extras get more bays and peninsulas than the main island
		isl.anchor = islands.find(anchor)
		islands.append(isl)
		placed += 1
	extra_count = placed


## One bridge from every extra island to the island it was placed next to, so the whole map is connected on foot.
## Islands that already touch need none. Each bridge gets its own look: grassy neck or bare stone arch, a sideways
## S-curve, pinches in its width and a raised back.
func _build_bridges() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(islands.size(), islands[0].center)) + 17
	for i in range(1, islands.size()):
		var isl := islands[i]
		var other := islands[isl.anchor]
		var edge_a := _rim_point(other, isl.center)   # leaving `other` towards `isl`
		var edge_b := _rim_point(isl, other.center)
		var dir := (isl.center - other.center).normalized()
		if (edge_b[0] - edge_a[0]).dot(dir) < 3.0:
			continue   # rims meet or overlap
		var br := Bridge.new(edge_a[0], edge_b[0], edge_a[1], edge_b[1])
		var len := br.length()
		br.style = rng.randi() % 2
		br.waves = 1 + rng.randi() % 2
		br.sway = rng.randf_range(0.0, 1.0) * minf(7.0, len * 0.28) * (1.0 if rng.randf() < 0.5 else -1.0)
		var wanted_hump := 3.0 if br.style == 1 else float(rng.randi_range(0, 2))
		# Keep the climb under one block per step: the hump may only use what the length leaves after the height difference.
		br.hump = clampf((0.85 * len - absf(br.ha - br.hb)) / PI, 0.0, wanted_hump)
		br.width_phase = rng.randf() * TAU
		br.base_width = rng.randf_range(1.9, 2.5)
		bridges.append(br)


## How far inside an island's own outline a point is (above 0 means ground belongs to this island).
func _own_influence(isl: Island, p: Vector2) -> float:
	var d := p.distance_to(isl.center) / isl.radius
	d *= 1.0 + _shape.get_noise_2d(p.x, p.y) * isl.shape_amp
	return 1.0 - d


## Walks from an island's centre towards `target` and returns [last point still on this island, its top height].
func _rim_point(isl: Island, target: Vector2) -> Array:
	var dir := (target - isl.center).normalized()
	var p := isl.center
	var last := p
	for i in int(isl.radius * 2.0) + 40:
		if _own_influence(isl, p) <= 0.0:
			break
		last = p
		p += dir
	var col := _island_column(int(last.x), int(last.y))
	return [last, col.x if col != EMPTY else isl.base_top]


## The point where the start island has ground, with the surface y measured by the generator.
func spawn_column() -> Vector2i:
	var c := islands[0].center
	return Vector2i(int(c.x), int(c.y))


## Top and bottom (inclusive) of solid ground in a column, or EMPTY for open sky.
func column(wx: int, wz: int) -> Vector2i:
	var v := column_full(wx, wz)
	return EMPTY if v.x < 0 else Vector2i(v.x, v.y)


## Like column(), plus the bridge style in z (-1 for island ground, 0 / 1 for a bridge); x < 0 means open sky.
## Island ground has 1-block pits and 1-wide trenches filled in (Ramps.despeckle).
func column_full(wx: int, wz: int) -> Vector3i:
	var v := raw_column(wx, wz)
	if v.z != -1 or v.x < 0:
		return v
	var px := raw_column(wx + 1, wz)
	var nx := raw_column(wx - 1, wz)
	var pz := raw_column(wx, wz + 1)
	var nz := raw_column(wx, wz - 1)
	var top := Ramps.despeckle(v.x, px.x, nx.x, pz.x, nz.x)
	return Vector3i(top, v.y, -1)


## The column before despeckling.
func raw_column(wx: int, wz: int) -> Vector3i:
	var c := _island_column(wx, wz)
	if bridges.is_empty():
		return Vector3i(c.x, c.y, -1)
	var p := Vector2(wx + 0.5, wz + 0.5)   # centre of the cell
	if c != EMPTY:
		# In the middle of a bridge the deck wins over a ragged island peninsula it crosses, so it stays continuous.
		var over := _bridge_at(wx, wz, p, true)
		if over.x >= 0:
			return Vector3i(over.x, mini(over.y, c.y), over.z)
		c = _landing_pad(p, c)
		return Vector3i(c.x, c.y, -1)
	return _bridge_at(wx, wz, p)


## A bridge strip is the set of points close to its curved centre line. Width pinches and swells along it, the deck
## rises into a hump, and the underside is thick near the islands and thin in the middle (an arch), with a few
## stalactites hanging from the thin part.
func _bridge_at(wx: int, wz: int, p: Vector2, only_middle := false) -> Vector3i:
	for br in bridges:
		var ab := br.b - br.a
		var len2 := ab.length_squared()
		if len2 < 1.0:
			continue
		var t := (p - br.a).dot(ab) / len2
		if t < -0.1 or t > 1.1:
			continue
		t = clampf(t, 0.0, 1.0)
		if only_middle and (t < 0.14 or t > 0.86):
			continue
		var perp := Vector2(-ab.y, ab.x).normalized()
		var lateral := (p - br.a).dot(perp) - br.lateral_offset(t)
		# Width: wide landings at both ends, pinches in between, a bulge (rest platform) in the middle of long bridges.
		var edge := smoothstep(0.0, 0.22, minf(t, 1.0 - t))
		var pinch := br.base_width + 0.8 * sin(t * TAU * 1.5 + br.width_phase)
		var w := lerpf(3.4, maxf(pinch, 1.3), edge)
		if br.length() > 26.0:
			w += 2.2 * (1.0 - smoothstep(0.0, 0.1, absf(t - 0.5)))
		w += _shape.get_noise_2d(wx * 2.3, wz * 2.3) * 0.8
		if absf(lateral) > w:
			continue
		var y := clampi(roundi(lerpf(br.ha, br.hb, t) + br.hump * sin(PI * t)), 4, _max_y)
		var thick: int
		if br.style == 1:
			thick = 2 + int(round(4.0 * pow(1.0 - sin(PI * t), 1.2)))
			if _under.get_noise_2d(wx * 1.7, wz * 1.7) > 0.45 and absf(lateral) < w * 0.6:
				thick += 3   # stalactite
		else:
			thick = 4 + int(_under.get_noise_2d(wx, wz) * 1.6)
		return Vector3i(y, maxi(y - thick, 1), br.style)
	return Vector3i(-1, -1, -1)


## True when a point is on or within `margin` blocks of a bridge (props keep off them).
func near_bridge(p: Vector2, margin: float) -> bool:
	if bridges.is_empty():
		return false
	var m := int(ceil(margin)) + 1
	for dz in range(-m, m + 1, 2):
		for dx in range(-m, m + 1, 2):
			var q := Vector2(p.x + dx, p.y + dz)
			if _island_column(int(q.x), int(q.y)) != EMPTY:
				continue
			if _bridge_at(int(q.x), int(q.y), Vector2(int(q.x) + 0.5, int(q.y) + 0.5)).x >= 0:
				return true
	return false


## Near a bridge end the island ground is levelled to the deck height, so the bridge never ends against a ledge.
func _landing_pad(p: Vector2, c: Vector2i) -> Vector2i:
	# Only the nearest bridge end shapes the ground, so two bridges landing close together do not fight.
	var best_d := 14.0
	var best_h := -1
	for br in bridges:
		for end in 2:
			var e: Vector2 = br.a if end == 0 else br.b
			var d := p.distance_to(e)
			if d < best_d:
				best_d = d
				best_h = br.ha if end == 0 else br.hb
	if best_h < 0:
		return c
	var w := 1.0 - smoothstep(5.0, 14.0, best_d)
	var top := clampi(roundi(lerpf(c.x, best_h, w)), 4, _max_y)
	return Vector2i(top, clampi(c.y + top - c.x, 1, top))


func _island_column(wx: int, wz: int) -> Vector2i:
	var best: Island = null
	var best_m := 0.0
	var p := Vector2(wx, wz)
	var n := _shape.get_noise_2d(wx, wz)
	for isl in islands:
		var d := p.distance_to(isl.center) / isl.radius
		d *= 1.0 + n * isl.shape_amp
		var m := 1.0 - d
		if m > best_m:
			best_m = m
			best = isl
	if best == null:
		return EMPTY
	var rim := minf(1.0, best_m * 4.0)
	# Flat build area in the middle of each island, fading into the wild terrain.
	var flat := 1.0 - smoothstep(preset.flat_share, preset.flat_share + 0.25, 1.0 - best_m)
	flat *= 1.0 if best == islands[0] else 0.45
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
	# Only a sparse few of them, none on the flat build area: the ramp pieces do the smoothing work.
	var bump_noise := _detail.get_noise_2d(wx, wz)
	var bumps := 0.0
	if flat < 0.5 and absf(bump_noise) > 0.38:
		bumps = signf(bump_noise) * rim
	var top := best.base_top + lerpf(level, rel, slope) + bumps
	var depth := 3.0 + best.thickness * pow(best_m, 0.75) + _under.get_noise_2d(wx, wz) * 4.0 * best_m
	var top_i := clampi(int(top), 4, _max_y)
	var bottom_i := clampi(top_i - int(depth), 1, top_i)
	return Vector2i(top_i, bottom_i)


func block_at(wx: int, wy: int, wz: int, top: int, bottom: int, style := -1) -> int:
	if wy > top or wy < bottom:
		return Blocks.AIR
	if style == 1 and wy > bottom:
		return Blocks.STONE   # bare stone arch bridge
	var depth := top - wy
	if depth == 0:
		if wy >= snow_y:
			return Blocks.SNOW
		return Blocks.STONE if wy >= rock_y else preset.top_block
	# One layer of dirt under the grass, a second one in patches.
	if depth <= preset.dirt_depth or (depth == preset.dirt_depth + 1 and _dirt_extra.get_noise_2d(wx, wz) > preset.dirt_extra_threshold):
		if wy >= rock_y:
			return Blocks.STONE
		# Grey stone pockets inside the dirt layer, carrying a few ore flecks, as on the original's cliff faces.
		if _pocket.get_noise_3d(wx, wy * 1.4, wz) > 0.58:
			if _orange.get_noise_3d(wx, wy, wz) > 0.45:
				return Blocks.ORANGE_ORE
			if _iron.get_noise_3d(wx, wy, wz) > 0.5:
				return Blocks.IRON
			return Blocks.STONE
		return preset.sub_block
	if wy > bottom + 3 and depth > cave_depth and _cave.get_noise_3d(wx, wy * 1.6, wz) > 0.55:
		return Blocks.AIR
	if depth > 2 and _orange.get_noise_3d(wx, wy, wz) > 0.76:
		return Blocks.ORANGE_ORE
	if _coal.get_noise_3d(wx, wy, wz) > 0.62:
		return Blocks.COAL
	if depth > 4 and _iron.get_noise_3d(wx, wy, wz) > 0.70:
		return Blocks.IRON
	return Blocks.STONE


## Shape id of the slope piece for the cell right above a column's top, or -1 for none (see Ramps for the rules).
func skin_shape_at(wx: int, wz: int, top: int) -> int:
	var around := {}
	for off in Ramps.NEIGHBOURS:
		around[off] = Ramps.level_of_top(column(wx + off.x, wz + off.y).x)
	return Ramps.skin_shape(Ramps.level_of_top(top), around)


## Heights of the 18 x 18 columns around chunk column (cx, cz): 16 inside plus a 1-column border for ramp neighbours.
## Index (x + 1) + (z + 1) * 18. Cached, because every vertical chunk of the column needs the same numbers.
func region(cx: int, cz: int) -> Array:
	var key := Vector2i(cx, cz)
	_region_mutex.lock()
	var cached: Variant = _region_cache.get(key)
	_region_mutex.unlock()
	if cached != null:
		return cached
	# Raw heights for 20 x 20 columns (2 around the chunk), then despeckled for the inner 18 x 18.
	var raw_top := PackedInt32Array()
	var raw_bottom := PackedInt32Array()
	var raw_style := PackedInt32Array()
	raw_top.resize(400)
	raw_bottom.resize(400)
	raw_style.resize(400)
	for z in range(-2, 18):
		for x in range(-2, 18):
			var col := raw_column(cx * 16 + x, cz * 16 + z)
			var i := (x + 2) + (z + 2) * 20
			raw_top[i] = col.x
			raw_bottom[i] = col.y
			raw_style[i] = col.z
	var tops := PackedInt32Array()
	var bottoms := PackedInt32Array()
	var styles := PackedInt32Array()
	tops.resize(18 * 18)
	bottoms.resize(18 * 18)
	styles.resize(18 * 18)
	for z in range(-1, 17):
		for x in range(-1, 17):
			var i := (x + 2) + (z + 2) * 20
			var top := raw_top[i]
			if raw_style[i] == -1 and top >= 0:
				top = Ramps.despeckle(top, raw_top[i + 1], raw_top[i - 1], raw_top[i + 20], raw_top[i - 20])
			var j := (x + 1) + (z + 1) * 18
			tops[j] = top
			bottoms[j] = raw_bottom[i]
			styles[j] = raw_style[i]
	var res := [tops, bottoms, styles]
	_region_mutex.lock()
	_region_cache[key] = res
	_region_mutex.unlock()
	return res


## Returns an empty array when the chunk is entirely open sky (nothing stored, nothing meshed).
func generate_chunk(cpos: Vector3i) -> PackedInt32Array:
	var cs := Blocks.CHUNK_SIZE
	var ox := cpos.x * cs
	var oy := cpos.y * cs
	var oz := cpos.z * cs
	var reg := region(cpos.x, cpos.z)
	var tops: PackedInt32Array = reg[0]
	var bottoms: PackedInt32Array = reg[1]
	var styles: PackedInt32Array = reg[2]
	var any := false
	for z in cs:
		for x in cs:
			var i := (x + 1) + (z + 1) * 18
			if tops[i] >= 0 and tops[i] + 1 >= oy and bottoms[i] <= oy + cs - 1:
				any = true
				break
		if any:
			break
	if not any:
		return PackedInt32Array()
	var data := PackedInt32Array()
	data.resize(Blocks.CHUNK_VOLUME)
	for z in cs:
		for x in cs:
			var i := (x + 1) + (z + 1) * 18
			var top := tops[i]
			if top < 0:
				continue
			var bottom := bottoms[i]
			for y in cs:
				data[x + (z << 4) + (y << 8)] = block_at(ox + x, oy + y, oz + z, top, bottom, styles[i])
			var skin_y := top + 1 - oy
			if skin_y >= 0 and skin_y < cs and top + 1 <= _max_y:
				var around := {}
				for off in Ramps.NEIGHBOURS:
					around[off] = Ramps.level_of_top(tops[(x + 1 + off.x) + (z + 1 + off.y) * 18])
				var shape := Ramps.skin_shape(Ramps.level_of_top(top), around)
				if shape >= 0:
					data[x + (z << 4) + (skin_y << 8)] = Blocks.make(block_at(ox + x, top, oz + z, top, bottom, styles[i]), shape)
	return data
