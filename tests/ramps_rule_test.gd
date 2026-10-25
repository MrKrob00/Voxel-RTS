extends SceneTree
## Headless: godot --headless --path . -s res://tests/ramps_rule_test.gd
## The slope rule against every combination of neighbours (none / half / whole), its symmetry, and random height fields.

var _failed := false


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _init() -> void:
	_exhaustive()
	_random_fields()
	quit(1 if _failed else 0)


## All 3^8 = 6561 neighbourhoods: every neighbour contributes 0, 1 (half) or 2 (whole).
func _exhaustive() -> void:
	var offs := Ramps.NEIGHBOURS
	var categories := {"whole only": {}, "half only": {}, "mixed whole + half": {}}
	var counts := {"whole only": 0, "half only": 0, "mixed whole + half": 0, "none": 0}
	var valid := true
	var corner_ok := true
	var rot_ok := true
	var mirror_ok := true
	var all_shapes := {}
	for code in 6561:
		var rise := {}
		var c := code
		var has1 := false
		var has2 := false
		for off in offs:
			var r := c % 3
			c /= 3
			rise[off] = r
			has1 = has1 or r == 1
			has2 = has2 or r == 2
		var shape := Ramps.shape_from_rises(rise)
		if shape < 0:
			counts["none"] += 1
			continue
		var h := Blocks.corner_heights(shape)
		for k in 4:
			if h[k] < 0 or h[k] > 2:
				valid = false
		if Blocks.shape_from_corners(h[0], h[1], h[2], h[3]) != shape:
			valid = false
		# Each corner is the highest of the three cells that touch it.
		var expect := [
			maxi(maxi(rise[Vector2i(-1, 0)], rise[Vector2i(0, -1)]), rise[Vector2i(-1, -1)]),
			maxi(maxi(rise[Vector2i(1, 0)], rise[Vector2i(0, -1)]), rise[Vector2i(1, -1)]),
			maxi(maxi(rise[Vector2i(1, 0)], rise[Vector2i(0, 1)]), rise[Vector2i(1, 1)]),
			maxi(maxi(rise[Vector2i(-1, 0)], rise[Vector2i(0, 1)]), rise[Vector2i(-1, 1)]),
		]
		for k in 4:
			if h[k] != expect[k]:
				corner_ok = false
		var cat := "whole only" if (has2 and not has1) else ("half only" if (has1 and not has2) else "mixed whole + half")
		counts[cat] += 1
		categories[cat][shape] = true
		all_shapes[shape] = true
		# Rotating the neighbourhood a quarter turn rotates the piece (corner order 0,1,2,3 is a rotation too).
		var rotated := {}
		for off in offs:
			rotated[Vector2i(-off.y, off.x)] = rise[off]
		var rshape := Ramps.shape_from_rises(rotated)
		var rh := Blocks.corner_heights(rshape) if rshape >= 0 else [0, 0, 0, 0]
		if rh != [h[3], h[0], h[1], h[2]] and rh != [h[1], h[2], h[3], h[0]]:
			rot_ok = false
		# Mirroring x mirrors the piece.
		var mirrored := {}
		for off in offs:
			mirrored[Vector2i(-off.x, off.y)] = rise[off]
		var mshape := Ramps.shape_from_rises(mirrored)
		var mh := Blocks.corner_heights(mshape) if mshape >= 0 else [0, 0, 0, 0]
		if mh != [h[1], h[0], h[3], h[2]]:
			mirror_ok = false
	print("combinations: %s" % str(counts))
	for cat in categories:
		print("  %s -> %d different shapes" % [cat, categories[cat].size()])
	print("  all together -> %d different shapes" % all_shapes.size())
	_check(valid, "every result is a valid shape (corner heights 0-2, round trip)")
	_check(corner_ok, "every corner is the highest of the three cells that touch it")
	_check(rot_ok, "a quarter turn of the neighbours turns the piece (no orientation bias)")
	_check(mirror_ok, "mirroring the neighbours mirrors the piece")
	_check(categories["whole only"].size() > 0 and categories["half only"].size() > 0 and categories["mixed whole + half"].size() > 0, "whole-only, half-only and mixed neighbourhoods all produce pieces")


## Random height fields (levels in half-blocks, odd levels are half-dug blocks): neighbouring slope pieces in the same
## layer meet at equal heights, and a piece never rises above what its neighbours ask for.
func _random_fields() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var size := 9
	var pieces := 0
	var seams := 0
	var over := 0
	for field_index in 4000:
		var level := []
		for i in size * size:
			level.append(rng.randi_range(4, 9))
		var shape_at := {}
		for z in range(1, size - 1):
			for x in range(1, size - 1):
				var lv: int = level[x + z * size]
				if lv % 2 == 1:
					continue   # half-dug top: no slope piece
				var around := {}
				for off in Ramps.NEIGHBOURS:
					around[off] = level[(x + off.x) + (z + off.y) * size]
				var shape := Ramps.skin_shape(lv, around)
				if shape >= 0:
					shape_at[Vector2i(x, z)] = shape
					pieces += 1
					var h := Blocks.corner_heights(shape)
					for k in 4:
						if h[k] > Ramps.MAX_RISE:
							over += 1
		# Neighbouring pieces in the same layer (equal level): shared edge heights must agree.
		for cell in shape_at:
			var right: Vector2i = cell + Vector2i(1, 0)
			if shape_at.has(right) and level[cell.x + cell.y * size] == level[right.x + right.y * size]:
				var a := Blocks.corner_heights(shape_at[cell])
				var b := Blocks.corner_heights(shape_at[right])
				if a[1] != b[0] or a[2] != b[3]:
					seams += 1
			var below: Vector2i = cell + Vector2i(0, 1)
			if shape_at.has(below) and level[cell.x + cell.y * size] == level[below.x + below.y * size]:
				var a2 := Blocks.corner_heights(shape_at[cell])
				var b2 := Blocks.corner_heights(shape_at[below])
				if a2[3] != b2[0] or a2[2] != b2[1]:
					seams += 1
	print("random fields: %d slope pieces, %d seams" % [pieces, seams])
	_check(seams == 0, "random fields with whole, half and missing blocks: neighbouring pieces meet at equal heights")
	_check(over == 0, "no piece is taller than one block")
