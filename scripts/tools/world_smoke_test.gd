extends SceneTree
## Headless check: godot --headless --path . -s res://scripts/tools/world_smoke_test.gd
## Generates the archipelago, verifies islands/sky, meshes, editing, placement rules and the raycast.

var _failed := false


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _init() -> void:
	var world := VoxelWorld.new()
	root.add_child(world)
	var t0 := Time.get_ticks_msec()
	while not world.is_ready():
		await process_frame
	print("generated in %d ms (%s)" % [Time.get_ticks_msec() - t0, str(world.size_blocks())])

	var spawn := world.spawn_point()
	_check(world.get_block(spawn) == Blocks.GRASS, "spawn is grass %s" % str(spawn))
	_check(world.get_block(spawn + Vector3i(0, 1, 0)) == Blocks.AIR, "air above spawn")
	_check(world.get_block(Vector3i(spawn.x, 0, spawn.z)) == Blocks.AIR, "open sky far below the island")
	_check(world.get_block(Vector3i(2, spawn.y, 2)) == Blocks.AIR, "corner of the map is empty sky")
	_check(world.generator.islands.size() == 5, "5 islands laid out")
	for i in range(1, world.generator.islands.size()):
		var isl: WorldGen.Island = world.generator.islands[i]
		var col := world.generator.column(int(isl.center.x), int(isl.center.y))
		_check(col.x > 0, "island %d has ground at its centre (top y=%d)" % [i, col.x])

	for i in 600:
		await process_frame
	var meshes := 0
	var tris := 0
	for c in world.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			meshes += 1
	_check(meshes > 0, "chunk meshes committed (%d)" % meshes)

	var hit := world.raycast(Vector3(spawn.x + 0.5, 90.0, spawn.z + 0.5), Vector3.DOWN, 100.0)
	_check(not hit.is_empty() and hit.cell == spawn and hit.normal == Vector3i(0, 1, 0), "raycast hits spawn top face %s" % str(hit))
	var miss := world.raycast(Vector3(2.5, 90.0, 2.5), Vector3.DOWN, 100.0)
	_check(miss.is_empty(), "raycast through empty sky misses")

	_check(world.set_block(spawn, Blocks.AIR), "dig block")
	_check(world.get_block(spawn) == Blocks.AIR, "block is air after dig")
	_check(world.place_block(spawn, Blocks.STONE), "place into the hole (supported)")
	var floating := spawn + Vector3i(0, 6, 0)
	_check(not world.can_place(floating), "cannot place a block in mid-air")
	_check(not world.place_block(floating, Blocks.STONE), "place_block rejects mid-air")
	_check(world.can_place(spawn + Vector3i(0, 1, 0)), "can place on top of ground")
	_check(world.place_block(spawn + Vector3i(0, 1, 0), Blocks.STONE), "build a tower: first")
	_check(world.place_block(spawn + Vector3i(0, 2, 0), Blocks.STONE), "build a tower: second (on a placed block)")
	_check(not world.set_block(Vector3i(-1, 0, 0), Blocks.AIR), "out of bounds rejected")
	for i in 60:
		await process_frame

	quit(1 if _failed else 0)
