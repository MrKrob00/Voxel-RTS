extends SceneTree
## Headless check: godot --headless --path . -s res://scripts/tools/brick_test.gd
## Support rules: stacked bricks drop together, a running bond survives losing a brick, no building in mid-air,
## and fallen bricks come to rest on the terrain instead of sinking through it.

var _failed := false


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _init() -> void:
	var world := VoxelWorld.new()
	root.add_child(world)
	var bricks := BrickWorld.new()
	root.add_child(bricks)
	bricks.setup(world)
	while not world.is_ready():
		await process_frame
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
		await process_frame

	_check(not bricks.can_place(Vector3i(x, y + 5, z), 0), "no brick in mid-air")
	_check(bricks.can_place(Vector3i(x, y, z), 0), "brick on the ground")
	_check(not bricks.can_place(Vector3i(x, y - 1, z), 0), "no brick inside terrain")

	# 1. A straight stack of three: knocking out the bottom one drops the other two.
	var s1 := bricks.place(Vector3i(x, y, z), 0)
	var s2 := bricks.place(Vector3i(x, y + 1, z), 0)
	var s3 := bricks.place(Vector3i(x, y + 2, z), 0)
	_check(s1 != null and s2 != null and s3 != null, "stack of 3 placed")
	var fell := bricks.remove(s1)
	_check(fell == 2, "stack: removing the bottom drops both above (%d)" % fell)
	_check(bricks.brick_count() == 0 and bricks.debris_count() == 2, "stack: 2 debris bodies exist")

	# 2. A running bond. Row 1: x, x+2, x+4. Row 2: x+1, x+3. Row 3: x, x+2.
	var bz := z + 4
	var r1 := [bricks.place(Vector3i(x, y, bz), 0), bricks.place(Vector3i(x + 2, y, bz), 0), bricks.place(Vector3i(x + 4, y, bz), 0)]
	var r2 := [bricks.place(Vector3i(x + 1, y + 1, bz), 0), bricks.place(Vector3i(x + 3, y + 1, bz), 0)]
	var r3 := [bricks.place(Vector3i(x, y + 2, bz), 0), bricks.place(Vector3i(x + 2, y + 2, bz), 0)]
	_check(not (null in r1 or null in r2 or null in r3), "bonded wall placed (7 bricks)")
	var base_count := bricks.brick_count()
	fell = bricks.remove(r1[1])
	_check(fell == 0 and bricks.brick_count() == base_count - 1, "bond: losing the middle bottom brick drops nothing")
	# Now also remove the left bottom brick: row 2 brick x+1 loses both supports.
	fell = bricks.remove(r1[0])
	_check(fell == 2, "bond: losing a second support drops that brick and the one resting only on it (%d)" % fell)
	_check(bricks.brick_at(Vector3i(x + 2, y + 2, bz)) != null, "bond: neighbouring brick that still has a support stays")

	# 3. Debris settles on the terrain.
	for i in 300:
		await physics_frame
	var lowest := 1e9
	var bodies := 0
	for c in bricks.get_children():
		if c is RigidBody3D:
			bodies += 1
			lowest = minf(lowest, (c as RigidBody3D).global_position.y)
	_check(bodies >= 4, "debris bodies alive (%d)" % bodies)
	_check(lowest > spawn.y + 0.2, "debris rests on the ground, not through it (lowest y=%.2f, ground top=%d)" % [lowest, spawn.y + 1])

	quit(1 if _failed else 0)
