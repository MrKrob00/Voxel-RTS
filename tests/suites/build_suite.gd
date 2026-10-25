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
	var bank := _economy.place_stockpile(base + Vector3i(2, 0, 2), Stockpile.Style.PLATFORM)
	var logbank := _economy.place_stockpile(base + Vector3i(2, 0, 7), Stockpile.Style.PLATFORM)
	var crew := _units.spawn_squad(base + Vector3i(8, 0, 5), 2, 1)

	# A stockpile blueprint costs three planks.
	var plan := _board.place_blueprint("stockpile", Stockpile.Style.PLATFORM, base + Vector3i(10, 0, 2))
	check(plan != null and plan.cost == {Resources.Kind.PLANK: 3}, "a blueprint of a stockpile asks for three planks")
	check(_economy.stockpiles.size() == 2 and _economy.blueprints.size() == 1, "nothing is built yet, only planned")
	check(_board.place_blueprint("stockpile", Stockpile.Style.CRATE, base + Vector3i(11, 0, 3)) == null and _economy.last_error.contains("overlaps"), "a second plan cannot overlap the first (%s)" % _economy.last_error)
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
	_until(func() -> bool: return not _economy.stations.is_empty(), 3000)
	check(_economy.stations.size() == 1 and _economy.stations[0].task != null, "the stump stands and has its job")
	check(_economy.stock_of(Resources.Kind.LOG) == 0, "the log was used")

	# A plan can be cancelled.
	var third := _board.place_blueprint("station", Station.Kind.ROPE_MACHINE, base + Vector3i(12, 0, 8))
	var tasks_before := _board.tasks.size()
	_board.cancel_blueprint(third)
	check(_economy.blueprints.is_empty() and _board.tasks.size() == tasks_before - 1, "a cancelled plan goes with its job")


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
