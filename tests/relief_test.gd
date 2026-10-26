extends SceneTree
## Headless: godot --headless --path . -s res://tests/relief_test.gd
## ReliefShadow.shade_map on a tiny height map: a wall throws a shadow on the ground away from the sun and none towards it.

func _init() -> void:
	var failed := 0
	var w := 24
	var d := 24
	var h := PackedInt32Array()
	h.resize(w * d)
	h.fill(10)
	for x in w:
		h[x + 12 * w] = 14   # a wall four blocks high along x at z = 12
	# the sun lies towards +z, 45 degrees up
	var shade := ReliefShadow.shade_map(h, w, d, Vector3(0.0, 1.0, 1.0).normalized())
	failed += _check(shade[8 + 11 * w] > 200, "the ground just behind the wall (away from the sun) is in the shade (%d)" % shade[8 + 11 * w])
	failed += _check(shade[8 + 9 * w] > 0 and shade[8 + 9 * w] < 255 or shade[8 + 9 * w] == 255, "the shade reaches three blocks behind it (%d)" % shade[8 + 9 * w])
	failed += _check(shade[8 + 5 * w] == 0, "six blocks behind it the ground is lit again (%d)" % shade[8 + 5 * w])
	failed += _check(shade[8 + 14 * w] == 0 and shade[8 + 20 * w] == 0, "the ground on the sun's side is lit")
	# the sun low on the horizon: the shade is longer
	var low := ReliefShadow.shade_map(h, w, d, Vector3(0.0, 0.3, 1.0).normalized())
	failed += _check(low[8 + 3 * w] > 0, "with the sun low the shade reaches further (%d)" % low[8 + 3 * w])
	# the sun at an angle across x: the shade leans sideways
	var side := ReliefShadow.shade_map(h, w, d, Vector3(1.0, 1.0, 1.0).normalized())
	failed += _check(side[8 + 11 * w] > 200 and side[6 + 9 * w] > 0, "from a side the shade is cast the other way (%d, %d)" % [side[8 + 11 * w], side[6 + 9 * w]])
	print("RELIEF DONE: %d failed" % failed)
	quit(1 if failed > 0 else 0)


func _check(cond: bool, what: String) -> int:
	print(("ok   " if cond else "FAIL ") + what)
	return 0 if cond else 1
