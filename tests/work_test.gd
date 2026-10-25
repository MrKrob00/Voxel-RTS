extends SceneTree
## Headless: godot --headless --path . -s res://tests/work_test.gd
## Stockpile rules and the dig / carry / put-down loop of workers, stepped by hand with a fixed time step.

var _failed := false
var _world: VoxelWorld
var _units: UnitManager
var _board: TaskBoard
var _economy: Economy


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _init() -> void:
	_world = VoxelWorld.new()
	_world.extra_islands = 0
	root.add_child(_world)
	while not _world.is_ready():
		await process_frame
	var bricks := BrickWorld.new()
	root.add_child(bricks)
	bricks.setup(_world)
	_units = UnitManager.new()
	root.add_child(_units)
	_units.setup(_world, bricks)
	_economy = Economy.new()
	root.add_child(_economy)
	_economy.setup(_world, bricks)
	_board = TaskBoard.new()
	root.add_child(_board)
	_board.setup(_world, _units.nav, _economy)
	for n in [_units, _board]:
		n.process_mode = Node.PROCESS_MODE_DISABLED   # stepped by hand below

	var sp := _world.spawn_point()
	_flatten(Vector3i(sp.x - 12, sp.y, sp.z - 12), 20, 20)   # a pad to work on
	var base := Vector3i(sp.x - 12, sp.y + 1, sp.z - 12)
	_stockpile_rules(bricks, base)
	await _dig_and_haul(base)
	await _no_stockpile(base)
	var waited := 0
	while not _world.is_settled() and waited < 3000:
		await process_frame
		waited += 1
	quit(1 if _failed else 0)


## Level ground `w` x `d` columns from `corner` (y = surface): whole stone-and-grass blocks, air above.
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


func _step(frames: int, dt := 0.05) -> void:
	for i in frames:
		_board._process(dt)
		for u in _units.units:
			u._process(dt)


func _stockpile_rules(bricks: BrickWorld, base: Vector3i) -> void:
	var at := base + Vector3i(2, 0, 2)
	_check(Stockpile.can_place(_world, bricks, at) == "", "a stockpile fits on flat ground")
	_check(Stockpile.can_place(_world, bricks, base + Vector3i(0, 5, 0)) != "", "...not in mid-air")
	var s := _economy.place_stockpile(at)
	_check(s != null and _economy.stockpiles.size() == 1, "placed")
	_check(_economy.place_stockpile(at + Vector3i(1, 0, 1)) == null and _economy.last_error.contains("overlaps"), "...not over another one")
	var bump := base + Vector3i(8, 0, 2)
	_world.terrain.dig_step(bump + Vector3i(1, -1, 1))   # one corner half dug
	_check(Stockpile.can_place(_world, bricks, bump) != "", "...not over a half-dug block")
	var brick_at := base + Vector3i(12, 0, 2)
	bricks.place(brick_at + Vector3i(1, 0, 1), 0, BrickWorld.Kind.STONE, 1)
	_check(Stockpile.can_place(_world, bricks, brick_at) != "", "...not where a brick stands")
	_check(s.add(Resources.Kind.STONE, 5) == 5 and s.add(Resources.Kind.DIRT, 100) == Stockpile.CAPACITY - 5, "it takes bags until it is full")
	_check(s.free_space() == 0 and s.add(Resources.Kind.STONE, 1) == 0, "...and then refuses more")
	_check(s.take(Resources.Kind.STONE, 3) == 3 and s.free_space() == 3, "bags can be taken out again")
	_economy.remove_stockpile(s)
	_check(_economy.stockpiles.is_empty(), "removed")


func _dig_and_haul(base: Vector3i) -> void:
	var pile := _economy.place_stockpile(base + Vector3i(2, 0, 2))
	var crew := _units.spawn_squad(base + Vector3i(4, 0, 4), 2, 1)
	var rect := Vector3i(base.x + 10, 0, base.z + 10)
	var task := _board.create_dig(rect.x, rect.z, rect.x + 1, rect.z + 1)
	_check(task != null and task.cell_count() == 4, "marking 2 x 2 columns makes a task of 4 blocks")
	var before := {}
	for c in task.cells:
		before[c] = _world.get_block(c)
	for u in crew:
		_board.assign(u, task)
	_check(task.workers.size() == 2, "two workers on it")
	_step(5)
	_check(task.cells.values().any(func(v: Variant) -> bool: return v != null), "they claim blocks")
	var seen_half := false
	var seen_carry := false
	var frames := 0
	while not _board.tasks.is_empty() and frames < 20000:
		_step(1)
		frames += 1
		for c in before:
			if Blocks.is_dug(_world.get_block(c)):
				seen_half = true
		for u in crew:
			seen_carry = seen_carry or u.carried_amount() > 0
	_check(_board.tasks.is_empty(), "the task finishes by itself (%.0f s)" % (frames * 0.05))
	_check(seen_half, "blocks went through the half-dug stage")
	_check(seen_carry, "workers carried bags")
	var all_gone := true
	for c in before:
		all_gone = all_gone and _world.get_block(c) == Blocks.AIR
	_check(all_gone, "all four blocks are gone")
	_step(400)   # the last bags are still on their way
	_check(pile.amount(Resources.Kind.DIRT) == 8, "each of the 8 stages put one bag of earth on the stockpile (%d)" % pile.amount(Resources.Kind.DIRT))
	var empty_handed := true
	for u in crew:
		empty_handed = empty_handed and u.carried_amount() == 0
		_check(u.is_idle() and u.status == "", "a worker is idle and well again")
	_check(empty_handed, "nobody keeps a bag")


func _no_stockpile(base: Vector3i) -> void:
	for s in _economy.stockpiles.duplicate():
		_economy.remove_stockpile(s)
	var worker := _units.spawn(base + Vector3i(5, 0, 12))
	var task := _board.create_dig(base.x + 14, base.z + 14, base.x + 14, base.z + 14)
	_board.assign(worker, task)
	_step(400)
	_check(worker.carried_amount() == 1 and worker.status == "No free stockpile", "with no stockpile the worker holds its bag and says so (\"%s\")" % worker.status)
	var pile := _economy.place_stockpile(base + Vector3i(2, 0, 6))
	_step(800)
	_check(pile != null and pile.amount(Resources.Kind.DIRT) >= 1, "once a stockpile exists it brings the bag there")
	# A worker taken off the task drops the job (and keeps nothing claimed).
	var t2 := _board.create_dig(base.x + 16, base.z + 16, base.x + 17, base.z + 16)
	_board.assign(worker, t2)
	_step(10)
	_board.unassign(worker)
	var claimed := t2.cells.values().any(func(v: Variant) -> bool: return v != null)
	_check(not claimed and t2.workers.is_empty(), "unassigning releases the block it had claimed")
