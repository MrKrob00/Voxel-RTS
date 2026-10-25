extends SceneTree
## Headless check: godot --headless --path . -s res://tests/world_smoke_test.gd
## Generation, islands and bridges, the shape of the ground, and the editing rules (stages, slopes, building).

var _failed := false
var _meshed_frames := {}   ## cpos -> frame of its latest committed mesh


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_failed = true


func _init() -> void:
	var world := VoxelWorld.new()
	root.add_child(world)
	world.chunk_meshed.connect(func(cpos: Vector3i) -> void: _meshed_frames[cpos] = Engine.get_process_frames())
	var t0 := Time.get_ticks_msec()
	while not world.is_ready():
		await process_frame
	print("generated in %d ms (%s)" % [Time.get_ticks_msec() - t0, str(world.size_blocks())])

	var spawn := world.spawn_point()
	_check(world.get_block(spawn) == Blocks.GRASS, "spawn is grass %s" % str(spawn))
	_check(world.get_block(spawn + Vector3i(0, 1, 0)) == Blocks.AIR, "air above spawn")
	_check(world.get_block(Vector3i(spawn.x, 0, spawn.z)) == Blocks.AIR, "open sky far below the island")
	_check(world.get_block(Vector3i(2, spawn.y, 2)) == Blocks.AIR, "corner of the map is empty sky")
	var gen := world.generator
	_check(gen.islands.size() >= 1 and gen.islands.size() <= 5, "one main island plus 0-4 extra (%d islands, %d bridges)" % [gen.islands.size(), gen.bridges.size()])
	_check(gen.bridges.size() <= gen.islands.size() - 1, "at most one bridge per extra island")
	_bridge_report(world)
	for i in range(1, gen.islands.size()):
		var isl: WorldGen.Island = gen.islands[i]
		var col := gen.column(int(isl.center.x), int(isl.center.y))
		_check(col.x > 0, "island %d has ground at its centre (top y=%d)" % [i, col.x])
	_terrain_report(world)

	for i in 600:
		await process_frame
	_check(world.is_settled(), "all initial meshes are committed")
	var meshes := 0
	for c in world.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			meshes += 1
	_check(meshes > 0, "chunk meshes committed (%d)" % meshes)

	_slope_report(world)
	_dirt_report(world)
	_check_skin_consistency(world, "generated ground")
	_check_seams(world, "generated ground")

	await _test_stages(world)
	await _test_slope_rules(world)
	await _test_atomic_commit(world)
	await _test_basic_editing(world, spawn)

	quit(1 if _failed else 0)


# --- shapes -----------------------------------------------------------------------------------

## Classifies the slope pieces of the start island by their corner heights.
func _slope_report(world: VoxelWorld) -> void:
	var kinds := {"wedge": 0, "outer corner": 0, "inner corner": 0, "flat": 0, "other": 0}
	var c0 := world.generator.islands[0].center
	for dz in range(-70, 71):
		for dx in range(-70, 71):
			var x := int(c0.x) + dx
			var z := int(c0.y) + dz
			var col := world.generator.column(x, z)
			if col.x < 0:
				continue
			var shape := world.generator.skin_shape_at(x, z, col.x)
			if shape < 0:
				continue
			var h := Blocks.corner_heights(shape)
			var raised := 0
			for k in 4:
				raised += int(h[k] > 0)
			var all_two := h[0] == h[1] and h[1] == h[2] and h[2] == h[3]
			if all_two:
				kinds["flat"] += 1
			elif raised == 1:
				kinds["outer corner"] += 1
			elif raised == 2:
				kinds["wedge"] += 1
			elif raised == 3:
				kinds["inner corner"] += 1
			else:
				kinds["other"] += 1
	print("slope pieces on the start island: %s" % str(kinds))
	_check(kinds["wedge"] > 20, "wedges beside 1-block drops (%d)" % kinds["wedge"])
	_check(kinds["outer corner"] > 0, "outer corners (%d)" % kinds["outer corner"])
	_check(kinds["inner corner"] > 0, "inner corners (%d)" % kinds["inner corner"])
	_check(kinds["flat"] == 0 and kinds["other"] == 0, "no flat or odd pieces: pits and trenches get none (%d / %d)" % [kinds["flat"], kinds["other"]])


