extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- quarry).
## A quarry digs layer by layer and leaves a staircase that units can walk down into the pit and climb back out of: a step (with a stair
## piece) in every column, one block lower each, no flat stretches except a landing where the stairs turn a corner.

var _world: VoxelWorld
var _units: UnitManager
var _board: TaskBoard
var _top_y := 0
var _corner := Vector3i.ZERO


func run() -> void:
	_world = ctx.world
	var bricks := BrickWorld.new()
	add(bricks)
	bricks.setup(_world)
	_units = UnitManager.new()
	add(_units)
	_units.setup(_world, bricks)
	var economy := Economy.new()
	add(economy)
	economy.setup(_world, bricks)
	economy.charge_for_stockpiles = false
	_board = TaskBoard.new()
	add(_board)
	_board.setup(_world, _units.nav, economy, null, null, _units)
	for n in [_units, _board]:
		n.process_mode = Node.PROCESS_MODE_DISABLED

	var sp := _world.spawn_point()
	_top_y = sp.y
	# A pad of solid ground, deep enough to dig 6 layers.
	_corner = Vector3i(sp.x - 14, _top_y, sp.z - 14)
	for dz in 16:
		for dx in 22:
			for y in range(_top_y - 9, _top_y + 6):
				var p := Vector3i(_corner.x + dx, y, _corner.z + dz)
				_world.set_block(p, Blocks.make(Blocks.STONE) if y <= _top_y else Blocks.AIR)
	_straight()
	_corner_case()
	_free_units_help()
	var waited := 0
	while not _world.is_settled() and waited < 3000:
		await tree.process_frame
		waited += 1


func _run(task: DigTask, crew_size: int, at: Vector3i) -> int:
	task.collect = {}   # nothing is carried home: these tests are about the digging
	var crew := _units.spawn_squad(at, crew_size, 1)
	for u in crew:
		_board.assign(u, task)
	var frames := 0
	while _board.tasks.has(task) and frames < 80000:
		_board._process(0.05)
		for u in crew:
			u._process(0.05)
		frames += 1
	for u in crew:
		check(u.is_idle() and u.carried_amount() == 0, "a worker is idle again")
		_units.units.erase(u)
		u.queue_free()
	return frames


func _dug(col: Vector2i) -> int:
	return _top_y - (_world.terrain.level(col.x, col.y) / Blocks.UNIT - 1)


func _walks(from_cell: Vector3i, to_cell: Vector3i) -> Array[Vector3i]:
	return _units.nav.find_path(from_cell, to_cell)


func _straight() -> void:
	print("-- 8 x 6 columns, 3 layers")
	var x0 := _corner.x + 4
	var z0 := _corner.z + 4
	var task := _board.create_dig(x0, z0, x0 + 7, z0 + 5, 3)
	check(task != null and task.depth == 3, "a quarry 8 x 6 columns, 3 layers deep (depth %d)" % task.depth)
	check(task.stair_columns.size() == 4, "its staircase is four columns long: the start and one step per layer, no flat stretches (%d)" % task.stair_columns.size())
	var want := [0, 1, 2, 3]
	var ok := true
	for j in 4:
		ok = ok and task.limits[Vector2i(x0 + j, z0)] == want[j]
	check(ok, "the stair columns are dug 0, 1, 2, 3 layers")
	var rises := true
	for j in [1, 2, 3]:
		rises = rises and task.stair_rise[Vector2i(x0 + j, z0)] == Vector2i(-1, 0)
	check(rises, "columns 1 to 3 are stair pieces rising towards the column before")
	check(task.cells.size() == 47, "layer 1 marks every column but the first of the staircase (%d)" % task.cells.size())
	var frames := _run(task, 4, Vector3i(x0 - 2, _top_y + 1, z0 - 2))
	check(not _board.tasks.has(task), "the quarry is finished (%.0f s of work by 4 units)" % (frames * 0.05))
	var depth_ok := true
	var msg := ""
	for col in task.columns:
		if _dug(col) != task.limits.get(col, task.depth):
			depth_ok = false
			msg = "column %s dug %d, wanted %d" % [str(col), _dug(col), task.limits.get(col, task.depth)]
			break
	check(depth_ok, "every column is dug exactly as deep as planned %s" % msg)
	var pieces_ok := true
	for j in [1, 2, 3]:
		var cell := Vector3i(x0 + j, _top_y - j + 1, z0)
		var raw := _world.get_block(cell)
		if not (Blocks.is_stairs(raw) and Blocks.wedge_direction(Blocks.shape(raw)) == Vector2i(-1, 0)):
			pieces_ok = false
	check(pieces_ok, "each of them holds a stair piece")
	var stairs_cell := Vector3i(x0 + 2, _top_y - 1, z0)
	var nav := _units.nav
	check(nav.standable(stairs_cell), "a stair piece is a place to stand")
	var low := nav.feet_height(stairs_cell, stairs_cell.x + 0.9, stairs_cell.z + 0.5)
	var high := nav.feet_height(stairs_cell, stairs_cell.x + 0.1, stairs_cell.z + 0.5)
	check(is_equal_approx(high, stairs_cell.y + 1.0) and is_equal_approx(low, stairs_cell.y + 0.25), "feet climb four steps from a quarter to a whole block (%.2f to %.2f)" % [low - stairs_cell.y, high - stairs_cell.y])
	var levels := {}
	for i in 20:
		levels[snappedf(nav.feet_height(stairs_cell, stairs_cell.x + 1.0 - (i + 0.5) / 20.0, stairs_cell.z + 0.5), 0.001)] = true
	check(levels.size() == 4, "the height is stepped: exactly four levels (%d)" % levels.size())
	var entry := nav.nearest_standable(Vector3i(x0 - 1, _top_y + 1, z0), 2)
	var bottom := nav.nearest_standable(Vector3i(x0 + 5, _top_y + 1 - 3, z0 + 3), 2)
	check(entry.x >= 0 and bottom.x >= 0 and bottom.y == _top_y + 1 - 3, "there is a floor at the bottom of the pit (y %d)" % bottom.y)
	_walks(entry, bottom)
	check(nav.last_reached, "units can walk from the edge down to the bottom")
	var back := _walks(bottom, entry)
	check(nav.last_reached, "...and climb back out")
	var max_up := 0
	for i in range(1, back.size()):
		max_up = maxi(max_up, back[i].y - back[i - 1].y)
	check(max_up <= Navigation.MAX_STEP_UP, "the climb never needs more than one block at a step (%d)" % max_up)
	var via_stairs := false
	for c in back:
		if c.z == z0 and c.x > x0 and c.x <= x0 + 3:
			via_stairs = true
	check(via_stairs, "the way out goes up the staircase")


