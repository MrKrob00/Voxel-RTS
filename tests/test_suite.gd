class_name TestSuite
extends RefCounted
## Base of the headless test suites that run inside tests/run_suites.gd: one world is generated once and shared, each suite gets it
## back in its original state (VoxelWorld.snapshot / restore) and its own scene container, which is thrown away afterwards.
##
## A suite overrides `run()` (a coroutine) and uses `check(cond, what)`; `ctx` is the TestContext.

var ctx: TestContext
var failed := false
var checks := 0


func check(cond: bool, what: String) -> void:
	checks += 1
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		failed = true


## Override: the checks.
func run() -> void:
	pass


## The scene tree, for `await tree.process_frame` and the like.
var tree: SceneTree:
	get:
		return ctx.tree


## A node of this suite's own: it is freed when the suite ends.
func add(n: Node) -> Node:
	ctx.scene.add_child(n)
	return n
