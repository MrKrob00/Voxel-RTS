extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- navigation).
## Where units may stand and walk: the surface under their feet, pathfinding over ground, slopes, pits, bridges and bricks,
## and a unit actually walking a path.



func run() -> void:
	_surface_heights()
	var world := ctx.world
	var bricks := BrickWorld.new()
	add(bricks)
	bricks.setup(world)
	var nav := Navigation.new(world, bricks)
	var spawn := world.spawn_point()
	var start := Vector3i(spawn.x, spawn.y + 1, spawn.z)
	check(nav.standable(start), "the spawn is a place to stand")
	check(not nav.standable(start + Vector3i(0, 1, 0)), "the air one block above it is not (nothing under the feet)")
	check(not nav.standable(Vector3i(spawn.x, spawn.y, spawn.z)), "the ground block itself is not")

	_walk_on_island(world, nav, start)
	_bridges(world, nav, start)
	_blocked_goal(world, nav, start)
	_drops_and_pits(world, nav, start)
	_bricks(world, bricks, nav, start)
	_jumps(world, nav, start)
	_unit_walks(world, nav, start)
	# Let the mesh workers finish before the world is torn down.
	var waited := 0
	while not world.is_settled() and waited < 3000:
		await tree.process_frame
		waited += 1


func _surface_heights() -> void:
	check(Blocks.surface_height(Blocks.SHAPE_CUBE, 0.5, 0.5) == 1.0, "surface: a cube is one block high")
	var wedge := Blocks.shape_from_corners(0, 0, 4, 4)   # rises towards +z
	check(is_equal_approx(Blocks.surface_height(wedge, 0.5, 0.0), 0.0) and is_equal_approx(Blocks.surface_height(wedge, 0.5, 1.0), 1.0), "surface: a wedge rises from 0 to 1")
	check(is_equal_approx(Blocks.surface_height(wedge, 0.3, 0.5), 0.5), "surface: halfway up the wedge is half a block")
	var corner := Blocks.shape_from_corners(4, 0, 0, 0)
	check(is_equal_approx(Blocks.surface_height(corner, 0.0, 0.0), 1.0) and is_equal_approx(Blocks.surface_height(corner, 1.0, 1.0), 0.0), "surface: a corner piece is high at its raised corner only")
	check(is_equal_approx(Blocks.surface_height(Blocks.SHAPE_DUG, 0.5, 0.5), 0.75), "surface: the floor of a half-dug block is 3/4 high")
	check(is_equal_approx(Blocks.surface_height(Blocks.SHAPE_BOWL, 0.0, 0.0), 1.0), "surface: the rim of a bowl is a full block")
	# The surface is continuous across the whole cell: no jumps between neighbouring sample points.
	var smooth := true
	for shape in [wedge, corner, Blocks.SHAPE_BOWL, Blocks.dug_shape(5, 3)]:
		var prev := Blocks.surface_height(shape, 0.0, 0.0)
		for i in range(1, 41):
			var v := Blocks.surface_height(shape, i / 40.0, i / 40.0)
			smooth = smooth and absf(v - prev) < 0.06
			prev = v
	check(smooth, "surface: no jumps along the diagonal of any piece")


func _valid_path(nav: Navigation, path: Array[Vector3i]) -> String:
	for i in path.size():
		if not nav.standable(path[i]):
			return "cell %d %s is not standable" % [i, str(path[i])]
		if i > 0:
			var a := path[i - 1]
			var b := path[i]
			var jumped := (absi(a.x - b.x) == 2 and a.z == b.z) or (absi(a.z - b.z) == 2 and a.x == b.x)   # over a gap of one cell
			if not jumped and (absi(a.x - b.x) > 1 or absi(a.z - b.z) > 1 or (a.x == b.x and a.z == b.z)):
				return "step %d is not to a neighbouring column" % i
			var dy := b.y - a.y
			if dy > Navigation.MAX_STEP_UP or dy < -Navigation.MAX_DROP:
				return "step %d changes height by %d" % [i, dy]
	return ""