func _free_units_help() -> void:
	print("-- 4 x 4 columns, 1 layer: free units come to help by themselves")
	var x0 := _corner.x + 4
	var z0 := _corner.z + 10
	var task := _board.create_dig(x0, z0, x0 + 3, z0 + 3, 1)
	task.collect = {}
	var crew := _units.spawn_squad(Vector3i(x0 - 2, _top_y + 1, z0 - 2), 3, 1)   # nobody is told to dig
	var most := 0
	var frames := 0
	while _board.tasks.has(task) and frames < 40000:
		_board._process(0.05)
		for u in crew:
			u._process(0.05)
		most = maxi(most, task.workers.size())
		frames += 1
	check(not _board.tasks.has(task), "the quarry was dug although nobody was told to (%d frames)" % frames)
	check(most == 3, "all three free units came to help (at most %d at once)" % most)
	for u in crew:
		_units.units.erase(u)
		u.queue_free()


func _corner_case() -> void:
	print("-- 4 x 4 columns, 5 layers: the stairs have to turn corners")
	var x0 := _corner.x + 14
	var z0 := _corner.z + 4
	var task := _board.create_dig(x0, z0, x0 + 3, z0 + 3, 5)
	check(task != null and task.depth == 5, "a quarry 4 x 4 columns, 5 layers deep (depth %d)" % task.depth)
	# The way round the edge: along x to the corner (a landing), along z, ... one column per layer, plus the landings.
	var landings := 0
	for col in task.stair_columns:
		if col != Vector2i(x0, z0) and not task.stair_rise.has(col):
			landings += 1
	check(task.stair_rise.size() == 5 and landings == 1, "five steps and one landing, at the corner (%d steps, %d landings)" % [task.stair_rise.size(), landings])
	check(task.limits[Vector2i(x0 + 3, z0)] == task.limits[Vector2i(x0 + 2, z0)], "the landing is as deep as the step before it")
	var after := Vector2i(x0 + 3, z0 + 1)
	check(task.stair_rise.get(after, Vector2i.ZERO) == Vector2i(0, -1), "after the corner the steps rise towards -z")
	_run(task, 4, Vector3i(x0 - 2, _top_y + 1, z0 - 2))
	check(not _board.tasks.has(task), "the quarry is finished")
	var depth_ok := true
	for col in task.columns:
		depth_ok = depth_ok and _dug(col) == task.limits.get(col, task.depth)
	check(depth_ok, "every column is dug exactly as deep as planned")
	var landing_cell := Vector3i(x0 + 3, _top_y - task.limits[Vector2i(x0 + 3, z0)] + 1, z0)
	check(_world.get_block(landing_cell) == Blocks.AIR and _units.nav.standable(landing_cell), "the landing is plain floor")
	var nav := _units.nav
	var entry := nav.nearest_standable(Vector3i(x0 - 1, _top_y + 1, z0), 2)
	var bottom := nav.nearest_standable(Vector3i(x0 + 1, _top_y + 1 - 5, z0 + 1), 2)
	check(bottom.x >= 0 and bottom.y == _top_y + 1 - 5, "there is a floor five blocks down (y %d)" % bottom.y)
	_walks(entry, bottom)
	check(nav.last_reached, "units can walk down the turning stairs to the bottom")
	var back := _walks(bottom, entry)
	check(nav.last_reached, "...and climb back out")
	var max_up := 0
	for i in range(1, back.size()):
		max_up = maxi(max_up, back[i].y - back[i - 1].y)
	check(max_up <= Navigation.MAX_STEP_UP, "the climb never needs more than one block at a step (%d)" % max_up)