## Every slope cell near the main island must be exactly what the rules give for the current ground.
## Neighbouring slope pieces in the same layer must meet along edges of equal height (no cracks, no steps).
func _check_seams(world: VoxelWorld, label: String, radius := 70, around: Vector2 = Vector2(-1, -1)) -> void:
	var centre: Vector2 = world.generator.islands[0].center if around.x < 0 else around
	var dirs := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	var opposite := [1, 0, 3, 2]
	var pieces := 0
	var seams := 0
	var example := ""
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x := int(centre.x) + dx
			var z := int(centre.y) + dz
			var lv := world.terrain.level(x, z)
			if lv < 0 or lv % 2 == 1:
				continue
			var cell := Vector3i(x, lv / 2, z)
			var raw := world.get_block(cell)
			if not Blocks.is_skin(raw):
				continue
			pieces += 1
			for side in 4:
				var qcell: Vector3i = cell + dirs[side]
				var qraw := world.get_block(qcell)
				if not Blocks.is_skin(qraw):
					continue
				var a := _edge_heights(raw, side)
				var b := _edge_heights(qraw, opposite[side])
				if a != b:
					seams += 1
					if example == "":
						example = "%s side %d: %s vs %s" % [str(cell), side, str(a), str(b)]
	_check(seams == 0, "%s: neighbouring slope pieces meet at equal heights (%d pieces, %d seams) %s" % [label, pieces, seams, example])


## Heights (half-blocks) of the two top corners of a piece on one side, in a fixed order along the edge.
func _edge_heights(raw: int, side: int) -> Array:
	var h := Blocks.corner_heights(Blocks.shape(raw))   # corners 0:(0,0) 1:(1,0) 2:(1,1) 3:(0,1)
	match side:
		0: return [h[1], h[2]]   # +x
		1: return [h[0], h[3]]   # -x
		2: return [h[3], h[2]]   # +z
		_: return [h[0], h[1]]   # -z


## `allow_missing`: after digging, slope cells may legitimately stay empty (no new slopes are created in dug pits).
## Cells in `_destroyed` were destroyed by the player on purpose and are skipped.
var _destroyed := {}


func _check_skin_consistency(world: VoxelWorld, label: String, radius := 60, around: Vector2 = Vector2(-1, -1), allow_missing := false) -> void:
	var centre: Vector2 = world.generator.islands[0].center if around.x < 0 else around
	var cache := {}
	var bad := 0
	var checked := 0
	var first_bad := ""
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x := int(centre.x) + dx
			var z := int(centre.y) + dz
			var lv := world.terrain.level(x, z, cache)
			if lv < 0 or lv % 2 == 1:
				continue
			checked += 1
			var cell := Vector3i(x, lv / 2, z)
			var have := world.get_block(cell)
			if Blocks.is_solid(have) and not Blocks.is_skin(have):
				continue   # something else sits there (not a slope cell)
			if _destroyed.has(cell):
				continue
			var want := world.terrain.expected_skin(x, z, cache)
			if allow_missing and have == Blocks.AIR:
				continue
			if have != want:
				bad += 1
				if first_bad == "":
					first_bad = "%s have %d want %d" % [str(cell), have, want]
	_check(bad == 0, "%s: slope pieces match the rules (%d columns checked, %d off) %s" % [label, checked, bad, first_bad])


