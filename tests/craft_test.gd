extends SceneTree
## Headless: godot --headless --path . -s res://tests/craft_test.gd
## Felling a tree (3 logs as physics bodies), carrying logs, the stump that makes planks, cutting grass, the rope machine.
## Stepped on the physics clock (logs are rigid bodies), the units and the board by hand with the same time step.

const DT := 1.0 / 60.0

var _failed := false
var _world: VoxelWorld
var _units: UnitManager
var _board: TaskBoard
var _economy: Economy
var _loose: LooseItems
var _props: PropField


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _init() -> void:
	Engine.time_scale = 4.0
	_world = VoxelWorld.new()
	_world.extra_islands = 0
	root.add_child(_world)
	var colliders := GroundColliders.new()
	root.add_child(colliders)
	colliders.setup(_world)
	var bricks := BrickWorld.new()
	root.add_child(bricks)
	bricks.setup(_world, colliders)
	_loose = LooseItems.new()
	root.add_child(_loose)
	_loose.setup(_world, colliders)
	_props = PropField.new()
	root.add_child(_props)
	_props.setup(_world)
	_units = UnitManager.new()
	root.add_child(_units)
	_units.setup(_world, bricks)
	_economy = Economy.new()
	root.add_child(_economy)
	_economy.setup(_world, bricks)
	_units.nav.obstacle = _economy.blocks_cell
	_board = TaskBoard.new()
	root.add_child(_board)
	_board.setup(_world, _units.nav, _economy, _props, _loose, _units)
	for n in [_units, _board]:
		n.process_mode = Node.PROCESS_MODE_DISABLED   # stepped by hand
	while not _world.is_ready() or not _props.is_built():
		await process_frame

	var sp := _world.spawn_point()
	_flatten(Vector3i(sp.x - 12, sp.y, sp.z - 12), 20, 14)
	var base := Vector3i(sp.x - 12, sp.y + 1, sp.z - 12)
	var logs_pile := _economy.place_stockpile(base + Vector3i(2, 0, 2), Stockpile.Style.PLATFORM)
	var planks_pile := _economy.place_stockpile(base + Vector3i(2, 0, 6), Stockpile.Style.PLATFORM)
	var ropes_pile := _economy.place_stockpile(base + Vector3i(14, 0, 6), Stockpile.Style.PLATFORM)
	var grass_frame := _economy.place_stockpile(base + Vector3i(6, 0, 2), Stockpile.Style.FRAME)
	_check(logs_pile != null and planks_pile != null and ropes_pile != null and grass_frame != null, "four stockpiles are down")
	var crew := _units.spawn_squad(base + Vector3i(8, 0, 8), 2, 1)

	await _felling(logs_pile, crew, sp)
	await _stump(logs_pile, planks_pile, base)
	await _grass_and_rope(grass_frame, planks_pile, ropes_pile, crew, base, sp)
	Engine.time_scale = 1.0
	var waited := 0
	while not _world.is_settled() and waited < 3000:
		await process_frame
		waited += 1
	quit(1 if _failed else 0)


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
		await physics_frame
		_board._process(DT)
		for u in _units.units:
			u._process(DT)


func _until(cond: Callable, max_ticks: int) -> int:
	var ticks := 0
	while not cond.call() and ticks < max_ticks:
		await _tick()
		ticks += 1
	return ticks


func _felling(pile: Stockpile, crew: Array, sp: Vector3i) -> void:
	# The tree nearest to the spawn that stands alone (no other tree within a block and a half).
	var best := -1
	var best_d := INF
	for i in _props.trees.size():
		var o := _props.trees[i].origin
		var d := Vector2(o.x - sp.x, o.z - sp.z).length()
		if d < best_d and d > 14.0 and _props.trees_in_rect(Rect2(o.x - 1.5, o.z - 1.5, 3, 3)).size() == 1:
			best = i
			best_d = d
	_check(best >= 0, "there is a lone tree to fell (%.0f blocks from the spawn)" % best_d)
	var tree := _props.trees[best].origin
	var task := _board.create_harvest(HarvestTask.Kind.TREES, Rect2(tree.x - 0.5, tree.z - 0.5, 1.0, 1.0))
	_check(task != null and task.targets.size() == 1, "marking one tree makes a task with one target")
	for u in crew:
		_board.assign(u, task)
	var ticks := await _until(func() -> bool: return _loose.logs.size() == 3 and _props.tree_alive[best] == 0, 60 * 40)
	_check(_props.tree_alive[best] == 0, "the tree is felled")
	_check(_loose.logs.size() == 3 or pile.count > 0, "it dropped logs: three rigid bodies (%d on the ground, %d stored)" % [_loose.logs.size(), pile.count])
	for l in _loose.logs:
		_check(l.global_position.y > sp.y - 2.0, "a log landed on the ground instead of falling through (y %.1f, ground %d)" % [l.global_position.y, sp.y])
	var seen_log_on_back := [false]
	var done := func() -> bool:
		for u in crew:
			if u.carried_kind() == Resources.Kind.LOG:
				seen_log_on_back[0] = true
		return not _board.tasks.has(task)
	ticks += await _until(done, 60 * 120)
	_check(not _board.tasks.has(task), "the task is over: tree and logs dealt with (%.0f s)" % (ticks * DT))
	_check(seen_log_on_back[0], "a worker carried a log on the back")
	_check(pile.holding == Resources.Kind.LOG and pile.count == 3 and _loose.logs.is_empty(), "three logs are on the platform and none lie about (%d)" % pile.count)


