extends TestSuite
## Suite of tests/run_suites.gd (godot --headless --path . -s res://tests/run_suites.gd -- navcache).
## What Navigation remembers so that searches cost less: the cells that can be reached from a place where the goal cannot be reached,
## and the ways that were walked to a goal (a later search that meets one follows it).

var _world: VoxelWorld
var _nav: Navigation
var _bricks: BrickWorld
var _base: Vector3i


func run() -> void:
	_world = ctx.world
	var waited := 0
	while not _world.nav_bits.ready and waited < 3000:
		await tree.process_frame
		waited += 1
	_bricks = BrickWorld.new()
	add(_bricks)
	_bricks.setup(_world)
	_nav = Navigation.new(_world, _bricks)
	var sp := _world.spawn_point()
	_base = Vector3i(sp.x - 14, sp.y + 1, sp.z - 14)
	for dz in 30:
		for dx in 30:
			for y in range(sp.y - 2, sp.y + 8):
				_world.set_block(Vector3i(_base.x + dx, y, _base.z + dz), Blocks.make(Blocks.GRASS) if y == sp.y else (Blocks.make(Blocks.DIRT) if y < sp.y else Blocks.AIR))
	_cut_off()
	_routes()


## A pen with walls three blocks high; the goal is outside.
func _cut_off() -> void:
	var b := _base
	for i in range(0, 9):
		for h in 3:
			for p in [Vector3i(b.x + 2 + i, b.y + h, b.z + 2), Vector3i(b.x + 2 + i, b.y + h, b.z + 10), Vector3i(b.x + 2, b.y + h, b.z + 2 + i), Vector3i(b.x + 10, b.y + h, b.z + 2 + i)]:
				_world.set_block(p, Blocks.make(Blocks.STONE))
	var a := Vector3i(b.x + 4, b.y, b.z + 4)
	var c := Vector3i(b.x + 8, b.y, b.z + 7)
	var goal := Vector3i(b.x + 24, b.y, b.z + 24)
	check(_nav.standable(a) and _nav.standable(c) and _nav.standable(goal), "two places in the pen and a goal outside it can be stood in")
	var first := _nav.find_path(a, goal)
	var looked_first := _nav.last_expanded
	check(not _nav.last_reached and not first.is_empty(), "the goal behind the wall cannot be reached; the way goes as near as it can (%d cells, %d looked at)" % [first.size(), looked_first])
	var second := _nav.find_path(c, goal)
	var looked_second := _nav.last_expanded
	check(not _nav.last_reached and not second.is_empty(), "the same from another place in the pen")
	check(looked_second < looked_first / 3, "which does not look at the whole pen again (%d against %d cells looked at)" % [looked_second, looked_first])
	var near_a: Vector3i = first[-1]
	var near_c: Vector3i = second[-1]
	check(Vector2(near_a.x - goal.x, near_a.z - goal.z).distance_to(Vector2(near_c.x - goal.x, near_c.z - goal.z)) < 2.0, "and ends as near the goal as the first (%s, %s)" % [str(near_a), str(near_c)])
	# The wall is opened: what was learned is no longer true, and the goal is reached.
	_world.set_block(Vector3i(b.x + 10, b.y, b.z + 6), Blocks.AIR)
	_world.set_block(Vector3i(b.x + 10, b.y + 1, b.z + 6), Blocks.AIR)
	var opened := _nav.find_path(c, goal)
	check(_nav.last_reached and opened[-1] == goal, "after a door is made in the wall the goal is reached (what was learned is dropped)")


## A way that was walked is followed by a later search to a place near its end, from a place on it or near it.
func _routes() -> void:
	var b := _base
	var a := Vector3i(b.x + 13, b.y, b.z + 1)
	var goal := Vector3i(b.x + 28, b.y, b.z + 28)
	var s1 := _nav.begin_search(a, goal)
	s1.advance(-1)
	check(s1.reached and s1.path.size() > 20, "a way across the flat ground is found (%d cells, %d looked at)" % [s1.path.size(), s1.expanded])
	_nav.remember(s1)
	# a unit that starts a few cells further on, and wants a place two cells from the goal
	var from2: Vector3i = s1.path[6]
	var goal2 := Vector3i(goal.x - 2, goal.y, goal.z - 1)
	var s2 := _nav.begin_search(from2, goal2)
	s2.advance(-1)
	check(s2.reached and s2.path[-1] == goal2 and s2.path[0] == from2, "a search that starts on it reaches a place near the end of it")
	check(s2.expanded < s1.expanded / 3, "and looks at far fewer cells (%d against %d)" % [s2.expanded, s1.expanded])
	var legal := true
	for i in range(1, s2.path.size()):
		legal = legal and _nav.move_cost(s2.path[i - 1], s2.path[i]) >= 0.0
	check(legal, "every step of the way it found can be walked")
	# someone puts a brick on the way: the search does not follow it through the brick
	var block: Vector3i = s1.path[s1.path.size() / 2]
	_bricks.place(block, 0, BrickWorld.Kind.STONE, 1)
	_bricks.place(block + Vector3i(0, 1, 0), 0, BrickWorld.Kind.STONE, 1)
	var s3 := _nav.begin_search(from2, goal2)
	s3.advance(-1)
	var through := false
	for c in s3.path:
		through = through or c == block
	check(s3.reached and not through, "when something is built on the old way the new search goes round it")
