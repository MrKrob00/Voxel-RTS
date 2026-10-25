extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- wall).
## A planned wall is laid brick by brick from the bottom up with the stone of the stacks, in a running bond (cubes at the ends of the offset
## courses); units carry a brick on the back, stand next to the place, and climb on the finished courses to lay the upper ones.

const DT := 0.05

var _world: VoxelWorld
var _units: UnitManager
var _board: TaskBoard
var _economy: Economy
var _bricks: BrickWorld


func run() -> void:
	_world = ctx.world
	_bricks = BrickWorld.new()
	add(_bricks)
	_bricks.setup(_world)
	_units = UnitManager.new()
	add(_units)
	_units.setup(_world, _bricks)
	_economy = Economy.new()
	add(_economy)
	_economy.setup(_world, _bricks)
	_economy.charge_for_stockpiles = false
	_units.nav.obstacle = _economy.blocks_cell
	_board = TaskBoard.new()
	add(_board)
	_board.setup(_world, _units.nav, _economy, null, null, _units)
	for n in [_units, _board]:
		n.process_mode = Node.PROCESS_MODE_DISABLED

	_layout()
	var sp := _world.spawn_point()
	for dz in 16:
		for dx in 20:
			for y in range(sp.y - 3, sp.y + 8):
				var p := Vector3i(sp.x - 12 + dx, y, sp.z - 12 + dz)
				_world.set_block(p, Blocks.make(Blocks.GRASS) if y == sp.y else (Blocks.make(Blocks.DIRT) if y < sp.y else Blocks.AIR))
	var base := Vector3i(sp.x - 12, sp.y + 1, sp.z - 12)
	var stacks: Array[Stockpile] = []
	for i in 3:
		var st := _economy.place_stockpile(base + Vector3i(1 + i * 3, 0, 1), Stockpile.Style.STACK)
		st.add(Resources.Kind.BRICK, 8)
		stacks.append(st)
	var crew := _units.spawn_squad(base + Vector3i(9, 0, 7), 3, 1)

	check(_board.place_wall(base + Vector3i(2, 0, 9), base + Vector3i(7, 0, 9), 3) != null, "a wall 6 cells long and 3 courses high is planned (%s)" % _economy.last_error)
	var plan: WallPlan = _economy.walls[0]
	check(plan.total_halves() == 18, "it needs 18 halves of stone: 3 + 4 + 3 bricks and four cubes in the offset course (%d)" % plan.total_halves())
	check(_economy.place_wall(base + Vector3i(4, 0, 9), base + Vector3i(4, 0, 12), 1) == null and _economy.last_error.contains("overlaps"), "another wall cannot cross it (%s)" % _economy.last_error)
	check(_economy.place_wall(base + Vector3i(2, 0, 9), base + Vector3i(2, 0, 9), 1) == null, "...nor start on the same cell")

	# Build, watching the order: the bottom course first, every brick laid on something.
	var max_course_placed := -1
	var order_ok := true
	var carried_brick := false
	var ticks := 0
	var done_check := func() -> bool: return _economy.walls.is_empty() or plan.is_done()
	while not done_check.call() and ticks < 3000:
		_board._process(DT)
		for u in crew:
			u._process(DT)
			carried_brick = carried_brick or (u.carried_kind() == Resources.Kind.BRICK and u.carried_amount() > 0)
		for s in plan.slots:
			if s.done and s.course > max_course_placed:
				max_course_placed = s.course
				# every slot of the courses below must already be laid, or at least have its neighbour support
				for t in plan.slots:
					if t.course < s.course - 1 and not t.done:
						order_ok = false
		ticks += 1
	check(plan.is_done(), "the whole wall is laid (%.0f s of work by 3 units)" % (ticks * DT))
	check(order_ok, "it grew from the bottom up: nothing was laid two courses above an empty place")
	check(carried_brick, "a unit carried a brick on its back")
	var cells := 0
	for x in range(base.x, base.x + 10):
		for y in range(base.y, base.y + 4):
			if _bricks.occupied(Vector3i(x, y, base.z + 9)):
				cells += 1
	check(cells == 18, "18 cells of the wall are filled with bricks (%d)" % cells)
	# The running bond: no vertical joint runs through two courses in a row.
	var joints_ok := true
	for course in 2:
		for x in range(base.x + 2, base.x + 8):
			var here := _bricks.brick_at(Vector3i(x, base.y + course, base.z + 9))
			var above := _bricks.brick_at(Vector3i(x, base.y + course + 1, base.z + 9))
			var next_here := _bricks.brick_at(Vector3i(x + 1, base.y + course, base.z + 9))
			var next_above := _bricks.brick_at(Vector3i(x + 1, base.y + course + 1, base.z + 9))
			if here != null and next_here != null and here != next_here and above != null and next_above != null and above != next_above:
				joints_ok = false
	check(joints_ok, "the courses are offset: no joint lines up with the one below")
	var left := 0
	for st in _economy.stockpiles:
		left += st.count
	check(left == 24 - 18, "6 of the 24 halves of stone are still in the stacks (%d)" % left)
	_step(400)
	for u in crew:
		check(u.carried_amount() == 0 and u.is_idle() and _board.task_of(u) == null, "a unit is free and empty-handed again")
	check(not _board.tasks.any(func(t: WorkTask) -> bool: return t is WallTask), "the wall's job is over")
	check(_economy.place_wall(base + Vector3i(2, 0, 13), base + Vector3i(13, 0, 13), 5) != null and _economy.walls[-1].courses == WallPlan.MAX_COURSES, "a taller wall is cut back to %d courses for now" % WallPlan.MAX_COURSES)

	await _stairs_block(base, crew)


