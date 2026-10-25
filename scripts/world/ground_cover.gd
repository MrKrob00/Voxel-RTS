class_name GroundCover
extends RefCounted
## How much of each column's grass is gone, 0 (full turf) to 255 (bare earth). Grass is a surface cover, not a block
## material: it thins out under trees, boulders, ore and buildings and along cliff edges, and does not grow back.
##
## The mesher samples this per vertex (bilinear), so the turf fades into the earth with no hard tile edge; one soft
## brush (a disc with a falloff) is every transition tile the ground needs. Pure data, no scene access.

const SLICE_BORDER := 1   ## a chunk's slice has this many extra columns on every side, enough to blend its edge vertices

var width: int
var depth: int
var bare := PackedByteArray()


func _init(size_x: int, size_z: int) -> void:
	width = size_x
	depth = size_z
	bare.resize(size_x * size_z)
	bare.fill(0)


func get_bare(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= width or z >= depth:
		return 0
	return bare[x + z * width]


## Clears the grass in a disc: full inside `inner`, fading to nothing at `outer`. Never makes ground greener.
## Returns the rect of columns that may have changed.
func stamp_disc(center: Vector2, inner: float, outer: float, strength := 1.0) -> Rect2i:
	var x0 := maxi(0, floori(center.x - outer))
	var x1 := mini(width - 1, ceili(center.x + outer))
	var z0 := maxi(0, floori(center.y - outer))
	var z1 := mini(depth - 1, ceili(center.y + outer))
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var d := Vector2(x + 0.5, z + 0.5).distance_to(center)
			var w := strength * (1.0 - smoothstep(inner, outer, d))
			_raise(x, z, w)
	return Rect2i(x0, z0, x1 - x0 + 1, z1 - z0 + 1)


## Clears the grass under a rectangle (world units) and a margin around it that fades out. For buildings.
func stamp_rect(rect: Rect2, margin: float, strength := 1.0) -> Rect2i:
	var x0 := maxi(0, floori(rect.position.x - margin))
	var x1 := mini(width - 1, ceili(rect.end.x + margin))
	var z0 := maxi(0, floori(rect.position.y - margin))
	var z1 := mini(depth - 1, ceili(rect.end.y + margin))
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var p := Vector2(x + 0.5, z + 0.5)
			var dx := maxf(maxf(rect.position.x - p.x, p.x - rect.end.x), 0.0)
			var dz := maxf(maxf(rect.position.y - p.y, p.y - rect.end.y), 0.0)
			var d := sqrt(dx * dx + dz * dz)
			_raise(x, z, strength * (1.0 - smoothstep(0.0, margin, d)))
	return Rect2i(x0, z0, x1 - x0 + 1, z1 - z0 + 1)


func _raise(x: int, z: int, w: float) -> void:
	if w <= 0.0:
		return
	var v := int(round(clampf(w, 0.0, 1.0) * 255.0))
	var i := x + z * width
	if v > bare[i]:
		bare[i] = v


## Thin turf on the lip of a drop and at the foot of a wall: where the ground steps 2 or more blocks, or ends at the
## island edge. `tops[x + z * width]` is the y of the top block of each column, -1 for none. Then blurred, so the earth
## fades into the grass over a few blocks.
func paint_cliffs(tops: PackedInt32Array, min_drop := 2) -> void:
	var raw := PackedByteArray()
	raw.resize(width * depth)
	raw.fill(0)
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for z in depth:
		for x in width:
			var t := tops[x + z * width]
			if t < 0:
				continue
			var lip := 0
			var foot := 0
			for d in dirs:
				var nx: int = x + d.x
				var nz: int = z + d.y
				var n := -1
				if nx >= 0 and nz >= 0 and nx < width and nz < depth:
					n = tops[nx + nz * width]
				var diff := t - n if n >= 0 else min_drop + 1   # beyond the island is a drop
				lip = maxi(lip, diff)
				if n >= 0:
					foot = maxi(foot, n - t)
			var v := 0
			if lip >= min_drop:
				v = 230
			if foot >= min_drop:
				v = maxi(v, 150)
			raw[x + z * width] = v
	for pass_index in 2:
		raw = _blur(raw)
	for i in raw.size():
		if raw[i] > bare[i]:
			bare[i] = raw[i]


func _blur(src: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(src.size())
	out.fill(0)
	for z in range(1, depth - 1):
		for x in range(1, width - 1):
			var i := x + z * width
			var s := src[i - width - 1] + src[i - width] + src[i - width + 1] + src[i - 1] + src[i] + src[i + 1] + src[i + width - 1] + src[i + width] + src[i + width + 1]
			out[i] = mini(255, int(round(s / 7.0)))   # a little over the mean so the peak does not wash out
	return out


## The columns of one chunk plus a border, as a copy the mesher thread may read: (size + 2 * border)^2 bytes, row by row.
func slice(origin_x: int, origin_z: int, size: int) -> PackedByteArray:
	var n := size + 2 * SLICE_BORDER
	var out := PackedByteArray()
	out.resize(n * n)
	for j in n:
		var z := origin_z - SLICE_BORDER + j
		for i in n:
			out[i + j * n] = get_bare(origin_x - SLICE_BORDER + i, z)
	return out


## Bilinear sample of a slice at a position given relative to the slice's chunk origin (in blocks). Columns count at their
## centres, so a vertex on a block corner averages the four columns around it. Returns 0..1.
static func sample_slice(cover: PackedByteArray, size: int, lx: float, lz: float) -> float:
	if cover.is_empty():
		return 0.0
	var n := size + 2 * SLICE_BORDER
	var fx := lx + SLICE_BORDER - 0.5
	var fz := lz + SLICE_BORDER - 0.5
	var i0 := clampi(floori(fx), 0, n - 2)
	var j0 := clampi(floori(fz), 0, n - 2)
	var tx := clampf(fx - i0, 0.0, 1.0)
	var tz := clampf(fz - j0, 0.0, 1.0)
	var a := lerpf(cover[i0 + j0 * n], cover[i0 + 1 + j0 * n], tx)
	var b := lerpf(cover[i0 + (j0 + 1) * n], cover[i0 + 1 + (j0 + 1) * n], tx)
	return lerpf(a, b, tz) / 255.0