func _walk_on_island(world: VoxelWorld, nav: Navigation, start: Vector3i) -> void:
	var t0 := Time.get_ticks_usec()
	var worst := 0
	var bad := ""
	var found := 0
	var tried := 0
	for off in [Vector2i(14, 3), Vector2i(-18, 9), Vector2i(5, -22), Vector2i(26, 20), Vector2i(-30, -12), Vector2i(2, 31)]:
		var goal := nav.nearest_standable(Vector3i(start.x + off.x, start.y, start.z + off.y), 5)
		if goal.x < 0:
			continue
		tried += 1
		var path := nav.find_path(start, goal)
		worst = maxi(worst, nav.last_expanded)
		if nav.last_reached and path.size() >= 2 and path[0] == start and path[-1] == goal:
			found += 1
			var why := _valid_path(nav, path)
			if why != "":
				bad = why
	check(tried >= 4 and found == tried, "paths over the start island: %d of %d found (worst search expanded %d cells, %d ms for all)" % [found, tried, worst, (Time.get_ticks_usec() - t0) / 1000])
	check(bad == "", "every cell of those paths is standable and every step is a legal move %s" % bad)


func _bridges(world: VoxelWorld, nav: Navigation, start: Vector3i) -> void:
	var gen := world.generator
	var reached := 0
	var total := 0
	var bad := ""
	var ms := 0
	for i in range(1, gen.islands.size()):
		var isl: WorldGen.Island = gen.islands[i]
		var col := gen.column(int(isl.center.x), int(isl.center.y))
		var goal := nav.nearest_standable(Vector3i(int(isl.center.x), col.x + 1, int(isl.center.y)), 6)
		if goal.x < 0:
			continue
		total += 1
		var t0 := Time.get_ticks_msec()
		var path := nav.find_path(start, goal)
		ms += Time.get_ticks_msec() - t0
		if nav.last_reached:
			reached += 1
			var why := _valid_path(nav, path)
			if why != "":
				bad = why
		else:
			print("   island %d: not reached, expanded %d" % [i, nav.last_expanded])
	check(total > 0 and reached == total, "paths over the bridges to every extra island: %d of %d (%d ms)" % [reached, total, ms])
	check(bad == "", "bridge paths are legal %s" % bad)


func _blocked_goal(world: VoxelWorld, nav: Navigation, start: Vector3i) -> void:
	# A goal walled in on all sides, three blocks high: unreachable, but the unit still gets as close as it can.
	var goal := nav.nearest_standable(Vector3i(start.x + 12, start.y, start.z + 4), 3)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			for dy in range(0, 3):
				world.set_block(goal + Vector3i(dx, dy, dz), Blocks.make(Blocks.STONE))
	var path := nav.find_path(start, goal)
	check(not nav.last_reached, "a goal walled in on all sides is not reached")
	check(path.size() >= 2 and Vector2(path[-1].x - goal.x, path[-1].z - goal.z).length() <= 4.5, "...but the path gets within a few blocks of it (ends %s, goal %s)" % [str(path[-1]) if not path.is_empty() else "-", str(goal)])
	# Open one side and it can be reached again.
	for dy in range(0, 3):
		world.set_block(goal + Vector3i(1, dy, 0), Blocks.AIR)
	var again := nav.find_path(start, goal)
	check(nav.last_reached and again[-1] == goal, "after opening a gap the goal is reached")


func _drops_and_pits(world: VoxelWorld, nav: Navigation, start: Vector3i) -> void:
	# A shaft five blocks deep next to the start: the rim does not link to its floor (a drop of more than %d)
	var rim := nav.nearest_standable(Vector3i(start.x - 8, start.y, start.z - 8), 3)
	var pit := rim + Vector3i(1, 0, 0)
	for dy in range(-6, 3):
		world.set_block(pit + Vector3i(0, dy, 0), Blocks.AIR)
	var floor_cell := pit + Vector3i(0, -5, 0)
	world.set_block(floor_cell + Vector3i(0, -1, 0), Blocks.make(Blocks.STONE))
	check(nav.standable(floor_cell), "the bottom of a deep shaft is standable")
	var linked := false
	for r in nav.neighbours(rim):
		if r[0] == floor_cell:
			linked = true
	check(not linked, "...but you cannot step down five blocks into it")
	# A half-dug block is a floor too, one step down from its neighbours.
	var flat := nav.nearest_standable(Vector3i(start.x + 6, start.y, start.z - 10), 3)
	var next := flat + Vector3i(1, 0, 0)
	if nav.standable(next) and next.y == flat.y:
		var top := next + Vector3i(0, -1, 0)
		world.terrain.dig_step(top)
		var dug := Blocks.is_dug(world.get_block(top))
		check(dug and nav.standable(top), "a half-dug block is a floor to stand in")
		var down_ok := false
		for r in nav.neighbours(flat):
			if r[0] == top:
				down_ok = true
		check(down_ok, "...one step down from its neighbour")
		var h := nav.feet_height(top, top.x + 0.5, top.z + 0.5)
		check(is_equal_approx(h, top.y + 0.75), "...and the feet stand on its floor, 3/4 of the way up (%.2f)" % h)


