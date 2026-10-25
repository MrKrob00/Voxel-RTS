extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- work).
## Stockpile rules and the dig / carry / put-down loop of workers, stepped by hand with a fixed time step.

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
	_economy.charge_for_stockpiles = false   # the scene is set up with stockpiles for free
	_board = TaskBoard.new()
	add(_board)
	_board.setup(_world, _units.nav, _economy, null, null, _units)
	for n in [_units, _board]:
		n.process_mode = Node.PROCESS_MODE_DISABLED   # stepped by hand below

	var sp := _world.spawn_point()
	_flatten(Vector3i(sp.x - 12, sp.y, sp.z - 12), 20, 20)   # a pad to work on
	var base := Vector3i(sp.x - 12, sp.y + 1, sp.z - 12)
	_stockpile_rules(bricks, base)
	_dig_and_haul(base)
	_earth_is_not_collected(base)
	_filter(base)
	_wrong_style(base)
	var waited := 0
	while not _world.is_settled() and waited < 3000:
		await tree.process_frame
		waited += 1


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


## Makes the surface of a block of columns into `material` (the pad is grass by default; digging needs stone or ore to carry).
func _surface_of(corner: Vector3i, w: int, d: int, material: int) -> void:
	for dz in d:
		for dx in w:
			_world.set_block(Vector3i(corner.x + dx, corner.y, corner.z + dz), Blocks.make(material))


func _stockpile_rules(bricks: BrickWorld, base: Vector3i) -> void:
	var at := base + Vector3i(2, 0, 2)
	check(Stockpile.can_place(_world, bricks, at) == "", "a stockpile fits on flat ground")
	check(Stockpile.can_place(_world, bricks, base + Vector3i(0, 5, 0)) != "", "...not in mid-air")
	var s := _economy.place_stockpile(at)
	check(s != null and _economy.stockpiles.size() == 1, "placed")
	check(_economy.place_stockpile(at + Vector3i(1, 0, 1)) == null and _economy.last_error.contains("overlaps"), "...not over another one")
	var bump := base + Vector3i(8, 0, 2)
	_world.terrain.dig_step(bump + Vector3i(1, -1, 1))   # one corner half dug
	check(Stockpile.can_place(_world, bricks, bump) != "", "...not over a half-dug block")
	var brick_at := base + Vector3i(12, 0, 2)
	bricks.place(brick_at + Vector3i(1, 0, 1), 0, BrickWorld.Kind.STONE, 1)
	check(Stockpile.can_place(_world, bricks, brick_at) != "", "...not where a brick stands")
	# It takes any kind, one kind at a time.
	check(s.accepts(Resources.Kind.IRON) and s.accepts(Resources.Kind.LOG) and s.accepts(Resources.Kind.STONE), "a stockpile takes logs, planks, rope, ore, stone and grass")
	check(s.add(Resources.Kind.IRON, 5) == 5 and not s.accepts(Resources.Kind.COAL) and s.add(Resources.Kind.COAL, 1) == 0, "it holds one kind at a time")
	check(s.add(Resources.Kind.IRON, 100) == s.capacity_for(Resources.Kind.IRON) - 5 and s.free_space() == 0, "it takes bags until it is full")
	check(s.take(Resources.Kind.IRON, 3) == 3 and s.free_space() == 3, "bags can be taken out again")
	s.take(Resources.Kind.IRON, 100)
	check(s.holding == Resources.Kind.NONE and s.accepts(Resources.Kind.COAL), "once empty it takes another kind")
	_economy.remove_stockpile(s)
	check(_economy.stockpiles.is_empty(), "removed")
	var crate := _economy.place_stockpile(at)
	check(crate.form() == Stockpile.Form.PLATFORM and not crate.blocks(at + Vector3i(1, 1, 1)), "an empty stockpile is a platform")
	crate.add(Resources.Kind.STONE, 1)
	check(crate.form() == Stockpile.Form.CRATE and crate.capacity() == 16 and Stockpile.BAGS_PER_BRICK * 4 == crate.capacity(), "with stone in it it is a crate of 2 x 2 x 2 blocks: 16 bags, 4 bricks of 4 bags")
	check(crate.blocks(at + Vector3i(1, 1, 1)) and not crate.blocks(at + Vector3i(0, 2, 0)) and not crate.blocks(at + Vector3i(2, 0, 0)), "a crate is solid, two blocks high")
	crate.take(Resources.Kind.STONE, 1)
	check(crate.form() == Stockpile.Form.PLATFORM and not crate.blocks(at + Vector3i(1, 1, 1)), "emptied, it is a platform again")
	_economy.remove_stockpile(crate)
	var plat := _economy.place_stockpile(at)
	check(not plat.blocks(at), "a platform can be walked over")
	check(plat.capacity_for(Resources.Kind.LOG) == 4 and plat.capacity_for(Resources.Kind.ROPE) == 20 and plat.capacity_for(Resources.Kind.PLANK) == 24, "a platform holds 4 logs, 24 planks or 20 ropes")
	check(plat.add(Resources.Kind.LOG, 9) == 4 and not plat.accepts(Resources.Kind.LOG), "the fifth log does not fit")
	plat.take(Resources.Kind.LOG, 4)
	check(plat.add(Resources.Kind.ROPE, 30) == 20, "twenty ropes fit: a quarter of the area and a fifth of the height each")
	_economy.remove_stockpile(plat)
	# What a stockpile costs when put down at once: three planks in a stockpile (units bring them to a blueprint instead).
	var bank := _economy.place_stockpile(at)
	_economy.charge_for_stockpiles = true
	var refused := _economy.place_stockpile(at + Vector3i(4, 0, 0))
	check(refused == null and _economy.last_error.contains("3 plank"), "a stockpile needs three planks in a stockpile (%s)" % _economy.last_error)
	bank.add(Resources.Kind.PLANK, 5)
	var paid := _economy.place_stockpile(at + Vector3i(4, 0, 0))
	check(paid != null and bank.count == 2, "with planks it is paid for: 3 of the 5 are gone (%d left)" % bank.count)
	_economy.charge_for_stockpiles = false
	_economy.remove_stockpile(bank)
	_economy.remove_stockpile(paid)
	check(Resources.carry_capacity(Resources.Kind.PLANK) == 3 and Resources.carry_capacity(Resources.Kind.LOG) == 1, "a unit carries three planks or one log at a time")
	check(Resources.from_block(Blocks.GRASS) == Resources.Kind.NONE and Resources.from_block(Blocks.DIRT) == Resources.Kind.NONE and Resources.from_block(Blocks.STONE) == Resources.Kind.STONE, "earth gives nothing, stone gives stone")


