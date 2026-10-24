extends SceneTree
## Headless check: godot --headless --path . -s res://scripts/tools/world_smoke_test.gd
## Generates a small world, verifies data, meshes, editing and the raycast.

var _failed := false


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _init() -> void:
	var world := VoxelWorld.new()
	world.size_chunks = Vector3i(3, 4, 3)
	root.add_child(world)
	var t0 := Time.get_ticks_msec()
	while not world.is_ready():
		await process_frame
	print("generated in %d ms" % (Time.get_ticks_msec() - t0))

	_check(world.get_block(Vector3i(5, 0, 5)) == Blocks.BEDROCK, "bedrock at y=0")
	var sy := world.surface_y(20, 20)
	_check(sy > 3, "surface found (y=%d)" % sy)
	_check(world.get_block(Vector3i(20, 60, 20)) == Blocks.AIR, "air above ground")

	# Let the mesher finish.
	for i in 400:
		await process_frame
	var meshes := 0
	for c in world.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			meshes += 1
	_check(meshes > 0, "chunk meshes committed (%d)" % meshes)

	# Raycast straight down onto the surface.
	var hit := world.raycast(Vector3(20.5, 63.0, 20.5), Vector3.DOWN, 100.0)
	_check(not hit.is_empty() and hit.cell.y >= sy - 0 and hit.normal == Vector3i(0, 1, 0), "raycast hits top face %s" % str(hit))

	# Edit: dig and place.
	var cell := Vector3i(20, sy, 20)
	_check(world.set_block(cell, Blocks.AIR), "dig block")
	_check(world.get_block(cell) == Blocks.AIR, "block is air after dig")
	_check(world.set_block(cell, Blocks.STONE), "place block")
	_check(not world.set_block(Vector3i(-1, 0, 0), Blocks.AIR), "out of bounds rejected")
	for i in 60:
		await process_frame

	quit(1 if _failed else 0)
