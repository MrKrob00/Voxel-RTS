extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- craft).
## Felling a tree (3 logs as physics bodies), carrying logs, the stump that makes planks, cutting grass, the rope machine.
## Stepped on the physics clock (logs are rigid bodies), the units and the board by hand with the same time step.

const DT := 1.0 / 60.0

var _world: VoxelWorld
var _units: UnitManager
var _board: TaskBoard
var _economy: Economy
var _loose: LooseItems
var _props: PropField


func run() -> void:
	seed(20260101)   # the logs get a random push: the same one every time
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
	_props = ctx.props
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
	_board.setup(_world, _units.nav, _economy, _props, _loose, _units)
	for n in [_units, _board]:
		n.process_mode = Node.PROCESS_MODE_DISABLED   # stepped by hand

	var sp := _world.spawn_point()
	_flatten(Vector3i(sp.x - 12, sp.y, sp.z - 12), 20, 14)
	var base := Vector3i(sp.x - 12, sp.y + 1, sp.z - 12)
	var logs_pile := _economy.place_stockpile(base + Vector3i(2, 0, 2))
	check(logs_pile != null, "a stockpile for the logs is down")
	var crew := _units.spawn_squad(base + Vector3i(8, 0, 8), 2, 1)

	await _felling(logs_pile, crew, sp)
	var planks_pile := await _stump(logs_pile, base)
	var grass_pile := _economy.place_stockpile(base + Vector3i(6, 0, 2))   # for the grass: made when the logs and planks are done with
	await _grass_and_rope(grass_pile, planks_pile, crew, base, sp)
	await _log_on_the_ground(base)
	await _first_stockpile(base)
	_circle(sp)
	Engine.time_scale = 1.0
	var waited := 0
	while not _world.is_settled() and waited < 3000:
		await tree.process_frame
		waited += 1


func _flatten(corner: Vector3i, w: int, d: int) -> void:
	for dz in d:
		for dx in w:
			for y in range(corner.y - 3, corner.y + 6):
				var p := Vector3i(corner.x + dx, y, corner.z + dz)
				if y < corner.y:
					_world.set_block(p, Blocks.make(Blocks.DIRT))
				elif y == corner.y:
					_world.set_block(p, Blocks.make(Blocks.GRASS))
				else:
					_world.set_block(p, Blocks.AIR)


## One physics tick of the world and one step of the board and the units.
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


## No ledge or hole within `r` blocks of `p`: every column there has its top within `tol` blocks of the one under `p`.
func _level_around(p: Vector3, r: int, tol: int) -> bool:
	var base_y := _world.surface_y(int(p.x), int(p.z))
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if absi(_world.surface_y(int(p.x) + dx, int(p.z) + dz) - base_y) > tol:
				return false
	return true


func _felling(pile: Stockpile, crew: Array, sp: Vector3i) -> void:
	# The tree nearest to the spawn that stands alone (no other tree within a block and a half).
	var best := -1
	var best_d := INF
	for i in _props.trees.size():
		var o := _props.trees[i].origin
		var d := Vector2(o.x - sp.x, o.z - sp.z).length()
		if d < best_d and d > 14.0 and _props.trees_in_rect(Rect2(o.x - 1.0, o.z - 1.0, 2, 2)).size() == 1 and _level_around(o, 3, 1):
			best = i
			best_d = d
	check(best >= 0, "there is a lone tree to fell (%.0f blocks from the spawn)" % best_d)
	var tree := _props.trees[best].origin
	var task := _board.create_harvest(HarvestTask.Kind.TREES, Rect2(tree.x - 0.5, tree.z - 0.5, 1.0, 1.0))
	check(task != null and task.targets.size() == 1, "marking one tree makes a task with one target")
	for u in crew:
		_board.assign(u, task)
	var ticks := await _until(func() -> bool: return _loose.logs.size() == 3 and _props.tree_alive[best] == 0, 60 * 40)
	check(_props.tree_alive[best] == 0, "the tree is felled")
	check(_loose.logs.size() == 3 or pile.count > 0, "it dropped logs: three rigid bodies (%d on the ground, %d stored)" % [_loose.logs.size(), pile.count])
	for l in _loose.logs:
		check(l.global_position.y > sp.y - 2.0, "a log landed on the ground instead of falling through (y %.1f, ground %d)" % [l.global_position.y, sp.y])
	var seen_log_on_back := [false]
	var done := func() -> bool:
		for u in crew:
			if u.carried_kind() == Resources.Kind.LOG:
				seen_log_on_back[0] = true
		return not _board.tasks.has(task)
	ticks += await _until(done, 60 * 120)
	check(not _board.tasks.has(task), "the task is over: tree and logs dealt with (%.0f s)" % (ticks * DT))
	check(seen_log_on_back[0], "a worker carried a log on the back")
	check(pile.holding == Resources.Kind.LOG and pile.count == 3 and _loose.logs.is_empty(), "three logs are on the platform and none lie about (%d)" % pile.count)


