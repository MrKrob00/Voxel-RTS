extends SceneTree
## Headless: godot --headless --path . -s res://tests/ramps_rule_test.gd
## The slope / dug-block rule against every combination of neighbours (none / half dug / whole), its symmetry, and random
## height fields.

var _failed := false


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _init() -> void:
	for base in [0, Blocks.DUG_HEIGHT]:
		_exhaustive(base)
	_random_fields()
	quit(1 if _failed else 0)


## All 3^8 = 6561 neighbourhoods: every neighbour contributes 0 (nothing), DUG_HEIGHT (a half-dug block) or UNIT (a whole one).
## `base` 0 is a slope piece, DUG_HEIGHT a half-dug block.
func _exhaustive(base: int) -> void:
	var label := "slope piece" if base == 0 else "half-dug block"
	var values := [0, Blocks.DUG_HEIGHT, Blocks.UNIT]
	var offs := Ramps.NEIGHBOURS
	var counts := {"whole only": 0, "half only": 0, "mixed whole + half": 0, "none": 0}
	var shapes := {"whole only": {}, "half only": {}, "mixed whole + half": {}}
	var all_shapes := {}
	var valid := true
	var corner_ok := true
	var rot_ok := true
	var mirror_ok := true
	for code in 6561:
		var rise := {}
		var c := code
		var has_half := false
		var has_whole := false
		for off in offs:
			var v: int = values[c % 3]
			c /= 3
			rise[off] = v
			has_half = has_half or v == Blocks.DUG_HEIGHT
			has_whole = has_whole or v == Blocks.UNIT
		var shape := Ramps.shape_from_rises(rise, base)
		if shape < 0:
			counts["none"] += 1
			continue
		var h := Blocks.corner_heights(shape)
		for k in 4:
			if h[k] < base or h[k] > Blocks.UNIT:
				valid = false
		if Blocks.shape_from_corners(h[0], h[1], h[2], h[3], base > 0) != shape:
			valid = false
		# Each corner is the highest of the base and the three cells that touch it.
		var expect := [
			maxi(base, maxi(maxi(rise[Vector2i(-1, 0)], rise[Vector2i(0, -1)]), rise[Vector2i(-1, -1)])),
			maxi(base, maxi(maxi(rise[Vector2i(1, 0)], rise[Vector2i(0, -1)]), rise[Vector2i(1, -1)])),
			maxi(base, maxi(maxi(rise[Vector2i(1, 0)], rise[Vector2i(0, 1)]), rise[Vector2i(1, 1)])),
			maxi(base, maxi(maxi(rise[Vector2i(-1, 0)], rise[Vector2i(0, 1)]), rise[Vector2i(-1, 1)])),
		]
		for k in 4:
			if h[k] != expect[k]:
				corner_ok = false
		var cat := "whole only" if (has_whole and not has_half) else ("half only" if (has_half and not has_whole) else "mixed whole + half")
		counts[cat] += 1
		shapes[cat][shape] = true
		all_shapes[shape] = true
		# A quarter turn of the neighbours turns the piece (corner order is a rotation too).
		var rotated := {}
		for off in offs:
			rotated[Vector2i(-off.y, off.x)] = rise[off]
		var rshape := Ramps.shape_from_rises(rotated, base)
		var rh := Blocks.corner_heights(rshape) if rshape >= 0 else [0, 0, 0, 0]
		if rh != [h[3], h[0], h[1], h[2]] and rh != [h[1], h[2], h[3], h[0]]:
			rot_ok = false
		var mirrored := {}
		for off in offs:
			mirrored[Vector2i(-off.x, off.y)] = rise[off]
		var mshape := Ramps.shape_from_rises(mirrored, base)
		var mh := Blocks.corner_heights(mshape) if mshape >= 0 else [0, 0, 0, 0]
		if mh != [h[1], h[0], h[3], h[2]]:
			mirror_ok = false
	print("%s: combinations %s" % [label, str(counts)])
	for cat in shapes:
		print("  %s -> %d different shapes" % [cat, shapes[cat].size()])
	print("  all together -> %d different shapes" % all_shapes.size())
	_check(valid, "%s: every result is a valid shape (corners between base and a full block, round trip)" % label)
	_check(corner_ok, "%s: every corner is the highest of the base and the three cells that touch it" % label)
	_check(rot_ok, "%s: a quarter turn of the neighbours turns the piece (no orientation bias)" % label)
	_check(mirror_ok, "%s: mirroring the neighbours mirrors the piece" % label)
	_check(all_shapes.size() > 0 and shapes["whole only"].size() > 0 and shapes["mixed whole + half"].size() > 0, "%s: whole-only and mixed neighbourhoods produce pieces" % label)
	if base > 0:
		_check(all_shapes.has(Blocks.SHAPE_BOWL) and all_shapes.has(Blocks.SHAPE_DUG), "half-dug block: both the flat pit floor and the bowl in the middle of whole blocks occur")


## Random height fields (levels in quarter-blocks: whole tops are multiples of UNIT, half-dug tops are 3 above that):
## neighbouring pieces in the same layer meet at equal heights, and no piece stands taller than a block.
func _random_fields() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var size := 9
	var tops := [16, 19, 20, 23, 24, 27, 28, 31, 32]   # whole, dug, whole, dug...
	var pieces := 0
	var seams := 0
	var over := 0
	for field_index in 4000:
		var level := []
		for i in size * size:
			level.append(tops[rng.randi_range(0, tops.size() - 1)])
		var piece := {}   # Vector2i -> [shape, cell base]
		for z in range(1, size - 1):
			for x in range(1, size - 1):
				var lv: int = level[x + z * size]
				var around := {}
				for off in Ramps.NEIGHBOURS:
					around[off] = level[(x + off.x) + (z + off.y) * size]
				var shape: int
				var cell_base: int
				if lv % Blocks.UNIT == 0:
					shape = Ramps.skin_shape(lv, around)
					cell_base = lv
				else:
					shape = Ramps.dug_shape(lv, around)
					cell_base = lv - Blocks.DUG_HEIGHT
				if shape >= 0:
					piece[Vector2i(x, z)] = [shape, cell_base]
					pieces += 1
					for hv in Blocks.corner_heights(shape):
						if hv > Blocks.UNIT:
							over += 1
		for cell in piece:
			var right: Vector2i = cell + Vector2i(1, 0)
			if piece.has(right) and piece[cell][1] == piece[right][1]:
				var a := Blocks.corner_heights(piece[cell][0])
				var b := Blocks.corner_heights(piece[right][0])
				if a[1] != b[0] or a[2] != b[3]:
					seams += 1
			var below: Vector2i = cell + Vector2i(0, 1)
			if piece.has(below) and piece[cell][1] == piece[below][1]:
				var a2 := Blocks.corner_heights(piece[cell][0])
				var b2 := Blocks.corner_heights(piece[below][0])
				if a2[3] != b2[0] or a2[2] != b2[1]:
					seams += 1
	print("random fields: %d pieces, %d seams" % [pieces, seams])
	_check(seams == 0, "random fields with whole, half-dug and missing blocks: neighbouring pieces meet at equal heights")
	_check(over == 0, "no piece is taller than one block")