## A stairs block: one 2x1x1 piece of half steps and half whole, built from two halves of stone, and walked over by a unit.
func _stairs_block(base: Vector3i, crew: Array) -> void:
	for st in _economy.stockpiles:
		st.add(Resources.Kind.BRICK, 4)
	var at := base + Vector3i(14, 0, 3)
	var plan := _board.place_stairs(at, Vector2i(1, 0))
	check(plan != null and plan.total_halves() == 2, "a stairs block is planned and costs two halves of stone (%s)" % _economy.last_error)
	check(_board.place_stairs(at, Vector2i(1, 0)) == null, "the same place cannot be planned twice")
	var ticks := 0
	while plan != null and not plan.is_done() and ticks < 3000:
		_step(1)
		ticks += 1
	check(plan.is_done(), "the stairs block is built (%.0f s)" % (ticks * DT))
	check(Blocks.is_stairs(_world.get_block(at)), "its cell became a stair piece")
	check(_bricks.occupied(at + Vector3i(1, 0, 0)), "a stone cube stands at its high end")
	_step(300)
	for u in crew:
		check(u.is_idle() and u.carried_amount() == 0, "a unit is free again")


## The layout alone: bricks and cubes in a running bond.
func _layout() -> void:
	var even := WallPlan.layout(Vector3i.ZERO, 0, 6, 2)
	check(even.size() == 3 + 4, "6 cells, 2 courses: 3 bricks, then a cube, 2 bricks and a cube (%d)" % even.size())
	var odd := WallPlan.layout(Vector3i.ZERO, 0, 5, 2)
	var cubes := 0
	var halves := 0
	for s in odd:
		cubes += 1 if s.length == 1 else 0
		halves += s.length
	check(halves == 10 and cubes == 2, "5 cells, 2 courses: every cell is covered once per course (%d halves, %d cubes)" % [halves, cubes])
	var covered := {}
	var overlap := false
	for s in WallPlan.layout(Vector3i(3, 5, 7), 1, 7, 3):
		for c in s.cells():
			overlap = overlap or covered.has(c)
			covered[c] = true
	check(not overlap and covered.size() == 21, "a wall along z, 7 cells and 3 courses: 21 cells, none twice")


func _step(n: int) -> void:
	for i in n:
		_board._process(DT)
		for u in _units.units:
			u._process(DT)
