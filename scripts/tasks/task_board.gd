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
var _return_to := {}                 ## Unit -> the task it left for a detour (a log taken to a stump), to go back to


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
	for t in tasks:
		t.update(self)
	# A finished task goes once nobody is still carrying something from it to a stockpile.
	for t in tasks.duplicate():
		if t.is_finished() and not t.workers.any(func(u: Unit) -> bool: return u.carried_amount() > 0):
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
	t.board = self
	t.id = _next_id
	_next_id += 1
	if with_overlay:
		_make_overlay(t)
	tasks.append(t)
	t.redraw(self)
	changed.emit()


## Marks the surface block of every column in the rectangle (columns x0..x1, z0..z1, inclusive). Returns the task, or null
## when there was nothing to dig there.
func create_dig(x0: int, z0: int, x1: int, z1: int, depth := 1) -> DigTask:
	var t := DigTask.new()
	var lo := Vector2i(mini(x0, x1), mini(z0, z1))
	var hi := Vector2i(maxi(x0, x1), maxi(z0, z1))
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			t.columns.append(Vector2i(x, z))
	t.depth = maxi(depth, 1)
	if t.depth > 1:
		_plan_staircase(t, lo, hi)
	t.update(self)   # opens layer 1
	if t.cells.is_empty():
		return null
	add_task(t)
	return t


## The staircase goes along the edge of the area from its low corner, first along the longer side: the first column is not dug at
## all, each next column is dug one layer deeper and ends in a stair piece, so a column is a step. Where the edge ends (a corner) and
## there is still depth to go, the stairs turn and the corner column is a flat landing as deep as the column before it. The depth
## is cut back when the whole edge is too short for stairs that deep.
func _plan_staircase(t: DigTask, lo: Vector2i, hi: Vector2i) -> void:
	var w := hi.x - lo.x + 1
	var h := hi.y - lo.y + 1
	var first := Vector2i(1, 0) if w >= h else Vector2i(0, 1)
	var second := Vector2i(0, 1) if w >= h else Vector2i(1, 0)
	# The edge as a walk: out along the first side, along the second, back along the first, back along the second.
	var path: Array[Vector2i] = [lo]
	var legs := [[first, (w if w >= h else h) - 1], [second, (h if w >= h else w) - 1], [-first, (w if w >= h else h) - 1], [-second, (h if w >= h else w) - 1]]
	var at := lo
	var corners := {}
	for leg in legs:
		for i in range(1, int(leg[1]) + 1):
			at += leg[0]
			path.append(at)
		corners[at] = true
	if path.size() > 1 and path[-1] == lo:
		path.pop_back()   # the walk round the edge ends where it began
	var layers := 0
	var wanted := t.depth
	var prev := lo
	t.limits[lo] = 0
	t.stair_columns.append(lo)
	var reached := 0
	for i in range(1, path.size()):
		if reached >= wanted:
			break
		var col := path[i]
		var step := col - prev
		var is_corner: bool = corners.has(col) and i < path.size() - 1
		# A corner is a landing, but only when the stairs go on round it; the last column of a leg that is also the last needed is a step.
		var needs_more := reached + 1 < wanted
		if is_corner and needs_more:
			t.limits[col] = layers
			t.stair_columns.append(col)
		else:
			layers += 1
			reached += 1
			t.limits[col] = layers
			t.stair_columns.append(col)
			t.stair_rise[col] = -step
		prev = col
	t.depth = maxi(reached, 1)
	if t.depth <= 1 and reached == 0:
		t.limits.erase(lo)
		t.stair_columns.clear()
		t.stair_rise.clear()
		t.depth = 1


## Marks the trees (or the grass) in `rect` (x, z in blocks) for harvesting. Null when there are none there.
func create_harvest(kind: int, rect: Rect2) -> HarvestTask:
	if props == null or not props.is_built():
		return null
	var t := HarvestTask.new(kind)
	if kind == HarvestTask.Kind.TREES:
		for i in props.trees_in_rect(rect):
			t.add_tree(i, props.trees[i].origin)
	else:
		for i in props.tufts_in_rect(rect):
			t.add_plant(i, props.tufts[i].origin)
	if t.targets.is_empty():
		return null
	add_task(t)
	return t


## A standing harvest job over a circle (x, z in blocks): everything of the kind that is in it, until the player closes it.
func create_harvest_circle(kind: int, center: Vector2, radius: float) -> HarvestTask:
	if props == null or not props.is_built():
		return null
	var t := HarvestTask.new(kind, center, clampf(radius, HarvestTask.MIN_RADIUS, HarvestTask.MAX_RADIUS))
	add_task(t)
	t.scan(self)
	return t