func _stump(logs_pile: Stockpile, base: Vector3i) -> Stockpile:
	var stump := _board.place_station(Station.Kind.STUMP, base + Vector3i(10, 0, 2))
	check(stump != null, "a stump with an axe is set up (%s)" % _economy.last_error)
	check(logs_pile.count == 2, "it cost one log (%d left)" % logs_pile.count)
	var second := _board.place_station(Station.Kind.STUMP, base + Vector3i(12, 0, 2))
	check(second != null and logs_pile.count == 1, "a second stump costs another log (%d left)" % logs_pile.count)
	_board.remove_station(second)
	# Planks go to an empty platform of their own.
	var planks_pile := _economy.place_stockpile(base + Vector3i(2, 0, 6))
	var ticks := await _until(func() -> bool: return _economy.stock_of(Resources.Kind.PLANK) == 3 and _economy.stock_of(Resources.Kind.LOG) == 0, 60 * 60)
	check(_economy.stock_of(Resources.Kind.PLANK) == 3, "idle units came by themselves and made 3 planks of the last log (%d) in %.0f s" % [_economy.stock_of(Resources.Kind.PLANK), ticks * DT])
	check(_economy.stock_of(Resources.Kind.LOG) == 0, "no log is left")
	# The planks lie on one platform (the empty one nearest to where they were made: that may be the one the logs came from).
	for sp in _economy.stockpiles:
		if sp.holding == Resources.Kind.PLANK:
			planks_pile = sp
	await _tick(120)
	for u in _units.units:
		check(u.is_idle() and u.carried_amount() == 0 and _board.task_of(u) == null, "a unit is free again with nothing in its hands")
	return planks_pile


func _grass_and_rope(frame: Stockpile, planks_pile: Stockpile, crew: Array, base: Vector3i, sp: Vector3i) -> void:
	# Cut four tufts of grass: sacks into the frame.
	var picked: Array[int] = []
	for i in _props.tufts.size():
		var o := _props.tufts[i].origin
		if Vector2(o.x - sp.x, o.z - sp.z).length() > 10.0 and picked.size() < 4 and _props.tufts_in_rect(Rect2(o.x - 0.5, o.z - 0.5, 1.0, 1.0)).size() == 1:
			if picked.is_empty() or Vector2(o.x - _props.tufts[picked[0]].origin.x, o.z - _props.tufts[picked[0]].origin.z).length() < 12.0:
				picked.append(i)
	check(picked.size() == 4, "four tufts of grass close together")
	var task := HarvestTask.new(HarvestTask.Kind.GRASS)
	for i in picked:
		task.add_plant(i, _props.tufts[i].origin)
	_board.add_task(task)
	for u in crew:
		_board.assign(u, task)
	var seen_sack := [false]
	var ticks := await _until(func() -> bool:
		for u in crew:
			if u.carried_kind() == Resources.Kind.PLANT:
				seen_sack[0] = true
		return not _board.tasks.has(task), 60 * 150)
	check(seen_sack[0] and frame.holding == Resources.Kind.PLANT and frame.count == 4, "four sacks of grass went into the stockpile (%d, %.0f s)" % [frame.count, ticks * DT])
	check(not (_props.tuft_alive[picked[0]] == 1), "the tufts are gone from the ground")
	# The rope machine: costs two planks, takes two sacks of grass per rope.
	var ropes_pile := _economy.place_stockpile(base + Vector3i(14, 0, 6))
	var machine := _board.place_station(Station.Kind.ROPE_MACHINE, base + Vector3i(10, 0, 6))
	check(machine != null and not machine.enabled, "the rope machine waits to be switched on")
	await _tick(120)
	check(_economy.stock_of(Resources.Kind.ROPE) == 0 and frame.count == 4, "switched off, it makes nothing (%d ropes)" % _economy.stock_of(Resources.Kind.ROPE))
	machine.enabled = true   # what the round menu's Produce does
	check(machine != null and _economy.stock_of(Resources.Kind.PLANK) == 1, "the rope machine is set up for two planks (%d left)" % _economy.stock_of(Resources.Kind.PLANK))
	ticks = await _until(func() -> bool: return _economy.stock_of(Resources.Kind.ROPE) == 2 and frame.count == 0, 60 * 90)
	check(_economy.stock_of(Resources.Kind.ROPE) == 2, "two ropes were made of four sacks of grass (%d, %.0f s)" % [_economy.stock_of(Resources.Kind.ROPE), ticks * DT])
	await _tick(120)
	var all_free := true
	for u in _units.units:
		all_free = all_free and u.is_idle() and u.carried_amount() == 0
	check(all_free, "all units are free again")


