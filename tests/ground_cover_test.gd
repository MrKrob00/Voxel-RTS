extends SceneTree
## Headless: godot --headless --path . -s res://tests/ground_cover_test.gd
## The bare-earth layer: brushes, cliff pass, the slices the mesher reads, and how they blend.

var _failed := false


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _init() -> void:
	_brushes()
	_cliffs()
	_slices()
	quit(1 if _failed else 0)


func _brushes() -> void:
	var cover := GroundCover.new(64, 64)
	cover.stamp_disc(Vector2(32, 32), 1.0, 3.0, 1.0)
	_check(cover.get_bare(32, 32) == 255, "disc: bare in the middle")
	var prev := 255
	var monotone := true
	for dx in range(0, 5):
		var v := cover.get_bare(32 + dx, 32)
		monotone = monotone and v <= prev
		prev = v
	_check(monotone, "disc: fades out steadily with distance")
	_check(cover.get_bare(32 + 5, 32) == 0, "disc: nothing beyond the outer radius")
	var before := cover.get_bare(33, 32)
	cover.stamp_disc(Vector2(32, 32), 0.2, 0.6, 0.3)
	_check(cover.get_bare(33, 32) == before, "a weaker brush never makes the ground greener")
	cover.stamp_rect(Rect2(10, 10, 2, 1), 1.5)
	_check(cover.get_bare(10, 10) == 255 and cover.get_bare(11, 10) == 255, "rect: bare under the footprint")
	_check(cover.get_bare(9, 10) > 0 and cover.get_bare(9, 10) < 255, "rect: soft margin around it")
	cover.stamp_disc(Vector2(-5, -5), 1.0, 3.0)   # off the map: must not crash or wrap
	_check(cover.get_bare(0, 0) == 0, "stamps off the map are ignored")


func _cliffs() -> void:
	# A plateau at height 10 on the left, 4 on the right, a straight drop between them; the right edge ends at air.
	var w := 40
	var tops := PackedInt32Array()
	tops.resize(w * w)
	for z in w:
		for x in w:
			tops[x + z * w] = 10 if x < 20 else (4 if x < 36 else -1)
	var cover := GroundCover.new(w, w)
	cover.paint_cliffs(tops)
	_check(cover.get_bare(19, 20) > 100, "lip of the drop is bare")
	_check(cover.get_bare(20, 20) > 60, "foot of the drop is bare too")
	_check(cover.get_bare(5, 20) == 0, "flat ground far from edges keeps its grass")
	_check(cover.get_bare(28, 20) == 0, "flat ground at the foot, away from the wall, keeps its grass")
	_check(cover.get_bare(35, 20) > 100, "an island edge counts as a drop")
	var smooth := true
	for x in range(10, 19):
		smooth = smooth and cover.get_bare(x, 20) <= cover.get_bare(x + 1, 20)
	_check(smooth, "earth fades into the grass towards the lip, no hard edge")


func _slices() -> void:
	var cover := GroundCover.new(64, 64)
	cover.stamp_disc(Vector2(16.0, 16.0), 2.0, 4.0)
	var slice := cover.slice(16, 16, 16)
	_check(slice.size() == 18 * 18, "slice has one border column on every side")
	_check(slice[1 + 1 * 18] == cover.get_bare(16, 16), "slice index (1, 1) is the chunk's first column")
	_check(slice[0] == cover.get_bare(15, 15), "slice index (0, 0) is the border column")
	# Vertex on a block corner = average of the four columns around it, so neighbouring chunks agree on shared edges.
	var a := GroundCover.sample_slice(cover.slice(0, 0, 16), 16, 16.0, 8.0)
	var b := GroundCover.sample_slice(cover.slice(16, 0, 16), 16, 0.0, 8.0)
	_check(is_equal_approx(a, b), "the same vertex seen from two chunks has the same value")
	var v := GroundCover.sample_slice(slice, 16, 0.0, 0.0)
	var expect := (cover.get_bare(15, 15) + cover.get_bare(16, 15) + cover.get_bare(15, 16) + cover.get_bare(16, 16)) / 4.0 / 255.0
	_check(is_equal_approx(v, expect), "corner vertex = mean of the four columns around it")
	_check(GroundCover.sample_slice(PackedByteArray(), 16, 3.0, 3.0) == 0.0, "no slice = all grass")