## Grass only on top, then a thin layer of earth: one block, a second one in patches, never more.
func _dirt_report(world: VoxelWorld) -> void:
	var gen := world.generator
	var c0 := gen.islands[0].center
	var one := 0
	var two := 0
	var more := 0
	var grass_below := 0
	var total := 0
	for dz in range(-60, 61):
		for dx in range(-60, 61):
			var x := int(c0.x) + dx
			var z := int(c0.y) + dz
			var col := gen.column(x, z)
			if col.x < 0 or col.x - col.y < 6 or gen.block_at(x, col.x, z, col.x, col.y) != Blocks.GRASS:
				continue
			total += 1
			var layers := 0
			var y := col.x - 1
			while y > col.y and gen.block_at(x, y, z, col.x, col.y) == Blocks.DIRT:
				layers += 1
				y -= 1
			if gen.block_at(x, col.x - 1, z, col.x, col.y) == Blocks.GRASS:
				grass_below += 1
			if layers <= 1:
				one += 1
			elif layers == 2:
				two += 1
			else:
				more += 1
	print("earth under the grass: %d columns, one layer %d, two layers %d, more %d" % [total, one, two, more])
	_check(more == 0, "never more than two layers of earth (%d columns with more)" % more)
	_check(grass_below == 0, "grass only on the very top")
	_check(two > total * 0.1 and two < total * 0.6, "a second layer of earth in patches (%.0f%% of columns)" % (100.0 * two / maxf(total, 1)))


# --- editing rules ---------------------------------------------------------------------------------

## A natural block that is not at a chunk border and has a lower column next to it (slopes depend on it).
func _find_step(world: VoxelWorld, avoid_border := true) -> Dictionary:
	var c0 := world.generator.islands[0].center
	for dz in range(-50, 51):
		for dx in range(-50, 51):
			var x := int(c0.x) + dx
			var z := int(c0.y) + dz
			if avoid_border and ((x & 15) == 0 or (x & 15) == 15 or (z & 15) == 0 or (z & 15) == 15):
				continue
			var lv := world.terrain.level(x, z)
			if lv < 4 or lv % 2 == 1:
				continue
			var lows := 0
			for off in Ramps.NEIGHBOURS:
				var n := world.terrain.level(x + off.x, z + off.y)
				if n >= 0 and n == lv - 2:
					lows += 1
			if lows >= 3:
				return {"x": x, "z": z, "level": lv}
	return {}


## A block whose neighbouring slope piece passes through three different shapes: block whole, half dug, gone.
## Found by running the rule on the levels, without touching the world.
func _find_intermediate(world: VoxelWorld) -> Dictionary:
	var c0 := world.generator.islands[0].center
	for dz in range(-60, 61):
		for dx in range(-60, 61):
			var x := int(c0.x) + dx
			var z := int(c0.y) + dz
			if (x & 15) == 0 or (x & 15) == 15 or (z & 15) == 0 or (z & 15) == 15:
				continue
			var lv := world.terrain.level(x, z)
			if lv < 4 or lv % 2 == 1:
				continue
			for off in Ramps.NEIGHBOURS:
				var nx: int = x + off.x
				var nz: int = z + off.y
				var nlv := world.terrain.level(nx, nz)
				if nlv < 0 or nlv % 2 == 1:
					continue
				var shapes := []
				for d_level in [lv, lv - 1, lv - 2]:
					var around := {}
					for o2 in Ramps.NEIGHBOURS:
						var lvl := world.terrain.level(nx + o2.x, nz + o2.y)
						if Vector2i(nx + o2.x, nz + o2.y) == Vector2i(x, z):
							lvl = d_level
						around[o2] = lvl
					shapes.append(Ramps.skin_shape(nlv, around))
				if shapes[0] >= 0 and shapes[1] != shapes[0] and shapes[1] != shapes[2] and shapes[1] >= 0:
					return {"x": x, "z": z, "level": lv, "nx": nx, "nz": nz, "shapes": shapes}
	return {}