func _run_task(task: DigTask, crew: Array, limit := 20000) -> int:
	for u in crew:
		_board.assign(u, task)
	var frames := 0
	while _board.tasks.has(task) and frames < limit:
		_step(1)
		frames += 1
	return frames


func _dig_and_haul(base: Vector3i) -> void:
	# Stone ground to dig: 2 x 4 columns = 8 blocks = 16 bags, exactly one frame full.
	var quarry := base + Vector3i(10, 0, 10)
	_surface_of(quarry, 2, 4, Blocks.STONE)
	var frame := _economy.place_stockpile(base + Vector3i(2, 0, 2))
	var crew := _units.spawn_squad(base + Vector3i(5, 0, 5), 2, 1)
	var task := _board.create_dig(quarry.x, quarry.z, quarry.x + 1, quarry.z + 3)
	check(task != null and task.cell_count() == 8, "marking 2 x 4 columns makes a task of 8 blocks")
	var before := {}
	for c in task.cells:
		before[c] = _world.get_block(c)
	var seen_half := false
	var seen_carry := false
	for u in crew:
		_board.assign(u, task)
	check(task.workers.size() == 2, "two workers on it")
	_step(5)
	check(task.cells.values().any(func(v: Variant) -> bool: return v != null), "they claim blocks")
	var frames := 0
	while _board.tasks.has(task) and frames < 30000:
		_step(1)
		frames += 1
		for c in before:
			seen_half = seen_half or Blocks.is_dug(_world.get_block(c))
		for u in crew:
			seen_carry = seen_carry or u.carried_amount() > 0
	check(not _board.tasks.has(task), "the task finishes by itself (%.0f s)" % (frames * 0.05))
	check(seen_half and seen_carry, "blocks went through the half-dug stage and workers carried bags")
	var all_gone := true
	for c in before:
		all_gone = all_gone and _world.get_block(c) == Blocks.AIR
	check(all_gone, "all eight blocks are gone")
	var stack: Stockpile = frame
	check(_economy.stockpiles.has(frame) and frame.form() == Stockpile.Form.STACK, "the crate, filled to the brim with stone, has become a stack of bricks: the same stockpile")
	check(_economy.packed_bricks == 4, "...4 stone bricks (%d)" % _economy.packed_bricks)
	check(stack != null and stack.holding == Resources.Kind.BRICK and stack.count == 8, "it holds 8 halves: 4 bricks of 2x1x1, two layers of two")
	check(stack != null and stack.blocks(Vector3i(base.x + 3, base.y + 1, base.z + 3)), "the stack is a solid block 2 x 2 x 2")
	_economy.remove_stockpile(stack)
	for u in crew:
		check(u.carried_amount() == 0 and u.is_idle() and u.status == "", "a worker is idle, empty-handed and well")


