extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- build).
## Blueprints: the player plans a building, idle units bring what it costs from the stockpiles when they have it, and the building
## stands when everything has arrived.

const DT := 0.05

var _world: VoxelWorld
var _units: UnitManager
var _board: TaskBoard
var _economy: Economy


func run() -> void:
	_world = ctx.world
	var bricks := BrickWorld.new()
	add(bricks)
	bricks.setup(_world)
	_units = UnitManager.new()
	add(_units)
	_units.setup(_world, bricks)
	_economy = Economy.new()
	add(_economy)
	_economy.setup(_world, bricks)
	_economy.charge_for_stockpiles = false
	_units.nav.obstacle = _economy.blocks_cell
	_board = TaskBoard.new()
	add(_board)
	_board.setup(_world, _units.nav, _economy, null, null, _units)
	for n in [_units, _board]:
		n.process_mode = Node.PROCESS_MODE_DISABLED

	var sp := _world.spawn_point()
	for dz in 14:
		for dx in 18:
			for y in range(sp.y - 3, sp.y + 6):
				var p := Vector3i(sp.x - 12 + dx, y, sp.z - 12 + dz)
				_world.set_block(p, Blocks.make(Blocks.GRASS) if y == sp.y else (Blocks.make(Blocks.DIRT) if y < sp.y else Blocks.AIR))
	var base := Vector3i(sp.x - 12, sp.y + 1, sp.z - 12)
	var bank := _economy.place_stockpile(base + Vector3i(2, 0, 2))
	var logbank := _economy.place_stockpile(base + Vector3i(2, 0, 7))
	var crew := _units.spawn_squad(base + Vector3i(8, 0, 5), 2, 1)

	# A stockpile blueprint costs three planks.
	var plan := _board.place_blueprint("stockpile", 0, base + Vector3i(10, 0, 2))
	check(plan != null and plan.cost == {Resources.Kind.PLANK: 3}, "a blueprint of a stockpile asks for three planks")
	check(_economy.stockpiles.size() == 2 and _economy.blueprints.size() == 1, "nothing is built yet, only planned")
	check(_board.place_blueprint("stockpile", 0, base + Vector3i(11, 0, 3)) == null and _economy.last_error.contains("overlaps"), "a second plan cannot overlap the first (%s)" % _economy.last_error)
	_step(400)
	check(_economy.stockpiles.size() == 2 and plan.delivered.is_empty(), "with no planks anywhere nobody does anything")
	for u in crew:
		check(u.is_idle() and u.carried_amount() == 0, "the units stand idle")
	bank.add(Resources.Kind.PLANK, 3)
	var seen_planks := [false]
	var ticks := _until(func() -> bool:
		for u in crew:
			seen_planks[0] = seen_planks[0] or (u.carried_kind() == Resources.Kind.PLANK and u.carried_amount() == 3)
		return _economy.stockpiles.size() == 3, 3000)
	check(seen_planks[0], "once the planks are there a unit comes by itself and carries three of them")
	check(_economy.stockpiles.size() == 3 and _economy.blueprints.is_empty() and bank.count == 0, "the stockpile stands where the blueprint was, the planks are used up (%.0f s)" % (ticks * DT))
	check(_economy.stockpiles[2].origin == base + Vector3i(10, 0, 2), "...exactly there")
	_step(200)
	for u in crew:
		check(u.is_idle() and u.carried_amount() == 0 and _board.task_of(u) == null, "the units are free again")

	# A stump costs a log; the station gets its standing job when it stands.
	var stump_plan := _board.place_blueprint("station", Station.Kind.STUMP, base + Vector3i(6, 0, 10))
	check(stump_plan != null and stump_plan.cost == {Resources.Kind.LOG: 1}, "a blueprint of a stump asks for a log")
	logbank.add(Resources.Kind.LOG, 1)
	var ghost_seen := [false]
	_until(func() -> bool:
		if is_instance_valid(stump_plan) and stump_plan.is_ghost_log_shown():
			ghost_seen[0] = true
		return not _economy.stations.is_empty(), 3000)
	check(ghost_seen[0], "a ghost log hung over the plan while the log was carried to it")
	check(_economy.stations.size() == 1 and _economy.stations[0].task != null, "the stump stands and has its job")
	check(_economy.stock_of(Resources.Kind.LOG) == 0, "the log was used")

	# A plan can be cancelled.
	var third := _board.place_blueprint("station", Station.Kind.ROPE_MACHINE, base + Vector3i(12, 0, 8))
	var tasks_before := _board.tasks.size()
	_board.cancel_blueprint(third)
	check(_economy.blueprints.is_empty() and _board.tasks.size() == tasks_before - 1, "a cancelled plan goes with its job")

	# The only stockpile holds logs (no room for planks) and a second one is only planned: the stump makes planks of a log and they
	# go straight to the blueprint, nobody waits for a stockpile that does not exist yet.
	_economy.remove_stockpile(bank)
	_economy.remove_stockpile(_economy.stockpiles[1])
	var logs_only := _economy.stockpiles[0]
	logs_only.add(Resources.Kind.LOG, 2)
	var second := _board.place_blueprint("stockpile", 0, base + Vector3i(10, 0, 2))
	check(second != null and _economy.stockpiles.size() == 1, "one stockpile, full of logs, and a second one planned")
	_until(func() -> bool: return _economy.stockpiles.size() == 2, 6000)
	check(_economy.stockpiles.size() == 2 and logs_only.count == 1, "the stump made three planks of a log and they built the second stockpile (%d logs left)" % logs_only.count)
	_step(300)
	for u in crew:
		check(u.carried_amount() == 0, "nobody is left holding planks")

	# A stockpile with room AND a plan that needs planks: the planks go to the plan first.
	var room := _economy.place_stockpile(base + Vector3i(2, 0, 2))
	var third_plan := _board.place_blueprint("stockpile", 0, base + Vector3i(10, 0, 7))
	logs_only.add(Resources.Kind.LOG, 1)
	_until(func() -> bool: return _economy.stockpiles.size() == 4, 6000)
	check(_economy.stockpiles.size() == 4 and room.count == 0, "the planks went to the plan, not to the stockpile that had room (%d on it)" % room.count)


	# A plan is deleted while a unit carries its planks to it: it takes them to a stockpile (room) or throws them into the world.
	var plan4 := _board.place_blueprint("stockpile", 0, base + Vector3i(14, 0, 7))
	check(plan4 != null, "a fourth plan (%s)" % _economy.last_error)
	var spare := _economy.place_stockpile(base + Vector3i(14, 0, 2))
	room.add(Resources.Kind.PLANK, 12)   # planks the units can carry to the plan (and no room left in this stockpile)
	var carrying := [null]
	_until(func() -> bool:
		for u in crew:
			if u.carried_kind() == Resources.Kind.PLANK and u.carried_amount() > 0:
				carrying[0] = u
		return carrying[0] != null, 3000)
	check(carrying[0] != null, "a unit carries planks towards the plan")
	var holder: Unit = carrying[0]
	_board.cancel_blueprint(plan4)
	_until(func() -> bool: return holder.carried_amount() == 0 and holder.is_idle(), 3000)
	check(holder.carried_amount() == 0 and holder.is_idle(), "the unit put its planks down and is free")
	check(_economy.stock_of(Resources.Kind.PLANK) == 12, "all twelve planks are on stockpiles again, the three it carried too (%d)" % _economy.stock_of(Resources.Kind.PLANK))

	# A job whose blueprint is already built and freed (a worker may still be on it): nothing to fetch, no crash.
	var gone := Blueprint.new()
	var job := BuildTask.new(gone)
	gone.free()
	check(job.is_finished() and job.input_needed().is_empty(), "a finished building job with a freed blueprint asks for nothing")

	# The ghost before a block is planned asks the same question the plan does, without planning anything.
	var spot := base + Vector3i(14, 0, 9)
	check(_economy.block_error("brick", spot, Vector2i(1, 0)) == "" and _economy.walls.is_empty(), "a free flat spot has no error and nothing is planned by asking")
	check(_economy.block_error("brick", base + Vector3i(3, 0, 3), Vector2i(1, 0)).contains("overlaps"), "the ghost over a stockpile is refused")

	# A block can be planned on a plan that is not laid yet; it is laid only after the one under it.
	var up := spot + Vector3i(0, 1, 0)
	check(_economy.block_error("brick", up, Vector2i(1, 0)) != "", "in the air with nothing planned under it: refused")
	var low_plan := _board.place_block("brick", spot, Vector2i(1, 0))
	check(low_plan != null and _economy.plan_slot_at(spot) != null, "the lower block is planned")
	var up_plan := _board.place_block("brick", up, Vector2i(1, 0))
	check(up_plan != null, "a block is planned on the plan (%s)" % _economy.last_error)
	var store := _economy.place_stockpile(base + Vector3i(2, 0, 10))
	store.add(Resources.Kind.BRICK, 4)
	var order: Array[int] = []
	bricks.brick_placed.connect(func(b: BrickWorld.Brick) -> void: order.append(b.origin.y))
	_until(func() -> bool: return bricks.brick_count() == 2, 6000)
	check(bricks.brick_count() == 2 and order == [spot.y, up.y], "both are laid, the lower one first (%s)" % str(order))


func _step(n: int) -> void:
	for i in n:
		_board._process(DT)
		for u in _units.units:
			u._process(DT)


func _until(cond: Callable, max_ticks: int) -> int:
	var n := 0
	while not cond.call() and n < max_ticks:
		_step(1)
		n += 1
	return n