func _test_stages(world: VoxelWorld) -> void:
	var step := _find_intermediate(world)
	_check(not step.is_empty(), "found a block whose neighbour has three different states")
	if step.is_empty():
		return
	var x: int = step.x
	var z: int = step.z
	var lv: int = step.level
	var cell := Vector3i(x, lv / 2 - 1, z)
	var neighbour_cell := Vector3i(step.nx, world.terrain.level(step.nx, step.nz) / 2, step.nz)
	var raw := world.get_block(cell)
	_check(Blocks.is_whole(raw), "the block is whole before digging")
	_check(Blocks.shape(world.get_block(neighbour_cell)) == step.shapes[0], "the neighbouring slope starts in its first state")

	# Stage 1: the block becomes half dug FIRST, and the neighbour follows that state, not "destroyed".
	_check(world.terrain.dig_step(cell), "dig stage 1")
	var half := world.get_block(cell)
	_check(Blocks.is_dug(half) and Blocks.shape(half) == Blocks.SHAPE_HALF and Blocks.mat(half) == Blocks.dug_material(Blocks.mat(raw)), "stage 1: a half-dug block; its grass is gone and the earth shows")
	_check(world.terrain.level(x, z) == lv - 1, "stage 1: the column level dropped by half a block (%d -> %d)" % [lv, world.terrain.level(x, z)])
	_check(Blocks.shape(world.get_block(neighbour_cell)) == step.shapes[1], "stage 1: the neighbouring slope is in the half-way state (not the 'destroyed' one)")
	_check_skin_consistency(world, "after stage 1", 8, Vector2(x, z), true)
	_check_seams(world, "after stage 1", 10, Vector2(x, z))

	# Stage 2: the block is gone and the neighbour follows.
	_check(world.terrain.dig_step(cell), "dig stage 2")
	_check(world.get_block(cell) == Blocks.AIR, "stage 2: the block is gone")
	_check(world.terrain.level(x, z) == lv - 2, "stage 2: the column level dropped by a full block")
	_check(Blocks.shape(world.get_block(neighbour_cell)) == step.shapes[2] or world.get_block(neighbour_cell) == Blocks.AIR and step.shapes[2] < 0, "stage 2: the neighbouring slope is in its final state")
	_check_skin_consistency(world, "after stage 2", 8, Vector2(x, z), true)
	_check_seams(world, "after stage 2", 10, Vector2(x, z))
	for i in 5:
		await process_frame

	# Building on the hole refills it: free space next to ground becomes a whole block again.
	_check(world.terrain.build(cell, Blocks.STONE), "build back into the hole")
	_check(Blocks.is_whole(world.get_block(cell)) and world.terrain.level(x, z) == lv, "the hole is a whole block again, level restored")
	_check_skin_consistency(world, "after rebuilding", 8, Vector2(x, z))
	_check_seams(world, "after rebuilding", 10, Vector2(x, z))
	for i in 5:
		await process_frame


