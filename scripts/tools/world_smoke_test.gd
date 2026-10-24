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

	_terrain_report(world)

	# Ramp wedges next to 1-block drops, and staged digging.
	var wedge := Vector3i(-1, -1, -1)
	var wedges := 0
	for dz in range(-60, 61):
		for dx in range(-60, 61):
			var wx := int(world.generator.islands[0].center.x) + dx
			var wz := int(world.generator.islands[0].center.y) + dz
			var col := world.generator.column(wx, wz)
			if col.x < 0:
				continue
			var sh := world.generator.ramp_shape(wx, wz, col.x)
			if sh != Blocks.SHAPE_CUBE:
				wedges += 1
				if wedge.x < 0:
					wedge = Vector3i(wx, col.x + 1, wz)
	print("ramp wedges on the start island: %d, first at %s" % [wedges, str(wedge)])
	_check(wedges > 20, "1-block drops get ramp wedges")

	for i in 600:
		await process_frame
	var w_raw := world.get_block(wedge)
	_check(Blocks.shape(w_raw) >= Blocks.SHAPE_WEDGE_PX and Blocks.shape(w_raw) <= Blocks.SHAPE_WEDGE_NZ, "wedge is stored in the world (raw %d)" % w_raw)
	_check(Blocks.is_solid(w_raw) and not Blocks.is_opaque(w_raw), "wedge is solid ground but does not hide neighbours")
	_check(world.dig_step(wedge) and world.get_block(wedge) == Blocks.AIR, "digging a wedge removes it")
	var cube := Vector3i(spawn.x + 3, spawn.y, spawn.z + 3)
	_check(world.get_block(cube) == Blocks.GRASS, "cube before digging")
	_check(world.dig_step(cube) and Blocks.shape(world.get_block(cube)) == Blocks.SHAPE_SLAB and Blocks.mat(world.get_block(cube)) == Blocks.GRASS, "first dig stage: cube becomes a slab of the same material")
	_check(world.dig_step(cube) and world.get_block(cube) == Blocks.AIR, "second dig stage: slab is gone")
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


## Walks the start island by column heights (up 1 / down 2 per step) and reports how much of it is reachable,
## and how much of it is mountain, to prove that passes exist and the map is not flat.
func _terrain_report(world: VoxelWorld) -> void:
	var gen := world.generator
	var isl: WorldGen.Island = gen.islands[0]
	var r := int(isl.radius * 1.3)
	var cx := int(isl.center.x)
	var cz := int(isl.center.y)
	var total := 0
	var high := 0
	var min_h := 999
	var max_h := 0
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var col := gen.column(cx + dx, cz + dz)
			if col.x < 0:
				continue
			total += 1
			min_h = mini(min_h, col.x)
			max_h = maxi(max_h, col.x)
			var east := gen.column(cx + dx + 1, cz + dz)
			var south := gen.column(cx + dx, cz + dz + 1)
			if (east.x >= 0 and absi(east.x - col.x) >= 3) or (south.x >= 0 and absi(south.x - col.x) >= 3):
				high += 1   # a cliff edge: neighbouring columns differ by 3+ blocks
	var seen := {}
	var queue: Array[Vector2i] = [Vector2i(cx, cz)]
	seen[queue[0]] = true
	var reach := 0
	while not queue.is_empty():
		var p: Vector2i = queue.pop_back()
		reach += 1
		var h := gen.column(p.x, p.y).x
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q: Vector2i = p + d
			if seen.has(q):
				continue
			var qc := gen.column(q.x, q.y)
			if qc.x < 0:
				continue
			var dh := qc.x - h
			if dh <= 1 and dh >= -2:
				seen[q] = true
				queue.append(q)
	print("start island: %d columns, height %d..%d, cliff edges %.1f%%, walkable from spawn %.0f%%" % [total, min_h, max_h, 100.0 * high / total, 100.0 * reach / total])
	_check(max_h - min_h >= 10 and max_h - min_h <= 22, "relief is varied but low enough to dig through (%d blocks)" % (max_h - min_h))
	_check(high > total * 0.004, "plateaus are separated by cliffs (%d edge columns)" % high)
	_check(reach > total * 0.6, "plains: most of the island is walkable from spawn")