func _bricks_at(cell: Vector3i) -> bool:
	return _economy.bricks.occupied(cell)


func _earth_is_not_collected(base: Vector3i) -> void:
	var pile := _economy.place_stockpile(base + Vector3i(2, 0, 8))
	var worker := _units.spawn(base + Vector3i(4, 0, 8))
	var task := _board.create_dig(base.x + 14, base.z + 2, base.x + 15, base.z + 3)   # grass
	var carried := [false]
	var frames := 0
	_board.assign(worker, task)
	while _board.tasks.has(task) and frames < 20000:
		_step(1)
		frames += 1
		carried[0] = carried[0] or worker.carried_amount() > 0
	check(not _board.tasks.has(task) and not carried[0] and pile.count == 0, "grass and earth are broken and gone: nothing is carried, nothing is stored (%d s)" % int(frames * 0.05))
	_economy.remove_stockpile(pile)


func _filter(base: Vector3i) -> void:
	# A quarry that brings iron only: the stone it breaks on the way is thrown away.
	var spot := base + Vector3i(14, 0, 8)
	_surface_of(spot, 2, 2, Blocks.STONE)
	_world.set_block(spot + Vector3i(0, 0, 0), Blocks.make(Blocks.IRON))
	_world.set_block(spot + Vector3i(1, 0, 1), Blocks.make(Blocks.IRON))
	var pile := _economy.place_stockpile(base + Vector3i(2, 0, 11))
	var frame := _economy.place_stockpile(base + Vector3i(6, 0, 11))
	var worker := _units.spawn(base + Vector3i(12, 0, 8))
	var task := _board.create_dig(spot.x, spot.z, spot.x + 1, spot.z + 1)
	task.collect[Resources.Kind.STONE] = false
	_run_task(task, [worker])
	_step(300)
	var holder := pile if pile.count > 0 else frame
	check(holder.holding == Resources.Kind.IRON and holder.count == 4, "iron (2 blocks, 4 bags) went to a stockpile (%d)" % holder.count)
	check(_economy.stock_of(Resources.Kind.STONE) == 0, "the stone was thrown away, none reached a stockpile")
	_economy.remove_stockpile(pile)
	_economy.remove_stockpile(frame)


func _wrong_style(base: Vector3i) -> void:
	# The only stockpile holds iron already: stone has nowhere to go, the worker holds it and says so.
	var pile := _economy.place_stockpile(base + Vector3i(2, 0, 14))
	pile.add(Resources.Kind.IRON, 1)
	var spot := base + Vector3i(14, 0, 13)
	_surface_of(spot, 1, 1, Blocks.STONE)
	var worker := _units.spawn(base + Vector3i(12, 0, 13))
	var task := _board.create_dig(spot.x, spot.z, spot.x, spot.z)
	_board.assign(worker, task)
	_step(400)
	check(worker.carried_amount() == 1 and worker.status.contains("No free stockpile for stone"), "stone with only a stockpile of iron around: the worker keeps the bag (\"%s\")" % worker.status)
	var frame := _economy.place_stockpile(base + Vector3i(6, 0, 14))
	_step(800)
	check(frame.holding == Resources.Kind.STONE and frame.count >= 1, "once an empty stockpile exists it brings the bag there")
	var t2 := _board.create_dig(base.x + 16, base.z + 16, base.x + 17, base.z + 16)
	_board.assign(worker, t2)
	_step(10)
	_board.unassign(worker)
	var claimed := t2.cells.values().any(func(v: Variant) -> bool: return v != null)
	check(not claimed and t2.workers.is_empty(), "unassigning releases the block it had claimed")
	_economy.remove_stockpile(pile)
	_economy.remove_stockpile(frame)
