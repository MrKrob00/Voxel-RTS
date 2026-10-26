extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- navbits).
## The cache of what the ground says about standing (NavBits) gives the same answers as the blocks themselves, also after blocks,
## bricks and buildings were changed.

var _world: VoxelWorld
var _nav: Navigation
var _bricks: BrickWorld
var _economy: Economy


func run() -> void:
	_world = ctx.world
	var waited := 0
	while not _world.nav_bits.ready and waited < 3000:
		await tree.process_frame
		waited += 1
	check(_world.nav_bits.ready, "the bits of the ground are worked out (%d frames)" % waited)
	_bricks = BrickWorld.new()
	add(_bricks)
	_bricks.setup(_world)
	_economy = Economy.new()
	add(_economy)
	_economy.setup(_world, _bricks)
	_nav = Navigation.new(_world, _bricks)
	_nav.obstacle = _economy.blocks_cell
	var sp := _world.spawn_point()
	var lo := Vector3i(sp.x - 20, sp.y - 6, sp.z - 20)
	var hi := Vector3i(sp.x + 20, sp.y + 8, sp.z + 20)
	check(_differences(lo, hi) == 0, "over the island the cache and the blocks agree on every cell")

	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	# How much faster the searches are (only told, not checked: it depends on the machine).
	var pairs: Array = []
	for i in 12:
		pairs.append([Vector3i(sp.x + rng.randi_range(-18, 18), sp.y + 1, sp.z + rng.randi_range(-18, 18)), Vector3i(sp.x + rng.randi_range(-18, 18), sp.y + 1, sp.z + rng.randi_range(-18, 18))])
	var t0 := Time.get_ticks_usec()
	var expanded := 0
	for pr in pairs:
		_nav.find_path(pr[0], pr[1])
		expanded += _nav.last_expanded
	var with_cache := Time.get_ticks_usec() - t0
	print("     nodes expanded: %d (%.1f us each)" % [expanded, float(with_cache) / maxi(expanded, 1)])
	_world.nav_bits.ready = false
	t0 = Time.get_ticks_usec()
	for pr in pairs:
		_nav.find_path(pr[0], pr[1])
	var without := Time.get_ticks_usec() - t0
	_world.nav_bits.ready = true
	print("     12 searches: %.1f ms with the bits, %.1f ms from the blocks" % [with_cache / 1000.0, without / 1000.0])
	# Changes: carve, fill and slope blocks, put bricks and a stockpile, then ask again.
	for i in 300:
		var p := Vector3i(rng.randi_range(lo.x, hi.x), rng.randi_range(sp.y - 3, sp.y + 4), rng.randi_range(lo.z, hi.z))
		var r := rng.randf()
		if r < 0.4:
			_world.set_block(p, Blocks.AIR)
		elif r < 0.8:
			_world.set_block(p, Blocks.make(Blocks.STONE))
		else:
			_world.set_block(p, Blocks.make(Blocks.GRASS, Blocks.shape_from_corners(0, 0, 4, 4)))
	for i in 20:
		_bricks.place(Vector3i(rng.randi_range(lo.x, hi.x), sp.y + 1, rng.randi_range(lo.z, hi.z)), rng.randi() % 2, BrickWorld.Kind.STONE, 1 + rng.randi() % 2)
	_economy.charge_for_stockpiles = false
	_economy.place_stockpile(Vector3i(sp.x + 5, sp.y + 1, sp.z + 5))
	check(_differences(lo, hi) == 0, "after 300 changed blocks, bricks and a stockpile they still agree")
	# A block put into the open sky far above the ground.
	var sky := Vector3i(sp.x, sp.y + 30, sp.z)
	_world.set_block(sky, Blocks.make(Blocks.STONE))
	check(_differences(Vector3i(sky.x - 3, sky.y - 3, sky.z - 3), Vector3i(sky.x + 3, sky.y + 3, sky.z + 3)) == 0, "and in a chunk that had held nothing but sky")


## How many cells in the box give another answer from the cache than from the blocks.
func _differences(lo: Vector3i, hi: Vector3i) -> int:
	var bad := 0
	for y in range(lo.y, hi.y + 1):
		for z in range(lo.z, hi.z + 1):
			for x in range(lo.x, hi.x + 1):
				var c := Vector3i(x, y, z)
				if _nav.standable(c) != _nav._standable_by_blocks(c):
					bad += 1
	return bad