## A standing harvest circle: it takes the trees in it, never ends by itself, and follows its radius.
func _circle(sp: Vector3i) -> void:
	var o := Vector3.ZERO
	var best_d := INF
	for t in _props.trees:
		var d := Vector2(t.origin.x - sp.x, t.origin.z - sp.z).length()
		if d < best_d and _props.tree_alive[_props.trees.find(t)] == 1:
			best_d = d
			o = t.origin
	var task := _board.create_harvest_circle(HarvestTask.Kind.TREES, Vector2(o.x, o.z), 3.0)
	check(task != null and task.persistent and task.is_circle(), "a circle over trees makes a standing task")
	check(not task.targets.is_empty() and not task.is_finished(), "it holds the tree in the circle (%d targets) and does not end" % task.targets.size())
	check(task.wants_workers(_board) == (not task.targets.is_empty()), "idle units are called to it when there is a tree to fell")
	var n := task.targets.size()
	task.set_radius(30.0, _board)
	check(task.targets.size() >= n, "a bigger radius takes in more (%d -> %d)" % [n, task.targets.size()])
	task.set_radius(2.0, _board)
	check(task.radius == 2.0 and task.targets.size() <= n, "a smaller one lets go of what is outside")
	_board.remove_task(task)
	check(not _board.tasks.has(task), "closing it removes it")


## No task at all: a log lies on the ground, a stump is free and a stockpile has room for planks. Idle units carry the log to the
## stump, make planks of it and put them in the stockpile, by themselves.
func _log_on_the_ground(base: Vector3i) -> void:
	var planks_before := _economy.stock_of(Resources.Kind.PLANK)
	var spot := Vector3(base.x + 5.0, base.y + 1.0, base.z + 11.0)
	var log := _loose.spawn_log(spot, Vector3.ZERO)
	check(log != null and _loose.logs.size() == 1, "a log lies on the ground")
	var ticks := await _until(func() -> bool: return _economy.stock_of(Resources.Kind.PLANK) >= planks_before + 3 and _loose.logs.is_empty(), 60 * 90)
	check(_economy.stock_of(Resources.Kind.PLANK) == planks_before + 3 and _loose.logs.is_empty(), "idle units took the log to the stump and the three planks to a stockpile (%d planks, %.0f s)" % [_economy.stock_of(Resources.Kind.PLANK), ticks * DT])
	await _tick(120)
	for u in _units.units:
		check(u.is_idle() and u.carried_amount() == 0, "a unit is free again")


## The very beginning: no stockpile at all, only a stump, a log on the ground and a plan for a stockpile. Nothing can be stored, and a
## stockpile cannot be built without planks: the log goes to the stump and its planks go straight to the plan.
func _first_stockpile(base: Vector3i) -> void:
	for st in _economy.stockpiles.duplicate():
		_economy.remove_stockpile(st)
	var plan := _board.place_blueprint("stockpile", 0, base + Vector3i(9, 0, 12))
	check(plan != null and _economy.stockpiles.is_empty(), "no stockpile, one planned (%s)" % _economy.last_error)
	_loose.spawn_log(Vector3(base.x + 5.0, base.y + 1.0, base.z + 11.0), Vector3.ZERO)
	var ticks := await _until(func() -> bool: return _economy.stockpiles.size() == 1, 60 * 120)
	check(_economy.stockpiles.size() == 1 and _loose.logs.is_empty(), "the log became planks at the stump and the planks built the first stockpile (%.0f s)" % (ticks * DT))
	await _tick(120)
	for u in _units.units:
		check(u.is_idle() and u.carried_amount() == 0, "a unit is free again")