func _stump(logs_pile: Stockpile, planks_pile: Stockpile, base: Vector3i) -> void:
	var stump := _board.place_station(Station.Kind.STUMP, base + Vector3i(10, 0, 2))
	_check(stump != null, "a stump with an axe is set up (%s)" % _economy.last_error)
	_check(logs_pile.count == 2, "it cost one log (%d left)" % logs_pile.count)
	_check(_board.place_station(Station.Kind.STUMP, base + Vector3i(12, 0, 2)) != null, "a second stump is set up too")
	_check(logs_pile.count == 1, "...for another log")
	_economy.remove_station(_economy.stations[1])
	_board.remove_task(_board.tasks[-1]) if _board.tasks.size() > 1 and _board.tasks[-1].station == null else null
	var ticks := await _until(func() -> bool: return planks_pile.count == 3 and logs_pile.count == 0, 60 * 60)
	_check(planks_pile.holding == Resources.Kind.PLANK and planks_pile.count == 3, "idle units came by themselves and made 3 planks of the last log (%d) in %.0f s" % [planks_pile.count, ticks * DT])
	_check(logs_pile.count == 0 and logs_pile.holding == Resources.Kind.NONE, "the platform of logs is empty")
	await _tick(120)
	for u in _units.units:
		_check(u.is_idle() and u.carried_amount() == 0 and _board.task_of(u) == null, "a unit is free again with nothing in its hands")


func _grass_and_rope(frame: Stockpile, planks_pile: Stockpile, ropes_pile: Stockpile, crew: Array, base: Vector3i, sp: Vector3i) -> void:
	# Cut four tufts of grass: sacks into the frame.
	var picked: Array[int] = []
	for i in _props.tufts.size():
		var o := _props.tufts[i].origin
		if Vector2(o.x - sp.x, o.z - sp.z).length() > 10.0 and picked.size() < 4 and _props.tufts_in_rect(Rect2(o.x - 0.5, o.z - 0.5, 1.0, 1.0)).size() == 1:
			if picked.is_empty() or Vector2(o.x - _props.tufts[picked[0]].origin.x, o.z - _props.tufts[picked[0]].origin.z).length() < 12.0:
				picked.append(i)
	_check(picked.size() == 4, "four tufts of grass close together")
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
	_check(seen_sack[0] and frame.holding == Resources.Kind.PLANT and frame.count == 4, "four sacks of grass went into the frame (%d, %.0f s)" % [frame.count, ticks * DT])
	_check(not (_props.tuft_alive[picked[0]] == 1), "the tufts are gone from the ground")
	# The rope machine: costs two planks, takes two sacks of grass per rope.
	var machine := _board.place_station(Station.Kind.ROPE_MACHINE, base + Vector3i(10, 0, 6))
	_check(machine != null and planks_pile.count == 1, "the rope machine is set up for two planks (%d left)" % planks_pile.count)
	ticks = await _until(func() -> bool: return ropes_pile.count == 2 and frame.count == 0, 60 * 90)
	_check(ropes_pile.holding == Resources.Kind.ROPE and ropes_pile.count == 2, "two ropes were made of four sacks of grass (%d, %.0f s)" % [ropes_pile.count, ticks * DT])
	await _tick(120)
	var all_free := true
	for u in _units.units:
		all_free = all_free and u.is_idle() and u.carried_amount() == 0
	_check(all_free, "all units are free again")
