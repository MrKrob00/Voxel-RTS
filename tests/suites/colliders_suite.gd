extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- colliders).
## The ground under falling things: one set of tiles for everything that asks, a few boxes per tile, tiles made again when blocks
## change, and a body that really lands on it.

var _world: VoxelWorld
var _base: Vector3i


func run() -> void:
	_world = ctx.world
	var sp := _world.spawn_point()
	_base = Vector3i(sp.x - 12, sp.y, sp.z - 12)
	# a flat floor 40 x 40 with a pillar 3 high and a pit
	for dz in 40:
		for dx in 40:
			for y in range(sp.y - 3, sp.y + 8):
				_world.set_block(Vector3i(_base.x + dx, y, _base.z + dz), Blocks.make(Blocks.GRASS) if y == sp.y else (Blocks.make(Blocks.DIRT) if y < sp.y else Blocks.AIR))
	for h in range(1, 4):
		_world.set_block(Vector3i(_base.x + 20, sp.y + h, _base.z + 20), Blocks.make(Blocks.STONE))
	_world.set_block(Vector3i(_base.x + 10, sp.y, _base.z + 10), Blocks.AIR)
	var waited := 0
	while not _world.column_levels_ready and waited < 3000:
		await tree.process_frame
		waited += 1
	check(_world.column_levels_ready, "the heights of the columns are worked out (%d frames)" % waited)
	var p := _world.spawn_point()
	check(_world.ground_level(_base.x + 20, _base.z + 20) == Blocks.UNIT * (p.y + 4), "a pillar of three blocks is 4 blocks high over the floor (%d)" % _world.ground_level(_base.x + 20, _base.z + 20))
	check(_world.column_levels[(_base.x + 20) + (_base.z + 20) * _world.size_blocks().x] == _world.ground_level(_base.x + 20, _base.z + 20), "and the cache says the same")

	# The boxes of tiles: a flat tile is one box, a tile with a pillar and a pit a few.
	var flat := GroundColliders.tile_boxes(_world, Vector2i((_base.x + 36) / GroundColliders.TILE, (_base.z + 36) / GroundColliders.TILE))
	var rough := GroundColliders.tile_boxes(_world, Vector2i((_base.x + 20) / GroundColliders.TILE, (_base.z + 20) / GroundColliders.TILE))
	print("     boxes: flat tile %d, tile with a pillar %d (of %d columns)" % [flat.size(), rough.size(), GroundColliders.TILE * GroundColliders.TILE])
	check(rough.size() > 1 and rough.size() < 30, "a tile with a pillar is a few boxes, not a box per block (%d)" % rough.size())
	var area := 0
	for r in rough:
		area += (r.x1 - r.x0) * (r.z1 - r.z0)
	var covered := 0
	for j in GroundColliders.TILE:
		for i in GroundColliders.TILE:
			if _world.ground_level(((_base.x + 20) / GroundColliders.TILE) * GroundColliders.TILE + i, ((_base.z + 20) / GroundColliders.TILE) * GroundColliders.TILE + j) > 0:
				covered += 1
	check(area == covered, "the boxes cover exactly the columns that have ground (%d of %d)" % [area, covered])

	# Many things close together share the tiles.
	var colliders := GroundColliders.new()
	add(colliders)
	colliders.setup(_world)
	var centre := Vector3(_base.x + 24.0, sp.y + 1.0, _base.z + 24.0)
	var spots: Array[Vector3] = []
	for i in 30:
		spots.append(centre + Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0)))
	for sp_i in spots:
		colliders.touch(sp_i)
	await tree.physics_frame
	await tree.physics_frame
	check(colliders.patch_count() <= 4, "thirty things close together are at most four tiles (%d)" % colliders.patch_count())
	var count_before := colliders.patch_count()
	for sp_i in spots:
		colliders.touch(sp_i)
	await tree.physics_frame
	await tree.physics_frame
	check(colliders.patch_count() == count_before, "and asking again makes no new ones (%d, then %d)" % [count_before, colliders.patch_count()])

	# A body lands on it.
	var body := RigidBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 1
	var cs := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.3
	cs.shape = sphere
	body.add_child(cs)
	add(body)
	body.global_position = Vector3(_base.x + 5.5, sp.y + 4.0, _base.z + 5.5)
	for i in 120:
		colliders.touch(body.global_position)
		await tree.physics_frame
	check(body.global_position.y > sp.y + 0.9 and body.global_position.y < sp.y + 1.6, "a ball dropped on the floor lies on it (y %.2f, floor %d)" % [body.global_position.y, sp.y + 1])

	# A block dug out under a tile: the tile is made again and the ball can fall in.
	var pit := Vector3i(int(body.global_position.x), sp.y, int(body.global_position.z))
	_world.set_block(pit, Blocks.AIR)
	body.sleeping = false   # (a body that sleeps is not woken by the ground changing under it)
	for i in 120:
		colliders.touch(body.global_position)
		await tree.physics_frame
	check(body.global_position.y < sp.y + 0.6, "after the block under it is dug out the ball sinks into the hole (y %.2f)" % body.global_position.y)

	# Tiles go when nobody asks any more.
	var gone := 0
	while colliders.patch_count() > 0 and gone < 400:
		await tree.physics_frame
		gone += 1
	check(colliders.patch_count() == 0, "a few seconds after the last ask the tiles are gone (%d frames)" % gone)
