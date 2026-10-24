extends SceneTree
## Headless: godot --headless --path . -s res://scripts/tools/island_seeds_test.gd
## Many seeds, 0-4 extra islands each: counts, bounds, and every bridge deck walkable end to end.

var _failed := false


func _check(cond: bool, what: String) -> void:
	if not cond:
		print("FAIL " + what)
		_failed = true


func _init() -> void:
	var size := Vector3i(448, 112, 448)
	var counts := {}
	var lengths: Array[int] = []
	for seed_value in range(1, 41):
		for forced in [-1, 0, 4]:
			var gen := WorldGen.new(seed_value, size, MapPreset.plains(), forced)
			var n := gen.islands.size()
			counts[n - 1] = int(counts.get(n - 1, 0)) + 1
			_check(n >= 1 and n <= 5, "seed %d forced %d: %d islands" % [seed_value, forced, n])
			if forced == 0:
				_check(n == 1 and gen.bridges.is_empty(), "seed %d: zero extras means a single island" % seed_value)
			if forced == 4:
				_check(n >= 3, "seed %d: forced 4 extras placed only %d" % [seed_value, n - 1])
			_check(gen.bridges.size() <= n - 1, "seed %d: at most one bridge per extra island" % seed_value)
			for isl in gen.islands:
				_check(isl.center.x - isl.radius > 0 and isl.center.y - isl.radius > 0 and isl.center.x + isl.radius < size.x and isl.center.y + isl.radius < size.z, "seed %d: island inside the map" % seed_value)
			for br in gen.bridges:
				var steps := int(br.length() * 1.25) + 1
				lengths.append(int(br.length()))
				var prev := -1
				for i in steps + 1:
					var p: Vector2 = br.centre(float(i) / steps)
					var col := gen.column(int(p.x), int(p.y))
					if col == WorldGen.EMPTY:
						_check(false, "seed %d: hole in a bridge deck at step %d/%d" % [seed_value, i, steps])
						break
					if prev >= 0 and (col.x - prev > 1 or prev - col.x > 2):
						_check(false, "seed %d: bridge step too steep (%d -> %d)" % [seed_value, prev, col.x])
						break
					prev = col.x
	lengths.sort()
	print("extra-island counts over all runs: %s" % str(counts))
	print("bridge lengths: min %d, median %d, max %d" % [lengths[0], lengths[lengths.size() / 2], lengths[-1]])
	print("FAILED" if _failed else "all good")
	quit(1 if _failed else 0)
