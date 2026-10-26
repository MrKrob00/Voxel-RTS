extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- threads).
## Path searches on worker threads: the same answer as the search done at once, and no harm done while the main thread keeps changing
## the ground, the bricks and the buildings under them.

const FLAT := 20

var _world: VoxelWorld
var _bricks: BrickWorld
var _nav: Navigation
var _economy: Economy


func run() -> void:
	_world = ctx.world
	_bricks = BrickWorld.new()
	add(_bricks)
	_bricks.setup(_world)
	_economy = Economy.new()
	add(_economy)
	_economy.setup(_world, _bricks)
	_nav = Navigation.new(_world, _bricks)
	_nav.obstacle = _economy.blocks_cell
	_nav.obstacle_source = _economy
	var sp := _world.spawn_point()
	var base := Vector3i(sp.x - 10, sp.y + 1, sp.z - 10)
	for dz in FLAT:
		for dx in FLAT:
			for y in range(sp.y - 2, sp.y + 6):
				_world.set_block(Vector3i(base.x + dx, y, base.z + dz), Blocks.make(Blocks.GRASS) if y == sp.y else (Blocks.make(Blocks.DIRT) if y < sp.y else Blocks.AIR))
	_nav.threaded = false
	var a := base + Vector3i(1, 0, 1)
	var b := base + Vector3i(18, 0, 17)
	var reference := _nav.find_path(a, b)
	check(reference.size() > 15 and reference[-1] == b, "the search done at once finds the way (%d cells)" % reference.size())

	# The same search on a thread.
	_nav.threaded = true
	check(_nav.use_threads(), "searches are given to threads")
	var s := _nav.begin_search(a, b)
	_nav.run_search(s, 3000)
	check(s.threaded and not s.done or s.done, "the search is on its way")
	await _until_done([s])
	check(s.done and s.reached and s.path == reference, "a thread finds the very same way (%d cells)" % s.path.size())

	# A wall of bricks and a crate appear between two searches: the second one goes round them.
	for z in range(base.z + 4, base.z + 16):
		_bricks.place(Vector3i(base.x + 9, base.y, z), 1, BrickWorld.Kind.STONE, 1)
	var walled := _nav.begin_search(a, b)
	_nav.run_search(walled, 3000)
	await _until_done([walled])
	var blocked_cells := 0
	for c in walled.path:
		if _bricks.occupied(c):
			blocked_cells += 1
	check(walled.done and blocked_cells == 0 and walled.path.size() > reference.size(), "a search made after bricks were placed goes round them (%d > %d cells)" % [walled.path.size(), reference.size()])

	# Many searches while the ground, the bricks and the buildings are changed from here.
	var searches: Array[PathSearch] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 24:
		var from := base + Vector3i(rng.randi_range(0, 19), 0, rng.randi_range(0, 19))
		var to := base + Vector3i(rng.randi_range(0, 19), 0, rng.randi_range(0, 19))
		var q := _nav.begin_search(from, to)
		_nav.run_search(q, 3000)
		searches.append(q)
		for k in 6:
			var p := base + Vector3i(rng.randi_range(0, 19), -1, rng.randi_range(0, 19))
			_world.set_block(p, Blocks.make(Blocks.DIRT) if rng.randf() < 0.5 else Blocks.AIR)
		await tree.process_frame
	await _until_done(searches)
	var all_done := true
	for q in searches:
		all_done = all_done and q.done
	check(all_done, "twenty-four searches finished while the ground was being changed under them")
	# Open sky gets its first block while searches are running: the array of the chunk is made without them reading it.
	var sky := Vector3i(base.x + 2, sp.y + 12, base.z + 2)
	var running := _nav.begin_search(a, b)
	_nav.run_search(running, 3000)
	check(_world.set_block(sky, Blocks.make(Blocks.STONE)) and _world.get_block(sky) == Blocks.make(Blocks.STONE), "the first block in a chunk of open sky is put while a search runs")
	await _until_done([running])
	check(running.done, "and the search ends all the same")


func _until_done(list: Array, max_frames := 1200) -> void:
	var n := 0
	while n < max_frames:
		var all := true
		for q in list:
			all = all and q.done
		if all:
			return
		await tree.process_frame
		n += 1
