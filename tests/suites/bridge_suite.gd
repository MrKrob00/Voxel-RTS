extends TestSuite
## Suite of tests/run_suites.gd (-- bridge). The rope bridge: what can be built (a gap, not flat ground), what it costs, the planks laid
## one after another from the near end, a floor to walk on that follows the arc.

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

	# A small platform: flat grass, with a trench three blocks wide and two deep across the middle (the gap of the bridge).
	var sp := _world.spawn_point()
	var base := Vector3i(sp.x - 8, sp.y + 1, sp.z - 8)   # the feet cell of the corner of the platform
	for dz in 12:
		for dx in 16:
			for y in range(sp.y - 3, sp.y + 6):
				var p := Vector3i(sp.x - 8 + dx, y, sp.z - 8 + dz)
				_world.set_block(p, Blocks.make(Blocks.GRASS) if y == sp.y else (Blocks.make(Blocks.DIRT) if y < sp.y else Blocks.AIR))
	for dz in 12:
		for dx in range(5, 9):   # the gap: four blocks along x
			for y in range(sp.y - 1, sp.y + 1):
				_world.set_block(Vector3i(sp.x - 8 + dx, y, sp.z - 8 + dz), Blocks.AIR)
	var a := base + Vector3i(4, 0, 3)
	var b := base + Vector3i(9, 0, 3)

	# What can be built.
	var res := BridgePlan.check(_world, _units.nav, [], a, b, 1)
	check(res.ok and res.count == 4, "over a gap of four blocks a bridge of four pieces can be built (%s)" % res.why)
	check(not BridgePlan.check(_world, _units.nav, [], base + Vector3i(1, 0, 3), base + Vector3i(3, 0, 3), 1).ok, "on flat ground it cannot (nothing under it)")
	check(not BridgePlan.check(_world, _units.nav, [], a, base + Vector3i(4, 0, 9), 1).ok, "not to a point that is not on its line")
	check(not BridgePlan.check(_world, _units.nav, [], a, a + Vector3i(1, 0, 0), 1).ok, "not between two cells that touch")
	check(BridgePlan.layers(5, 5, 4) == PackedInt32Array([5, 5, 5, 5]) and BridgePlan.layers(5, 9, 3) == PackedInt32Array([6, 7, 8]), "the height of the pieces follows the line between the ends")

	# The plan: planks pay four blocks each; it joins the building job.
	var plan := _board.place_bridge(a, b, 1)
	check(plan != null and plan.count == 4 and plan.cost == {Resources.Kind.PLANK: 1}, "a bridge of four blocks asks for one plank")
	var jobs := _board.tasks.filter(func(t: WorkTask) -> bool: return t is BuildTask)
	check(jobs.size() == 1 and jobs[0].blueprints.has(plan), "it is a plan of the building job")
	check(_board.place_bridge(a + Vector3i(0, 0, 1), b + Vector3i(0, 0, 1), 1) == null, "a second bridge over the first one's lane is refused")
	var long := _board.place_bridge(base + Vector3i(1, 0, 8), base + Vector3i(14, 0, 8), 1)
	check(long == null, "over twelve blocks is refused (%s)" % _economy.last_error)

	# The planks come, a unit lays them one by one from the end it comes from.
	var bank := _economy.place_stockpile(base + Vector3i(1, 0, 8))
	bank.add(Resources.Kind.PLANK, 3)
	var crew := _units.spawn_squad(base + Vector3i(1, 0, 5), 1, 1)
	var order: Array[int] = []
	var seen_floor := [false]
	_until(func() -> bool:
		if order.is_empty() or order[-1] != plan.placed:
			order.append(plan.placed)
		return plan.finished, 6000)
	check(plan.finished and plan.placed == 4, "all four pieces are laid (%d)" % plan.placed)
	check(order.size() >= 4, "they were laid one after another, not all at once (%s)" % str(order))
	check(plan.from_end == 0, "from the end the unit came from")
	check(_economy.bridges.has(plan) and not _economy.blueprints.has(plan) and _board.tasks.filter(func(t: WorkTask) -> bool: return t is BuildTask).is_empty(), "the plan is a bridge now and the job is gone")
	check(_economy.stock_of(Resources.Kind.PLANK) == 2, "it cost one plank (%d left)" % _economy.stock_of(Resources.Kind.PLANK))

	# A floor: the feet cell over a plank is standable, the arc lowers the feet in the middle, the ends are level with the ground.
	var mid := a + Vector3i(2, 0, 0)
	check(_units.nav.standable(mid) and _units.nav.standable(mid + Vector3i(0, 0, 1)), "both lanes are floors")
	var h_end := _units.nav.feet_height(a + Vector3i(1, 0, 0), a.x + 1.5, a.z + 0.5)
	var h_mid := _units.nav.feet_height(mid, mid.x + 0.5, mid.z + 0.5)
	check(h_mid < h_end and h_mid > a.y - 1.0, "the feet hang in the middle (%.2f against %.2f)" % [h_mid, h_end])
	check(_units.nav.find_path(a, b).size() > 0, "a path leads across")


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
