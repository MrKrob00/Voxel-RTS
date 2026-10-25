extends SceneTree
## Headless: godot --headless --path . -s res://tests/run_suites.gd [-- navigation work quarry craft brick]
## The suites that need a world share ONE: it is generated once (a small map with one extra island and its trees, no meshes), and
## every suite gets it back in its original state and its own scene container, which is freed afterwards. Prints one line per suite,
## exits with 1 if any check failed.

const SUITES := {
	"navigation": "res://tests/suites/navigation_suite.gd",
	"work": "res://tests/suites/work_suite.gd",
	"quarry": "res://tests/suites/quarry_suite.gd",
	"craft": "res://tests/suites/craft_suite.gd",
	"logs": "res://tests/suites/logs_suite.gd",
	"build": "res://tests/suites/build_suite.gd",
	"brick": "res://tests/suites/brick_suite.gd",
}


func _init() -> void:
	var wanted := OS.get_cmdline_user_args()
	var t0 := Time.get_ticks_msec()
	var world := VoxelWorld.new()
	world.size_chunks = Vector3i(16, 7, 16)   # 256 x 256 blocks: room for the suites, a fraction of the full map's generation time
	world.extra_islands = 1
	world.meshing_enabled = false
	root.add_child(world)
	while not world.is_ready():
		await process_frame
	var props := PropField.new()
	root.add_child(props)
	props.setup(world)
	while not props.is_built():
		await process_frame
	while not world.is_settled():
		await process_frame
	var snapshot := world.snapshot()
	print("shared world ready in %d ms" % (Time.get_ticks_msec() - t0))

	var ctx := TestContext.new()
	ctx.tree = self
	ctx.world = world
	ctx.props = props
	var failed_suites := 0
	var summary := PackedStringArray()
	for suite_name in SUITES:
		if not wanted.is_empty() and not wanted.has(suite_name):
			continue
		print("== ", suite_name)
		var t1 := Time.get_ticks_msec()
		ctx.scene = Node3D.new()
		root.add_child(ctx.scene)
		var suite: TestSuite = load(SUITES[suite_name]).new()
		suite.ctx = ctx
		await suite.run()
		Engine.time_scale = 1.0
		ctx.scene.free()
		world.restore(snapshot)
		props.reset()
		for i in 3:
			await process_frame
		var ok := not suite.failed
		failed_suites += 0 if ok else 1
		summary.append("%s %s (%d checks, %.1f s)" % ["PASS" if ok else "FAIL", suite_name, suite.checks, (Time.get_ticks_msec() - t1) / 1000.0])
	print("--")
	for line in summary:
		print(line)
	print("SUITES DONE: %d failed, total %.1f s" % [failed_suites, (Time.get_ticks_msec() - t0) / 1000.0])
	while not world.is_settled():
		await process_frame
	quit(1 if failed_suites > 0 else 0)
