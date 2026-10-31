extends TestSuite
## Suite of tests/run_suites.gd (-- furnace). The furnace: orders and slots, ore and amber brought in loads of three, ingots made one
## at a time and carried to a stockpile, the plan built of bricks.

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
	var base := Vector3i(sp.x - 8, sp.y + 1, sp.z - 8)
	for dz in 14:
		for dx in 18:
			for y in range(sp.y - 3, sp.y + 7):
				var p := Vector3i(sp.x - 8 + dx, y, sp.z - 8 + dz)
				_world.set_block(p, Blocks.make(Blocks.GRASS) if y == sp.y else (Blocks.make(Blocks.DIRT) if y < sp.y else Blocks.AIR))

	# The furnace: 3 x 2 on the ground, 3 high; turned a quarter it is 2 x 3.
	check(Furnace.footprint(0) == Vector2i(3, 2) and Furnace.footprint(1) == Vector2i(2, 3), "3 long, 2 wide, turned by its front")
	var furnace := _board.place_station(Station.Kind.FURNACE, base + Vector3i(4, 0, 3), false, 1) as Furnace
	check(furnace != null, "a furnace stands (%s)" % _economy.last_error)
	check(furnace.blocks(base + Vector3i(5, 2, 4)) and not furnace.blocks(base + Vector3i(5, 3, 4)) and not _units.nav.standable(base + Vector3i(5, 0, 4)), "three high, nobody walks through it")
	check(Furnace.can_place_at(_world, bricks, base + Vector3i(5, 0, 4), 1, [], _economy.stations) != "", "another one cannot overlap it")
	check(_board.tasks.any(func(t: WorkTask) -> bool: return t is FurnaceTask), "it has its job")

	# Orders take slots; eight at most; a tap takes one back.
	for i in 8:
		check(furnace.order(), "order %d" % (i + 1)) if i == 7 else furnace.order()
	check(not furnace.order() and furnace.free_slots() == 0, "the ninth is refused: all eight slots are taken")
	check(furnace.cancel_order() and furnace.queued == 7, "an order can be taken back")
	while furnace.cancel_order():
		pass
	check(furnace.queued == 0, "all of them")

	# Ingots: ore and amber come in threes, the furnace smelts by itself, the ingots go to a stockpile.
	var ore := _economy.place_stockpile(base + Vector3i(1, 0, 8))
	ore.add(Resources.Kind.IRON, 24)
	var ember := _economy.place_stockpile(base + Vector3i(5, 0, 8))
	ember.add(Resources.Kind.AMBER, 6)
	var shelf := _economy.place_stockpile(base + Vector3i(9, 0, 8))
	var crew := _units.spawn_squad(base + Vector3i(8, 0, 4), 2, 1)
	furnace.order()
	furnace.order()
	check(furnace.missing(Resources.Kind.IRON) == 20 and furnace.missing(Resources.Kind.AMBER) == 4, "two ingots need 20 ore and 4 amber")
	var most := [0]
	var seen_fire := [false]
	_until(func() -> bool:
		for u in crew:
			most[0] = maxi(most[0], u.carried_amount())
		seen_fire[0] = seen_fire[0] or furnace.smelting
		return _economy.stock_of(Resources.Kind.INGOT) == 2, 12000)
	check(most[0] == 3, "ore and amber are carried three at a time (%d)" % most[0])
	check(seen_fire[0], "the furnace burned")
	check(_economy.stock_of(Resources.Kind.INGOT) == 2 and shelf.holding == Resources.Kind.INGOT, "two ingots are on a stockpile")
	check(furnace.queued == 0 and furnace.made == 0 and furnace.free_slots() == 8, "the slots are free again")
	check(_economy.stock_of(Resources.Kind.IRON) == 4 and _economy.stock_of(Resources.Kind.AMBER) == 2, "20 ore and 4 amber were used")

	# The plan: 4 bricks (eight halves).
	var plan := _board.place_blueprint("station", Station.Kind.FURNACE, base + Vector3i(10, 0, 3), 0)
	check(plan != null and plan.cost == {Resources.Kind.BRICK: 8} and plan.size == Vector2i(3, 2), "a blueprint of a furnace asks for four bricks")


func _step(n: int) -> void:
	for i in n:
		_board._process(DT)
		for st in _economy.stations:
			if st is Furnace:
				st._process(DT)
		for u in _units.units:
			u._process(DT)


func _until(cond: Callable, max_ticks: int) -> int:
	var n := 0
	while not cond.call() and n < max_ticks:
		_step(1)
		n += 1
	return n
