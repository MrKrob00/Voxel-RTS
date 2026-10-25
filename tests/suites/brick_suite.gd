extends TestSuite
## Headless check: godot --headless --path . -s res://tests/brick_test.gd
## Support rules: stacked bricks drop together, a running bond survives losing a brick, no building in mid-air,
## and fallen bricks come to rest on the terrain instead of sinking through it.



func run() -> void:
	var world := ctx.world
	var bricks := BrickWorld.new()
	add(bricks)
	bricks.setup(world)
	var spawn := world.spawn_point()
	# Level test pad: solid stone at spawn.y, open air above it.
	var y := spawn.y + 1
	var x := spawn.x - 6
	var z := spawn.z - 6
	for dx in range(-1, 12):
		for dz in range(-1, 14):
			world.set_block(Vector3i(x + dx, spawn.y, z + dz), Blocks.STONE)
			for dy in range(1, 8):
				world.set_block(Vector3i(x + dx, spawn.y + dy, z + dz), Blocks.AIR)
	for i in 30:
		await tree.process_frame

	check(not bricks.can_place(Vector3i(x, y + 5, z), 0), "no brick in mid-air")
	check(bricks.can_place(Vector3i(x, y, z), 0), "brick on the ground")
	check(not bricks.can_place(Vector3i(x, y - 1, z), 0), "no brick inside terrain")

	# 1. A straight stack of three: knocking out the bottom one drops the other two.
	var s1 := bricks.place(Vector3i(x, y, z), 0)
	var s2 := bricks.place(Vector3i(x, y + 1, z), 0)
	var s3 := bricks.place(Vector3i(x, y + 2, z), 0)
	check(s1 != null and s2 != null and s3 != null, "stack of 3 placed")
	var fell := bricks.remove(s1)
	check(fell == 2, "stack: removing the bottom drops both above (%d)" % fell)
	check(bricks.brick_count() == 0 and bricks.debris_count() == 2, "stack: 2 debris bodies exist")

	# 2. A running bond. Row 1: x, x+2, x+4. Row 2: x+1, x+3. Row 3: x, x+2.
	var bz := z + 4
	var r1 := [bricks.place(Vector3i(x, y, bz), 0), bricks.place(Vector3i(x + 2, y, bz), 0), bricks.place(Vector3i(x + 4, y, bz), 0)]
	var r2 := [bricks.place(Vector3i(x + 1, y + 1, bz), 0), bricks.place(Vector3i(x + 3, y + 1, bz), 0)]
	var r3 := [bricks.place(Vector3i(x, y + 2, bz), 0), bricks.place(Vector3i(x + 2, y + 2, bz), 0)]
	check(not (null in r1 or null in r2 or null in r3), "bonded wall placed (7 bricks)")
	var base_count := bricks.brick_count()
	fell = bricks.remove(r1[1])
	check(fell == 0 and bricks.brick_count() == base_count - 1, "bond: losing the middle bottom brick drops nothing")
	# Now also remove the left bottom brick: row 2 brick x+1 loses both supports.
	fell = bricks.remove(r1[0])
	check(fell == 2, "bond: losing a second support drops that brick and the one resting only on it (%d)" % fell)
	check(bricks.brick_at(Vector3i(x + 2, y + 2, bz)) != null, "bond: neighbouring brick that still has a support stays")

	# 2b. 1x1x1 cubes: a cube column drops as one, and a cube standing on a long brick falls when that brick goes.
	var cz := z + 9
	var c1 := bricks.place(Vector3i(x, y, cz), 0, BrickWorld.Kind.STONE, 1)
	var c2 := bricks.place(Vector3i(x, y + 1, cz), 0, BrickWorld.Kind.WOOD, 1)
	check(c1 != null and c2 != null and c1.cells().size() == 1, "cube column placed")
	check(bricks.remove(c1) == 1, "cube: removing the bottom cube drops the one above")
	var lb := bricks.place(Vector3i(x + 4, y, cz), 0)
	var cb := bricks.place(Vector3i(x + 5, y + 1, cz), 0, BrickWorld.Kind.STONE, 1)
	check(lb != null and cb != null, "cube resting on the end of a long brick")
	check(bricks.remove(lb) == 1, "cube falls when its long brick is removed")

	# 2c. Bricks stand on whole ground blocks only: not on a slope piece or a half-dug block, and they never change terrain.
	var sx := x + 8
	var sz := z + 2
	world.set_block(Vector3i(sx, spawn.y, sz), Blocks.make(Blocks.STONE, Blocks.SHAPE_DUG, true))
	world.set_block(Vector3i(sx + 1, spawn.y, sz), Blocks.make(Blocks.STONE, Blocks.shape_from_corners(0, 4, 4, 0)))
	check(not bricks.can_place(Vector3i(sx, y, sz), 0, 1), "no brick on a half-dug block")
	check(not bricks.can_place(Vector3i(sx + 1, y, sz), 0, 1), "no brick on a slope piece")
	check(not bricks.can_place(Vector3i(sx - 1, y, sz), 0, 2), "a long brick may not overhang a half-dug block either")
	check(bricks.can_place(Vector3i(sx - 3, y, sz), 0, 2), "a brick on whole blocks next to it is fine")
	var level_before := world.terrain.level(sx - 3, sz)
	var onfloor := bricks.place(Vector3i(sx - 3, y, sz), 0, BrickWorld.Kind.STONE, 2)
	check(onfloor != null and world.terrain.level(sx - 3, sz) == level_before, "placing a brick does not change the terrain level")

	# 2d. Digging the ground out from under a brick drops it.
	var before_debris := bricks.debris_count()
	var stood := bricks.place(Vector3i(x + 9, y, z + 8), 0, BrickWorld.Kind.WOOD, 1)
	check(stood != null, "a cube brick on the pad")
	world.terrain.dig_step(Vector3i(x + 9, spawn.y, z + 8))
	check(bricks.brick_at(Vector3i(x + 9, y, z + 8)) == null and bricks.debris_count() == before_debris + 1, "the brick fell when its ground was dug half away")

	# 3. Debris settles on the terrain.
	for i in 300:
		await tree.physics_frame
	var lowest := 1e9
	var bodies := 0
	for c in bricks.get_children():
		if c is RigidBody3D:
			bodies += 1
			lowest = minf(lowest, (c as RigidBody3D).global_position.y)
	check(bodies >= 7, "debris bodies alive (%d)" % bodies)
	check(lowest > spawn.y + 0.2, "debris rests on the ground, not through it (lowest y=%.2f, ground top=%d)" % [lowest, spawn.y + 1])