func _bricks(world: VoxelWorld, bricks: BrickWorld, nav: Navigation, start: Vector3i) -> void:
	# A flat pad, a wall of bricks on it, and a unit has to go round.
	var base := nav.nearest_standable(Vector3i(start.x - 4, start.y, start.z + 10), 3)
	for dz in range(-3, 4):
		for dx in range(-4, 5):
			var gcell := base + Vector3i(dx, -1, dz)
			world.set_block(gcell, Blocks.make(Blocks.STONE))
			for dy in range(0, 4):
				world.set_block(base + Vector3i(dx, dy, dz), Blocks.AIR)
	var a := base + Vector3i(-3, 0, 0)
	var b := base + Vector3i(3, 0, 0)
	var direct := nav.find_path(a, b)
	check(nav.last_reached and direct.size() <= 8, "on a flat pad the way is straight (%d cells)" % direct.size())
	for dz in range(-3, 3):
		for dy in range(0, 2):
			bricks.place(base + Vector3i(0, dy, dz), 0, BrickWorld.Kind.STONE, 1)
	check(not nav.standable(base + Vector3i(0, 0, 0)), "a brick is not a place to stand in")
	check(nav.standable(base + Vector3i(0, 2, 0)), "the top of a brick wall is a place to stand")
	var around := nav.find_path(a, b)
	check(nav.last_reached and around.size() > direct.size(), "a wall of bricks makes the way longer (%d cells instead of %d)" % [around.size(), direct.size()])
	var through := false
	for c in around:
		if bricks.occupied(c):
			through = true
	check(not through, "...and the path does not go through a brick")


func _unit_walks(world: VoxelWorld, nav: Navigation, start: Vector3i) -> void:
	var manager := UnitManager.new()
	add(manager)
	manager.setup(world, null)
	var u := manager.spawn(start)
	var goal := nav.nearest_standable(Vector3i(start.x + 15, start.y, start.z - 6), 4)
	var done := [false]
	u.arrived.connect(func() -> void: done[0] = true)
	check(u.walk_to(goal), "a unit takes a walk order")
	var frames := 0
	while not done[0] and frames < 4000:
		u._process(0.05)
		frames += 1
	check(done[0] and u.cell == goal, "the unit arrives at its goal in %.1f s" % (frames * 0.05))
	check(u.position.distance_to(nav.feet_position(goal)) < 0.05, "...and stands on the ground there")
	# A squad sent to one spot spreads out to different cells.
	var squad := manager.spawn_squad(start, 5, 1)
	check(squad.size() == 5, "a squad of five finds room")
	manager.select_all()
	var target := nav.nearest_standable(Vector3i(start.x - 12, start.y, start.z + 14), 4)
	var moved := manager.command_move(target)
	check(moved >= 5, "a move order for the whole selection gives every unit a way (%d)" % moved)
	var goals := {}
	for s in manager.selection:
		goals[s.goal] = true
	check(goals.size() == manager.selection.size(), "...each to its own cell")
	for step_i in 6000:
		for s in manager.selection:
			s._process(0.05)
	var all_there := true
	for s in manager.selection:
		all_there = all_there and s.is_idle() and Vector2(s.cell.x - target.x, s.cell.z - target.z).length() < 4.0
	check(all_there, "the squad has arrived around the target")
	# Digging the floor out from under a unit makes it fall to the next floor instead of floating.
	var victim := manager.spawn(nav.nearest_standable(Vector3i(start.x + 2, start.y, start.z + 2), 3))
	var under := victim.cell + Vector3i(0, -1, 0)
	world.set_block(under, Blocks.AIR)
	world.set_block(under + Vector3i(0, -1, 0), Blocks.make(Blocks.STONE))
	for i in 60:
		victim._process(0.05)
	check(victim.cell.y == under.y and absf(victim.position.y - float(under.y)) < 0.05, "a unit whose floor was dug out falls one block (now at y %.2f)" % victim.position.y)


