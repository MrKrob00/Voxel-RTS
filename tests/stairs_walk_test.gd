extends SceneTree
## Headless: godot --headless --path . -s res://tests/stairs_walk_test.gd
## A tiny flat platform with stair blocks at two heights and facing different ways: a unit stands IN a flight of steps, climbs it,
## and cannot stand on top of it. No generated map.

var _failed := false


class Platform extends VoxelWorld:
	func size_blocks() -> Vector3i:
		return Vector3i(16, 8, 16)

	func get_block(p: Vector3i) -> int:
		return Blocks.make(Blocks.STONE) if (p.y == 0 and in_bounds(p)) else Blocks.AIR

	func stamp_cover_rect(_rect: Rect2, _margin: float, _strength := 1.0) -> void:
		pass


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _initialize() -> void:
	var world := Platform.new()
	var bricks := BrickWorld.new()
	root.add_child(bricks)
	await process_frame
	bricks.world = world
	var nav := Navigation.new(world, bricks)
	var kind := BrickWorld.Kind.STONE

	# Two stair blocks one above the other, rising towards +x: the flight at (3,1,2), its cube at (4,1,2); on that cube the next flight
	# at (4,2,2) and its cube at (5,2,2).
	_check(bricks.place(Vector3i(3, 1, 2), 0, kind, 2, "stairs", 0) != null, "lower stair block placed")
	_check(bricks.place(Vector3i(4, 2, 2), 0, kind, 2, "stairs", 0) != null, "upper stair block placed on the lower cube")
	_check(not bricks.steps_at(Vector3i(3, 1, 2)).is_empty() and bricks.steps_at(Vector3i(4, 1, 2)).is_empty(), "the flight is the low cell, the cube is not")

	_check(nav.standable(Vector3i(3, 1, 2)), "a unit can stand in a flight of steps")
	_check(not nav.standable(Vector3i(3, 2, 2)), "but not on top of it")
	_check(not nav.standable(Vector3i(4, 1, 2)), "nor in the cube beside it")
	_check(nav.standable(Vector3i(4, 2, 2)), "the second flight, on the first cube, can be stood in")
	_check(nav.standable(Vector3i(5, 3, 2)), "the top of the second cube can be stood on")

	var h1 := nav.feet_height(Vector3i(3, 1, 2), 3.1, 2.5)
	var h2 := nav.feet_height(Vector3i(3, 1, 2), 3.5, 2.5)
	var h3 := nav.feet_height(Vector3i(3, 1, 2), 3.9, 2.5)
	_check(is_equal_approx(h1, 1.0 + 1.0 / 3.0) and is_equal_approx(h2, 1.0 + 2.0 / 3.0) and is_equal_approx(h3, 2.0), "the feet rise by a third of a block at each step")

	var up := nav.find_path(Vector3i(1, 1, 2), Vector3i(5, 3, 2))
	_check(nav.last_reached and up.size() >= 2, "a path leads from the ground to the top of the upper cube")
	_check(up.has(Vector3i(3, 1, 2)) and up.has(Vector3i(4, 2, 2)), "it goes through both flights")
	var down := nav.find_path(Vector3i(5, 3, 2), Vector3i(1, 1, 2))
	_check(nav.last_reached and down.has(Vector3i(3, 1, 2)), "and back down the same way")

	# Facing -x: the flight is the cell at the larger x, the cube at the smaller one.
	_check(bricks.place(Vector3i(8, 1, 6), 0, kind, 2, "stairs", 2) != null, "stair block facing -x placed")
	_check(not bricks.steps_at(Vector3i(9, 1, 6)).is_empty() and bricks.steps_at(Vector3i(8, 1, 6)).is_empty(), "facing -x the flight is on the +x side")
	_check(is_equal_approx(nav.feet_height(Vector3i(9, 1, 6), 9.9, 6.5), 1.0 + 1.0 / 3.0) and is_equal_approx(nav.feet_height(Vector3i(9, 1, 6), 9.1, 6.5), 2.0), "facing -x it climbs towards -x")
	_check(nav.find_path(Vector3i(11, 1, 6), Vector3i(8, 2, 6)).size() > 0 and nav.last_reached, "a path climbs it from the +x side")

	# Facing +z, a single flight.
	_check(bricks.place(Vector3i(3, 1, 8), 0, kind, 1, "stairs_small", 1) != null, "a single flight facing +z placed")
	_check(is_equal_approx(nav.feet_height(Vector3i(3, 1, 8), 3.5, 8.1), 1.0 + 1.0 / 3.0) and is_equal_approx(nav.feet_height(Vector3i(3, 1, 8), 3.5, 8.9), 2.0), "it climbs towards +z")

	# A plain cube is still a thing to stand on, not in.
	_check(bricks.place(Vector3i(12, 1, 2), 0, kind, 1) != null, "a plain cube placed")
	_check(nav.standable(Vector3i(12, 2, 2)) and not nav.standable(Vector3i(12, 1, 2)), "the top of a cube is a place to stand, the cube is not")

	print("TEST DONE: ", "FAILED" if _failed else "passed")
	quit(1 if _failed else 0)
