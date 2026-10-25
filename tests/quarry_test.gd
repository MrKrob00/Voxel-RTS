extends SceneTree
## Headless: godot --headless --path . -s res://tests/quarry_test.gd
## A quarry digs layer by layer and leaves a staircase that units can walk down into the pit and climb back out of.

var _failed := false


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _init() -> void:
	var world := VoxelWorld.new()
	world.extra_islands = 0
	root.add_child(world)
	while not world.is_ready():
		await process_frame
	var bricks := BrickWorld.new()
	root.add_child(bricks)
	bricks.setup(world)
	var units := UnitManager.new()
	root.add_child(units)
	units.setup(world, bricks)
	var economy := Economy.new()
	root.add_child(economy)
	economy.setup(world, bricks)
	var board := TaskBoard.new()
	root.add_child(board)
	board.setup(world, units.nav, economy, null, null, units)
	for n in [units, board]:
		n.process_mode = Node.PROCESS_MODE_DISABLED

	var sp := world.spawn_point()
	var top_y := sp.y
	# A pad of solid ground, deep enough to dig 4 layers.
	var corner := Vector3i(sp.x - 14, top_y, sp.z - 14)
	for dz in 16:
		for dx in 22:
			for y in range(top_y - 8, top_y + 6):
				var p := Vector3i(corner.x + dx, y, corner.z + dz)
				if y <= top_y:
					world.set_block(p, Blocks.make(Blocks.STONE))
				else:
					world.set_block(p, Blocks.AIR)
	var x0 := corner.x + 4
	var z0 := corner.z + 4
	var task := board.create_dig(x0, z0, x0 + 7, z0 + 5, 3)
	_check(task != null and task.depth == 3, "a quarry 8 x 6 columns, 3 layers deep (depth %d)" % task.depth)
	_check(task.stair_columns.size() == 6 and task.stair_dir == Vector2i(1, 0), "its staircase is 6 columns along the long side")
	var want := [0, 1, 1, 2, 2, 3]
	var ok := true
	for j in 6:
		ok = ok and task.limits[Vector2i(x0 + j, z0)] == want[j]
	_check(ok, "stair columns are dug 0, 1, 1, 2, 2, 3 layers")
	_check(task.cells.size() == 47, "layer 1 marks every column but the first of the staircase (%d)" % task.cells.size())
	for k in task.cells:
		task.collect = {}   # nothing is carried home: this test is about the digging
	var crew := units.spawn_squad(Vector3i(x0 - 2, top_y + 1, z0 - 2), 4, 1)
	for u in crew:
		board.assign(u, task)
	var frames := 0
	var seen_layers := {}
	while board.tasks.has(task) and frames < 60000:
		for t in board.tasks:
			t.update(board)
		board._process(0.05)
		for u in crew:
			u._process(0.05)
		seen_layers[task.layer] = true
		frames += 1
	_check(not board.tasks.has(task), "the quarry is finished (%.0f s of work by 4 units)" % (frames * 0.05))
	_check(seen_layers.has(1) and seen_layers.has(2) and seen_layers.has(3), "it went through layers 1, 2 and 3 in turn")
	var depth_ok := true
	var first_wrong := ""
	for col in task.columns:
		var dug := top_y - (world.terrain.level(col.x, col.y) / Blocks.UNIT - 1)
		var wanted: int = task.limits.get(col, task.depth)
		if dug != wanted:
			depth_ok = false
			first_wrong = "column %s dug %d, wanted %d" % [str(col), dug, wanted]
			break
	_check(depth_ok, "every column is dug exactly as deep as planned %s" % first_wrong)
	# Every second column of the staircase ends in a stair piece rising towards the step before it.
	var pieces_ok := true
	var pieces_msg := ""
	for j in [1, 3, 5]:
		var col: Vector2i = Vector2i(x0 + j, z0)
		var k: int = (j + 1) / 2
		var cell := Vector3i(col.x, top_y - k + 1, col.y)
		var raw := world.get_block(cell)
		if not (Blocks.is_stairs(raw) and Blocks.wedge_direction(Blocks.shape(raw)) == Vector2i(-1, 0)):
			pieces_ok = false
			pieces_msg = "column %d has %d" % [j, raw]
	_check(pieces_ok, "columns 1, 3 and 5 end in a stair piece that rises towards the column before %s" % pieces_msg)
	var even_flat := true
	for j in [2, 4]:
		even_flat = even_flat and world.get_block(Vector3i(x0 + j, top_y - (j + 1) / 2 + 1, z0)) == Blocks.AIR
	_check(even_flat, "columns 2 and 4 are plain floor (a flat half and a stair half make a 2 x 1 x 1 piece)")
	var stairs_cell := Vector3i(x0 + 3, top_y - 1, z0)
	var nav0 := units.nav
	_check(nav0.standable(stairs_cell), "a stair piece is a place to stand")
	var low := nav0.feet_height(stairs_cell, stairs_cell.x + 0.9, stairs_cell.z + 0.5)
	var high := nav0.feet_height(stairs_cell, stairs_cell.x + 0.1, stairs_cell.z + 0.5)
	_check(is_equal_approx(high, stairs_cell.y + 1.0) and is_equal_approx(low, stairs_cell.y + 0.25), "feet climb four steps from a quarter to a whole block (%.2f to %.2f)" % [low - stairs_cell.y, high - stairs_cell.y])
	var mid_steps := {}
	for i in 20:
		mid_steps[snappedf(nav0.feet_height(stairs_cell, stairs_cell.x + 1.0 - (i + 0.5) / 20.0, stairs_cell.z + 0.5), 0.001)] = true
	_check(mid_steps.size() == 4, "the height is stepped: exactly four levels (%d)" % mid_steps.size())
	# The way down and the way back.
	var nav := units.nav
	var entry := nav.nearest_standable(Vector3i(x0 - 1, top_y + 1, z0), 2)
	var bottom := nav.nearest_standable(Vector3i(x0 + 4, top_y + 1 - 3, z0 + 3), 2)
	_check(entry.x >= 0 and bottom.x >= 0 and bottom.y == top_y + 1 - 3, "there is a floor at the bottom of the pit (y %d)" % bottom.y)
	var down := nav.find_path(entry, bottom)
	_check(nav.last_reached, "units can walk from the edge down to the bottom")
	var back := nav.find_path(bottom, entry)
	_check(nav.last_reached, "...and climb back out, one block up at a time")
	var max_up := 0
	for i in range(1, back.size()):
		max_up = maxi(max_up, back[i].y - back[i - 1].y)
	_check(max_up <= Navigation.MAX_STEP_UP, "the climb never needs more than one block at a step (%d)" % max_up)
	var via_stairs := false
	for c in back:
		if c.z == z0 and c.x >= x0 and c.x < x0 + 6:
			via_stairs = true
	_check(via_stairs, "the way out goes up the staircase")
	for u in crew:
		_check(u.is_idle() and u.carried_amount() == 0, "a worker is idle again")
	var waited := 0
	while not world.is_settled() and waited < 3000:
		await process_frame
		waited += 1
	quit(1 if _failed else 0)