func _jumps(world: VoxelWorld, nav: Navigation, start: Vector3i) -> void:
	# A flat pad cut in two by a ditch one cell wide: there is no way to walk across, but a unit can jump over it.
	var b := nav.nearest_standable(Vector3i(start.x + 4, start.y, start.z + 14), 3)
	for dz in range(-3, 4):
		for dx in range(-6, 7):
			for y in range(b.y - 5, b.y + 4):
				var p := Vector3i(b.x + dx, y, b.z + dz)
				world.set_block(p, Blocks.make(Blocks.STONE) if y < b.y else Blocks.AIR)
	for dz in range(-3, 4):
		for y in range(b.y - 5, b.y):
			world.set_block(Vector3i(b.x, y, b.z + dz), Blocks.AIR)   # the ditch, bottomless (no floor to stand on)
	var left := Vector3i(b.x - 1, b.y, b.z)
	var right := Vector3i(b.x + 1, b.y, b.z)
	check(nav.standable(left) and nav.standable(right) and not nav.standable(b), "the two sides are floors and the ditch between them is not")
	var walk_across := false
	for r in nav.neighbours(left):
		if r[0].x == right.x and r[0].z == right.z:
			walk_across = true
	check(walk_across, "a one-cell ditch can be jumped (the jump is one of the moves from the edge)")
	var found := nav.find_path(Vector3i(b.x - 5, b.y, b.z), Vector3i(b.x + 5, b.y, b.z))
	var jumps := 0
	for i in range(1, found.size()):
		if absi(found[i].x - found[i - 1].x) == 2 or absi(found[i].z - found[i - 1].z) == 2:
			jumps += 1
	check(nav.last_reached and jumps == 1, "a way across exists, with exactly one jump (%d)" % jumps)
	check(_valid_path(nav, found) == "", "...and every step of it is legal")
	# Two cells wide is too far.
	for dz in range(-3, 4):
		for y in range(b.y - 5, b.y):
			world.set_block(Vector3i(b.x + 1, y, b.z + dz), Blocks.AIR)
	check(nav.jump(left, Vector2i(1, 0))[0].x < 0, "a ditch two cells wide cannot be jumped")
	# One cell wide again, with the far side one block higher: the jump goes up as well.
	for dz in range(-3, 4):
		for dx in range(1, 7):
			for y in range(b.y - 5, b.y + 1):
				world.set_block(Vector3i(b.x + dx, y, b.z + dz), Blocks.make(Blocks.STONE))
			for y in range(b.y + 1, b.y + 5):
				world.set_block(Vector3i(b.x + dx, y, b.z + dz), Blocks.AIR)
	var from_edge := nav.jump(left, Vector2i(1, 0))
	check(from_edge[0] == Vector3i(b.x + 1, b.y + 1, b.z), "the jump over one cell can land one block higher %s" % str(from_edge[0]))
	# A unit does it for real.
	var manager := UnitManager.new()
	add(manager)
	manager.setup(world, null)
	var u := manager.spawn(Vector3i(b.x - 4, b.y, b.z))
	var goal := Vector3i(b.x + 4, b.y + 1, b.z)
	var done := [false]
	u.arrived.connect(func() -> void: done[0] = true)
	var ok := u.walk_to(goal) if nav.standable(goal) else false
	var peak := 0.0
	var frames := 0
	while ok and not done[0] and frames < 2000:
		u._process(0.05)
		peak = maxf(peak, u.position.y)
		frames += 1
	check(done[0] and u.cell == goal, "a unit walks across the ditch and up the step, jumping once (%d frames)" % frames)
	check(peak > b.y + 0.5, "it really leaves the ground for the jump (peak %.2f over floor %d)" % [peak, b.y])