func _test_slope_rules(world: VoxelWorld) -> void:
	# A slope piece that was dug stays dug, even when a neighbouring slope piece is dug afterwards.
	var c0 := world.generator.islands[0].center
	var pair := []
	for dz in range(-50, 51):
		for dx in range(-50, 51):
			if not pair.is_empty():
				continue
			var x := int(c0.x) + dx
			var z := int(c0.y) + dz
			var lv := world.terrain.level(x, z)
			var lv2 := world.terrain.level(x + 1, z)
			if lv < 0 or lv != lv2 or lv % 2 == 1:
				continue
			var a := Vector3i(x, lv / 2, z)
			var b := Vector3i(x + 1, lv / 2, z)
			if Blocks.is_skin(world.get_block(a)) and Blocks.is_skin(world.get_block(b)):
				pair = [a, b]
	_check(not pair.is_empty(), "found two neighbouring slope pieces")
	if pair.is_empty():
		return
	_check(world.terrain.dig_step(pair[0]) and world.get_block(pair[0]) == Blocks.AIR, "a slope piece is destroyed in one step")
	_check(world.terrain.dig_step(pair[1]), "its neighbour is destroyed too")
	_destroyed[pair[0]] = true
	_destroyed[pair[1]] = true
	_check(world.get_block(pair[0]) == Blocks.AIR, "the first slope stays destroyed (no new slope appears next to it)")
	for i in 5:
		await process_frame

	# Building on a slope fills that very cell: it becomes a whole block of its own material.
	var target := Vector3i(-1, -1, -1)
	for dz in range(-50, 51):
		for dx in range(-50, 51):
			if target.x >= 0:
				continue
			var x := int(c0.x) + dx
			var z := int(c0.y) + dz
			var lv := world.terrain.level(x, z)
			if lv < 0 or lv % 2 == 1:
				continue
			var cell := Vector3i(x, lv / 2, z)
			if Blocks.is_skin(world.get_block(cell)):
				target = cell
	_check(target.x >= 0, "found a slope piece to build on")
	if target.x < 0:
		return
	var m := Blocks.mat(world.get_block(target))
	var lv_before := world.terrain.level(target.x, target.z)
	_check(world.terrain.build(target, Blocks.STONE), "building on a slope succeeds")
	var after := world.get_block(target)
	_check(Blocks.is_whole(after) and Blocks.mat(after) == m, "the slope became a whole block of the same material (not a new block on top)")
	_check(world.get_block(target + Vector3i(0, 1, 0)) == Blocks.AIR or Blocks.is_skin(world.get_block(target + Vector3i(0, 1, 0))), "nothing was placed above it")
	_check(world.terrain.level(target.x, target.z) == lv_before + 2, "the column is one block higher")
	_check_skin_consistency(world, "after building on a slope", 8, Vector2(target.x, target.z))
	_check_seams(world, "after building on a slope", 10, Vector2(target.x, target.z))
	for i in 5:
		await process_frame


## One edit that touches several chunks must show all of them in the same frame.
func _test_atomic_commit(world: VoxelWorld) -> void:
	await process_frame
	var c0 := world.generator.islands[0].center
	var found := Vector2i(-1, -1)
	for dz in range(-50, 51):
		for dx in range(-50, 51):
			if found.x >= 0:
				continue
			var x := int(c0.x) + dx
			var z := int(c0.y) + dz
			if (x & 15) != 0:
				continue
			var lv := world.terrain.level(x, z)
			if lv > 0 and lv % 2 == 0 and Blocks.is_whole(world.get_block(Vector3i(x, lv / 2 - 1, z))):
				found = Vector2i(x, z)
	_check(found.x >= 0, "found a block on a chunk border")
	if found.x < 0:
		return
	_meshed_frames.clear()
	var lv := world.terrain.level(found.x, found.y)
	world.terrain.dig_step(Vector3i(found.x, lv / 2 - 1, found.y))
	var frames_waited := 0
	while not world.is_settled() and frames_waited < 600:
		await process_frame
		frames_waited += 1
	_check(world.is_settled(), "the edit finished meshing (%d frames)" % frames_waited)
	var frames := {}
	for cpos in _meshed_frames:
		frames[_meshed_frames[cpos]] = true
	_check(_meshed_frames.size() >= 2, "the edit rebuilt several chunks (%d)" % _meshed_frames.size())
	_check(frames.size() == 1, "all rebuilt chunks were committed in the same frame (%s)" % str(frames.keys()))


