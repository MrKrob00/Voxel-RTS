extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- logs).
## Where a felled log goes: nowhere (it stays lying, nobody picks it up without a place for it), or to a free stump first and its
## planks to a stockpile, after which the worker goes back to felling.

const DT := 1.0 / 60.0

var _world: VoxelWorld
var _units: UnitManager
var _board: TaskBoard
var _economy: Economy
var _loose: LooseItems


func run() -> void:
	seed(7)
	Engine.time_scale = 6.0
	_world = ctx.world
	var colliders := GroundColliders.new()
	add(colliders)
	colliders.setup(_world)
	var bricks := BrickWorld.new()
	add(bricks)
	bricks.setup(_world, colliders)
	_loose = LooseItems.new()
	add(_loose)
	_loose.setup(_world, colliders)
	_units = UnitManager.new()
	add(_units)
	_units.setup(_world, bricks)
	_economy = Economy.new()
	add(_economy)
	_economy.setup(_world, bricks)
	_economy.charge_for_stockpiles = false   # the scene is set up with stockpiles for free
	_units.nav.obstacle = _economy.blocks_cell
	_board = TaskBoard.new()
	add(_board)
	_board.setup(_world, _units.nav, _economy, ctx.props, _loose, _units)
	for n in [_units, _board]:
		n.process_mode = Node.PROCESS_MODE_DISABLED

	var sp := _world.spawn_point()
	# A flat pad for the stockpile and the stump.
	for dz in 12:
		for dx in 16:
			for y in range(sp.y - 3, sp.y + 6):
				var p := Vector3i(sp.x - 12 + dx, y, sp.z - 12 + dz)
				_world.set_block(p, Blocks.make(Blocks.GRASS) if y == sp.y else (Blocks.make(Blocks.DIRT) if y < sp.y else Blocks.AIR))
	var base := Vector3i(sp.x - 12, sp.y + 1, sp.z - 12)
	var worker := _units.spawn_squad(base + Vector3i(6, 0, 6), 1, 0)[0]

	# The nearest lone tree on level ground.
	var best := -1
	var best_d := INF
	for i in ctx.props.trees.size():
		var o := ctx.props.trees[i].origin
		var d := Vector2(o.x - sp.x, o.z - sp.z).length()
		if d < best_d and d > 14.0 and ctx.props.trees_in_rect(Rect2(o.x - 1.5, o.z - 1.5, 3, 3)).size() == 1 and _level_around(o, 4, 1):
			best = i
			best_d = d
	var tree: Vector3 = ctx.props.trees[best].origin
	var task := _board.create_harvest(HarvestTask.Kind.TREES, Rect2(tree.x - 0.5, tree.z - 0.5, 1.0, 1.0))
	_board.assign(worker, task)

	# 1. No stockpile at all: the tree is felled, the logs stay where they fell.
	await _until(func() -> bool: return _loose.logs.size() == 3, 60 * 40)
	await _tick(60 * 8)
	check(ctx.props.tree_alive[best] == 0 and _loose.logs.size() == 3, "the tree is felled and its three logs lie there")
	check(worker.carried_amount() == 0 and _board.tasks.has(task), "nobody picks a log up when there is nowhere to take it")

	# 2. A stockpile for the stump's price, then the stump: logs now go to the stump, planks to the stockpile.
	var pile := _economy.place_stockpile(base + Vector3i(2, 0, 2), Stockpile.Style.PLATFORM)
	pile.add(Resources.Kind.LOG, 1)
	var stump := _board.place_station(Station.Kind.STUMP, base + Vector3i(8, 0, 2))
	check(stump != null and pile.count == 0, "a stump is set up with a log from the stockpile (%s)" % _economy.last_error)
	var seen_log := [false]
	var seen_planks := [false]
	var ticks := await _until(func() -> bool:
		seen_log[0] = seen_log[0] or worker.carried_kind() == Resources.Kind.LOG
		seen_planks[0] = seen_planks[0] or (worker.carried_kind() == Resources.Kind.PLANK and worker.carried_amount() == 3)
		return not _board.tasks.has(task) and _economy.stock_of(Resources.Kind.PLANK) == 9, 60 * 240)
	check(seen_log[0] and seen_planks[0], "the worker took a log to the stump and carried three planks away")
	check(_economy.stock_of(Resources.Kind.PLANK) == 9 and _economy.stock_of(Resources.Kind.LOG) == 0 and _loose.logs.is_empty(), "three logs became nine planks on the stockpile, none left lying (%d planks, %.0f s)" % [_economy.stock_of(Resources.Kind.PLANK), ticks * DT])
	check(not _board.tasks.has(task), "the felling job is finished: the worker went back to it after each trip")
	await _tick(120)
	check(worker.is_idle() and worker.carried_amount() == 0 and _board.task_of(worker) == null, "the worker is free again")


func _level_around(p: Vector3, r: int, tol: int) -> bool:
	var base_y := _world.surface_y(int(p.x), int(p.z))
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if absi(_world.surface_y(int(p.x) + dx, int(p.z) + dz) - base_y) > tol:
				return false
	return true


func _tick(n := 1) -> void:
	for i in n:
		await tree.physics_frame
		_board._process(DT)
		for u in _units.units:
			u._process(DT)


func _until(cond: Callable, max_ticks: int) -> int:
	var ticks := 0
	while not cond.call() and ticks < max_ticks:
		await _tick()
		ticks += 1
	return ticks
