extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- stump).
## The stump on a small flat pad: a log in somebody's hands goes to a free stump before any stockpile, and planks that have nowhere to
## go stay on the stump (nobody takes them up) until a stockpile has room, when somebody carries them there.

const DT := 1.0 / 60.0

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
	var planks_pile := _economy.place_stockpile(base + Vector3i(2, 0, 2))
	var stump := _board.place_station(Station.Kind.STUMP, base + Vector3i(10, 0, 4), false)
	check(stump != null, "a stump is set up (%s)" % _economy.last_error)

	# 1. A worker with a log in its hands, on some other job, goes to the free stump first; the planks go to the stockpile.
	var carrier := _units.spawn_squad(base + Vector3i(6, 0, 8), 1, 0)[0]
	carrier.carry(Resources.Kind.LOG, 1)
	var other := HarvestTask.new(HarvestTask.Kind.GRASS)
	_board.add_task(other)
	_board.assign(carrier, other)
	var went := [false]
	_until(func() -> bool:
		went[0] = went[0] or _board.task_of(carrier) == stump.task
		return _economy.stock_of(Resources.Kind.PLANK) == 3, 60 * 60)
	check(went[0] and _economy.stock_of(Resources.Kind.PLANK) == 3 and carrier.carried_amount() == 0, "a log in the hands went to the free stump and the planks to the stockpile (%d planks)" % _economy.stock_of(Resources.Kind.PLANK))
	_board.remove_task(other)
	_step(180)
	check(carrier.is_idle() and carrier.carried_amount() == 0, "the worker is free again")

	# 2. Planks with nowhere to go stay on the stump. A log is brought; while the unit works the stockpile fills up.
	planks_pile.take(Resources.Kind.PLANK, 3)
	var log_pile := _economy.place_stockpile(base + Vector3i(2, 0, 7))
	log_pile.add(Resources.Kind.LOG, 2)   # one is made into planks, the other keeps this stockpile a log store (no room for planks)
	var working := [false]
	_until(func() -> bool:
		working[0] = carrier.progress >= 0.0
		return working[0], 60 * 40)
	check(working[0], "the stump is at work")
	planks_pile.add(Resources.Kind.PLANK, 12)   # no room for the planks any more
	_step(60 * 20)
	check(stump.waiting == 3 and carrier.carried_amount() == 0 and carrier.is_idle(), "the planks lie on the stump, nobody took them up (%d lie there)" % stump.waiting)
	var idle_all := true
	for u in _units.units:
		idle_all = idle_all and u.carried_amount() == 0
	check(idle_all, "nobody holds planks with nowhere to put them")

	# 3. Room appears: somebody carries the planks away.
	planks_pile.take(Resources.Kind.PLANK, 12)
	_until(func() -> bool: return stump.waiting == 0 and _economy.stock_of(Resources.Kind.PLANK) == 3, 60 * 40)
	check(stump.waiting == 0 and _economy.stock_of(Resources.Kind.PLANK) == 3, "when there is room a unit took the planks from the stump to the stockpile (%d there)" % _economy.stock_of(Resources.Kind.PLANK))


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
