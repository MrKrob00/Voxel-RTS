class_name TaskBoard
extends Node3D
## The list of jobs and the people on them. The player creates tasks (mark ground to dig, mark trees to fell) and assigns units;
## stations (stump, rope machine) bring a standing task of their own that idle units join by themselves when there is something to
## make. Each assigned unit runs a Worker brain, which this board ticks every frame.

signal changed

const AUTO_ASSIGN_EVERY := 1.0

var world: VoxelWorld
var nav: Navigation
var economy: Economy
var props: PropField                 ## trees and grass that can be harvested (null in tests without them)
var loose: LooseItems                ## logs lying on the ground
var units: UnitManager
var tasks: Array[WorkTask] = []
var now := 0.0                       ## seconds since start, for retry timers
var _workers := {}                   ## Unit -> Worker
var _next_id := 1
var _redraw_timer := 0.0
var _auto_timer := 0.0


func setup(w: VoxelWorld, n: Navigation, e: Economy, p: PropField = null, l: LooseItems = null, u: UnitManager = null) -> void:
	world = w
	nav = n
	economy = e
	props = p
	loose = l
	units = u
	if units != null:
		units.ordered.connect(unassign)   # a move order from the player ends the job


func _process(delta: float) -> void:
	now += delta
	for u in _workers.keys():
		var worker: Worker = _workers[u]
		worker.update(delta)
	# A finished task goes once nobody is still carrying something from it to a stockpile.
	for t in tasks.duplicate():
		if not t.persistent and t.is_finished() and not t.workers.any(func(u: Unit) -> bool: return u.carried_amount() > 0):
			remove_task(t)
	_auto_timer -= delta
	if _auto_timer <= 0.0:
		_auto_timer = AUTO_ASSIGN_EVERY
		_auto_assign()
	_redraw_timer -= delta
	if _redraw_timer <= 0.0:
		_redraw_timer = 0.3
		for t in tasks:
			t.redraw(self)


func _make_overlay(t: WorkTask) -> void:
	t.overlay = MeshInstance3D.new()
	t.overlay.name = "Task%d" % t.id
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	t.overlay.material_override = m
	add_child(t.overlay)


func add_task(t: WorkTask, with_overlay := true) -> void:
	t.id = _next_id
	_next_id += 1
	if with_overlay:
		_make_overlay(t)
	tasks.append(t)
	t.redraw(self)
	changed.emit()


## Marks the surface block of every column in the rectangle (columns x0..x1, z0..z1, inclusive). Returns the task, or null
## when there was nothing to dig there.
func create_dig(x0: int, z0: int, x1: int, z1: int) -> DigTask:
	var t := DigTask.new()
	for z in range(mini(z0, z1), maxi(z0, z1) + 1):
		for x in range(mini(x0, x1), maxi(x0, x1) + 1):
			var c := world.terrain.surface_target(x, z)
			if c.x >= 0 and world.terrain.can_dig(c):
				t.cells[c] = null
	if t.cells.is_empty():
		return null
	add_task(t)
	return t


func remove_task(t: WorkTask) -> void:
	for u in t.workers.duplicate():
		unassign(u)
	tasks.erase(t)
	if t.overlay != null:
		t.overlay.queue_free()
	changed.emit()


func task_of(u: Unit) -> WorkTask:
	var w: Worker = _workers.get(u)
	return w.task if w != null else null


func assign(u: Unit, t: WorkTask) -> bool:
	if task_of(u) == t:
		return true
	if t.workers.size() >= t.max_workers:
		return false
	unassign(u)
	t.workers.append(u)
	_workers[u] = Worker.new(u, t, self)
	changed.emit()
	return true


func unassign(u: Unit) -> void:
	var w: Worker = _workers.get(u)
	if w == null:
		return
	w.detach()
	w.task.workers.erase(u)
	_workers.erase(u)
	changed.emit()


## Idle units (no job, no order) join a station that has something to make: the nearest unit to each.
func _auto_assign() -> void:
	if units == null:
		return
	for t in tasks:
		if not t.persistent or t.workers.size() >= t.max_workers or not t.wants_workers(self):
			continue
		var best: Unit = null
		var best_d := INF
		var spot: Vector3 = t.face_point(null)
		for u in units.units:
			if not u.is_idle() or _workers.has(u) or u.carried_amount() > 0:
				continue
			var d := Vector2(u.position.x - spot.x, u.position.z - spot.z).length()
			if d < best_d:
				best_d = d
				best = u
		if best != null:
			assign(best, t)