## Sets a station up (paying for it) and gives it its standing job.
func place_station(kind: int, origin: Vector3i, pay := true) -> Station:
	var st := economy.place_station(kind, origin, pay)
	if st == null:
		return null
	_give_station_its_job(st)
	return st


func _give_station_its_job(st: Station) -> void:
	var t := CraftTask.new(st)
	st.task = t
	add_task(t, false)


## The player's way to build: a blueprint, and the job of bringing what it costs. Units come by themselves when the stockpiles have it.
func place_blueprint(type: String, kind: int, origin: Vector3i) -> Blueprint:
	var bp := economy.place_blueprint(type, kind, origin)
	if bp == null:
		return null
	add_task(BuildTask.new(bp), false)
	return bp


## A blueprint has all it needs: the building stands (a station also gets its standing job).
func finish_blueprint(bp: Blueprint) -> void:
	var made := economy.finish_blueprint(bp)
	if made is Station:
		_give_station_its_job(made)


## The player's way to wall: a plan of bricks and cubes, and the standing job of laying them.
func place_wall(from: Vector3i, to: Vector3i, height: int) -> WallPlan:
	var plan := economy.place_wall(from, to, height)
	if plan == null:
		return null
	add_task(WallTask.new(plan), false)
	return plan


## A stair block (stair piece + stone cube) as a plan with its job.
func place_stairs(at: Vector3i, rise: Vector2i) -> WallPlan:
	var plan := economy.place_stairs(at, rise)
	if plan == null:
		return null
	add_task(WallTask.new(plan), false)
	return plan


## One block of the catalog as a plan with its job.
func place_block(id: String, at: Vector3i, dir: Vector2i) -> WallPlan:
	var plan := economy.place_block(id, at, dir)
	if plan == null:
		return null
	add_task(WallTask.new(plan), false)
	return plan


func cancel_wall(plan: WallPlan) -> void:
	for t in tasks.duplicate():
		if t is WallTask and t.plan == plan:
			remove_task(t)
	economy.cancel_wall(plan)


func cancel_blueprint(bp: Blueprint) -> void:
	for t in tasks.duplicate():
		if t is BuildTask and t.blueprint == bp:
			remove_task(t)
	economy.cancel_blueprint(bp)


func remove_station(st: Station) -> void:
	if st.task != null:
		remove_task(st.task)
	economy.remove_station(st)


func remove_task(t: WorkTask) -> void:
	for u in t.workers.duplicate():
		unassign(u)
	if t is WallTask and is_instance_valid(t.plan):
		economy.cancel_wall(t.plan)   # the plan goes with its job
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
	_return_to.erase(u)
	var w: Worker = _workers.get(u)
	if w == null:
		return
	w.detach()
	w.task.workers.erase(u)
	_workers.erase(u)
	changed.emit()


## How many loads of `amount` of `kind` the workers of a task already have in their hands or are on the way to fetch.
func supplies_coming(t: WorkTask, kind: int, amount: int, except: Unit = null) -> int:
	var n := 0
	for u in t.workers:
		if u == except:
			continue
		var w: Worker = _workers.get(u)
		if u.carried_kind() == kind and u.carried_amount() >= amount:
			n += 1
		elif w != null and (w.state == Worker.State.GO_FETCH or w.state == Worker.State.TAKE) and w.fetching_kind() == kind:
			n += 1
	return n


## A stump that is free to take a log right now and has room to put the planks: its task, or null.
func free_stump() -> CraftTask:
	for t in tasks:
		var ct := t as CraftTask
		if ct != null and is_instance_valid(ct.station) and ct.station.kind == Station.Kind.STUMP and ct.workers.size() < ct.max_workers and ct.claimed_by == null:
			var d: Dictionary = ct.station.def()
			if economy.find_space(Vector3i(ct.station.origin), d.output.kind, d.output.amount) != null:
				return ct
	return null


## Can a log that is picked up now be taken somewhere? To a stump that is free (and the planks have room), or to a stockpile.
func log_has_destination(from: Vector3i) -> bool:
	return free_stump() != null or economy.find_space(from, Resources.Kind.LOG, 1) != null


## A worker with a log in its hands goes to a free stump first, to make planks of it; afterwards it returns to its job.
func detour_to_stump(u: Unit) -> bool:
	var craft := free_stump()
	if craft == null:
		return false
	var back := task_of(u)
	unassign(u)
	if not assign(u, craft):
		if back != null and tasks.has(back):
			assign(u, back)
		return false
	_return_to[u] = back
	return true


## A worker of a standing job (a station) has nothing more to do: back to what it was doing before, or free.
func resume_or_free(u: Unit) -> void:
	var back: WorkTask = _return_to.get(u)
	unassign(u)
	if back != null and tasks.has(back) and not back.is_finished():
		assign(u, back)


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