func _test_basic_editing(world: VoxelWorld, spawn: Vector3i) -> void:
	var cube := Vector3i(spawn.x + 3, spawn.y, spawn.z + 3)
	_check(world.get_block(cube) == Blocks.GRASS, "cube before digging")
	_check(world.terrain.dig_step(cube) and Blocks.is_dug(world.get_block(cube)) and Blocks.shape(world.get_block(cube)) == Blocks.SHAPE_HALF, "first dig stage: a half-dug block")
	_check(world.terrain.dig_step(cube) and world.get_block(cube) == Blocks.AIR, "second dig stage: gone")
	var hit := world.raycast(Vector3(spawn.x + 0.5, 90.0, spawn.z + 0.5), Vector3.DOWN, 100.0)
	_check(not hit.is_empty() and hit.cell == spawn and hit.normal == Vector3i(0, 1, 0), "raycast hits spawn top face %s" % str(hit))
	var miss := world.raycast(Vector3(2.5, 90.0, 2.5), Vector3.DOWN, 100.0)
	_check(miss.is_empty(), "raycast through empty sky misses")

	_check(world.terrain.dig_step(spawn) and world.terrain.dig_step(spawn), "dig the spawn block fully")
	_check(world.get_block(spawn) == Blocks.AIR, "block is air after digging")
	_check(world.terrain.build(spawn, Blocks.STONE), "build into the hole (supported)")
	var floating := spawn + Vector3i(0, 6, 0)
	_check(not world.terrain.can_build(floating), "cannot build in mid-air")
	_check(not world.terrain.build(floating, Blocks.STONE), "build rejects mid-air")
	_check(world.terrain.can_build(spawn + Vector3i(0, 1, 0)), "can build on top of ground")
	_check(world.terrain.build(spawn + Vector3i(0, 1, 0), Blocks.STONE), "build a tower: first")
	_check(world.terrain.build(spawn + Vector3i(0, 2, 0), Blocks.STONE), "build a tower: second (on a placed block)")
	_check(not world.set_block(Vector3i(-1, 0, 0), Blocks.AIR), "out of bounds rejected")
	for i in 60:
		await process_frame
	_check(world.is_settled(), "everything is meshed at the end")


# --- terrain and bridges -------------------------------------------------------------------------------

## Walks the start island by column heights (up 1 / down 2 per step) and reports relief, cliffs and reachability.
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
		if Vector2(p).distance_to(isl.center) <= isl.radius * 1.3:
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
	_check(max_h - min_h >= 10 and max_h - min_h <= 30, "relief is varied but low enough to dig through (%d blocks)" % (max_h - min_h))
	_check(high > total * 0.004, "plateaus are separated by cliffs (%d edge columns)" % high)
	_check(reach > total * 0.6, "plains: most of the island is walkable from spawn")


## Walks every bridge along its centre line (up 1 / down 2 per step) and checks both ends touch ground;
## then walks the whole map on foot from the spawn and checks every island is reachable.
func _bridge_report(world: VoxelWorld) -> void:
	var gen := world.generator
	for br in gen.bridges:
		var steps := int(br.length() * 1.25) + 1
		var prev := -1
		var ok := true
		for i in steps + 1:
			var p: Vector2 = br.centre(float(i) / steps)
			var col := gen.column(int(p.x), int(p.y))
			if col == WorldGen.EMPTY:
				ok = false
				break
			if prev >= 0 and (col.x - prev > 1 or prev - col.x > 2):
				ok = false
				break
			prev = col.x
		_check(ok, "bridge is continuous and walkable (%d blocks long, style %d)" % [int(br.length()), br.style])
	var start := gen.spawn_column()
	var queue: Array[Vector2i] = [start]
	var seen := {start: true}
	var targets := {}
	for i in range(1, gen.islands.size()):
		targets[i] = Vector2i(int(gen.islands[i].center.x), int(gen.islands[i].center.y))
	var visited := 0
	while not queue.is_empty():
		var p: Vector2i = queue.pop_back()
		visited += 1
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
	var reached := 0
	for i in targets:
		if seen.has(targets[i]):
			reached += 1
	print("on foot from the spawn: %d columns visited, %d of %d extra islands reached" % [visited, reached, targets.size()])
	_check(reached == targets.size(), "every island is reachable on foot over the bridges")
