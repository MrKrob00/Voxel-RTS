class_name Navigation
extends RefCounted
## Where units can stand and how they walk from A to B over the voxel ground, slopes, pits, bricks and bridges.
##
## A NODE is the cell the unit's feet are in. A cell can be stood in when
##   - it is open air, or a ground piece (slope / half-dug block, which the unit stands IN), never a whole block, a brick or water;
##   - the cell above it is free (the unit is one block tall plus a hat);
##   - in open air there is a whole block or a brick under it (a ground piece or a flight of brick steps carries itself).
## Moves go to the 8 neighbouring columns and change height by at most MAX_STEP_UP up (a hop onto a block) or MAX_DROP down.
## A diagonal needs both of the cells beside it to be free, so nobody cuts a corner through a wall.
## When there is no way to walk in a straight direction, a unit may JUMP over a gap of one cell (a hole, a missing block, a one-cell
## ditch) to the cell beyond it, at the same height or one block up or down. It costs more than walking, so it is only used when it
## saves a long way round.
## Pure rules on voxel data: no scene access, so it can run on a worker thread and in headless tests.

const MAX_STEP_UP := 1
const MAX_DROP := 3
const NODE_LIMIT := 60000   ## a search gives up (and returns the closest it got) after expanding this many nodes
const SQRT2 := 1.41421356
const JUMP_COST := 3.2

const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
]

var world: VoxelWorld
var bricks:   ## optional: bricks are obstacles and floors (a BrickWorld, or a BrickSnapshot in the copy a thread reads)
	set(value):
		bricks = value
		_brick_cells = value.cell_set() if value != null else {}
var obstacle := Callable()   ## optional (cell) -> bool: other things that fill a cell (a stockpile frame, a station)
## optional: whoever the cells of `obstacle` come from, with blocked_cells() -> Dictionary and obstacle_signature() -> int (the Economy);
## the cells are then kept in a set (and the search asks the set, not the buildings). A thread reads a copy of it.
var obstacle_source: Object
var _size: Vector3i
var _brick_cells := {}              ## the cells the bricks fill (the very dictionary of the BrickWorld, or the copy of it)
var _obstacle_cells := {}           ## the cells of the buildings, when `obstacle_source` is known
var _obstacle_signature := -1
const MAX_COMPONENTS := 6          ## sets of reachable cells remembered (see PathSearch.component)
var _components: Array[PackedInt32Array] = []
var _components_signature := -1
## The ways walked to a goal lately ({goal, path, t}): a search to a goal near one of them joins it where it meets it.
const MAX_ROUTES := 24
const ROUTE_GOAL_RADIUS := 3.0   ## columns between the goal of a way and the new goal for the way to be of use
const ROUTE_AGE_MSEC := 90000
const ROUTES_PER_SEARCH := 6
var _routes: Array[Dictionary] = []

## Result of the last find_path: false when the goal could not be reached and the path only gets as near as it could.
var last_reached := false
var last_expanded := 0


func _init(w: VoxelWorld, b = null) -> void:
	world = w
	bricks = b
	_size = w.size_blocks()


# --- cells ------------------------------------------------------------------------------------------

## What the ground says about standing in a cell (NavBits), -1 when that is not known (yet).
func _bits_of(c: Vector3i) -> int:
	var nb := world.nav_bits
	return nb.get_bits(c.x, c.y, c.z) if nb != null else -1


## Takes the cells of the buildings again if any of them changed (when `obstacle_source` is known).
func refresh_obstacles() -> void:
	if obstacle_source == null:
		return
	var sig: int = obstacle_source.call("obstacle_signature")
	if sig != _obstacle_signature:
		_obstacle_signature = sig
		_obstacle_cells = obstacle_source.call("blocked_cells")


func _obstacle(c: Vector3i) -> bool:
	if obstacle_source != null:
		return _obstacle_cells.has(c)
	return obstacle.call(c) if obstacle.is_valid() else false


func _brick(c: Vector3i) -> bool:
	return _brick_cells.has(c)


func _flight(c: Vector3i) -> Dictionary:
	if bricks == null:
		return {}
	return bricks.flight_at(c) if bricks.has_method("flight_at") else {}


func _floor_brick(c: Vector3i) -> bool:
	# a brick under the feet counts as a floor
	var below := c + Vector3i(0, -1, 0)
	return _brick(below)


func blocked(c: Vector3i) -> bool:
	if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= _size.x or c.y >= _size.y or c.z >= _size.z:
		return true
	if world.is_solid(c) or _brick(c) or world.is_water(c) or _obstacle(c):
		return true
	return false


func _feet_free(c: Vector3i) -> bool:
	# the cell of the feet and the one above (hat) must be free
	if blocked(c):
		return false
	var above := c + Vector3i(0, 1, 0)
	if above.y >= _size.y:
		return false
	return not blocked(above)


## True when a unit's feet can be in this cell.
func standable(c: Vector3i) -> bool:
	var b := _bits_of(c)
	if b >= 0:
		return (b & NavBits.STANDABLE) != 0
	return _standable_by_blocks(c)


func _standable_by_blocks(c: Vector3i) -> bool:
	if not _feet_free(c):
		return false
	var below := c + Vector3i(0, -1, 0)
	if below.y < 0:
		return false
	if world.is_solid(below) or _brick(below):
		return true
	# ground piece (slope / half) carries itself
	if world.has_method("is_ground_piece") and world.is_ground_piece(c):
		return true
	return false


func feet_height(c: Vector3i, wx: float, wz: float) -> float:
	# continuous height for smooth walking on slopes
	if world.has_method("feet_height"):
		return world.feet_height(c, wx, wz)
	return float(c.y)


func feet_position(c: Vector3i) -> Vector3:
	return Vector3(c.x + 0.5, feet_height(c, c.x + 0.5, c.z + 0.5), c.z + 0.5)


func standable_in_column(x: int, z: int, y_hint: int, up := 3, down := 5) -> Vector3i:
	for dy in range(0, up + 1):
		var t := Vector3i(x, y_hint + dy, z)
		if standable(t):
			return t
	for dy in range(1, down + 1):
		var t := Vector3i(x, y_hint - dy, z)
		if standable(t):
			return t
	return Vector3i(x, y_hint, z)


func nearest_standable(c: Vector3i, radius := 4) -> Vector3i:
	if standable(c):
		return c
	for r in range(1, radius + 1):
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if absi(dx) != r and absi(dz) != r:
					continue
				var t := standable_in_column(c.x + dx, c.z + dz, c.y)
				if standable(t):
					return t
	return c


func work_cells(target: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for d in DIRS:
		var n := target + Vector3i(d.x, 0, d.y)
		var s := nearest_standable(n, 2)
		if standable(s):
			out.append(s)
	return out


func standing_for_hit(hit: Dictionary) -> Vector3i:
	var pos: Vector3 = hit.get("position", Vector3.ZERO)
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	var c := Vector3i(floori(pos.x), floori(pos.y), floori(pos.z))
	if normal.y > 0.5:
		return nearest_standable(c + Vector3i(0, 1, 0), 2)
	return nearest_standable(c, 2)


func step(c: Vector3i, d: Vector2i) -> Array:
	var to := c + Vector3i(d.x, 0, d.y)
	if absi(d.x) + absi(d.y) == 2:
		var a := c + Vector3i(d.x, 0, 0)
		var b := c + Vector3i(0, 0, d.y)
		if not (standable(a) or standable(b)):
			# both side columns blocked at feet height - corner cut not allowed
			if blocked(a) and blocked(b):
				return [c, -1.0]
	var best: Vector3i = c
	var best_cost := -1.0
	for dy in range(-MAX_DROP, MAX_STEP_UP + 1):
		var t := to + Vector3i(0, dy, 0)
		if not standable(t):
			continue
		var cost := SQRT2 if absi(d.x) + absi(d.y) == 2 else 1.0
		if dy > 0:
			cost += dy * 0.5
		elif dy < 0:
			cost += absi(dy) * 0.15
		if best_cost < 0 or cost < best_cost:
			best = t
			best_cost = cost
	return [best, best_cost]


func neighbours(c: Vector3i) -> Array:
	var out: Array = []
	for d in DIRS:
		var r := step(c, d)
		if r[1] >= 0.0:
			out.append(r)
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var j := jump(c, d)
		if j[1] >= 0.0:
			out.append(j)
	return out


func jump(c: Vector3i, d: Vector2i) -> Array:
	if absi(d.x) + absi(d.y) != 1:
		return [c, -1.0]
	var mid := c + Vector3i(d.x, 0, d.y)
	var to := c + Vector3i(d.x * 2, 0, d.y * 2)
	if standable(mid):
		return [c, -1.0]
	var best: Vector3i = c
	var best_cost := -1.0
	for dy in range(-1, 2):
		var t := to + Vector3i(0, dy, 0)
		if not standable(t):
			continue
		var cost := JUMP_COST + absi(dy) * 0.3
		if best_cost < 0 or cost < best_cost:
			best = t
			best_cost = cost
	return [best, best_cost]


func _key(c: Vector3i) -> int:
	return c.x + c.z * _size.x + c.y * _size.x * _size.z


func _cell(key: int) -> Vector3i:
	var xz := _size.x * _size.z
	var y := key / xz
	var r := key % xz
	return Vector3i(r % _size.x, y, r / _size.x)


static func _heuristic(a: Vector3i, b: Vector3i) -> float:
	var dx := absi(a.x - b.x)
	var dz := absi(a.z - b.z)
	var dy := absi(a.y - b.y)
	var diag := mini(dx, dz)
	return float(dx + dz - diag) + float(diag) * SQRT2 + float(dy) * 0.5


func find_path(from: Vector3i, to: Vector3i, stop_near := 0.0) -> Array[Vector3i]:
	var s := _begin(from, to, stop_near, true)
	s.advance(-1)
	learn(s)
	last_reached = s.reached
	last_expanded = s.expanded
	return s.path


## A search that is done in slices of time, or on a worker thread (see PathSearch).
func begin_search(from: Vector3i, to: Vector3i, stop_near := 0.0) -> PathSearch:
	return _begin(from, to, stop_near, false)


func _begin(from: Vector3i, to: Vector3i, stop_near: float, here: bool) -> PathSearch:
	refresh_obstacles()
	var sig := signature()
	if sig != _components_signature:
		_components.clear()
		_components_signature = sig
	var s: PathSearch
	if here or not use_threads():
		s = PathSearch.new(self, from, to, stop_near)
	else:
		s = PathSearch.new(view(), from, to, stop_near)
		s.threaded = true
	s.signature = sig
	# Route grafting and component cut-off made paths "stupid": a unit would join a long
	# remembered way to a nearby goal (or give up on a reachable goal when a stale component
	# said it was cut off). NavBits still speeds standable; A* runs clean again.
	# (do not set s.routes or s.restrict)
	return s


## The recent ways to a goal near `to` (their cells), newest first.
func routes_for(to: Vector3i, _stop_near: float) -> Array:
	var out: Array = []
	var now := Time.get_ticks_msec()
	for i in range(_routes.size() - 1, -1, -1):
		var r := _routes[i]
		if now - int(r.t) > ROUTE_AGE_MSEC:
			continue
		var g: Vector3i = r.goal
		if Vector2(g.x - to.x, g.z - to.z).length() <= ROUTE_GOAL_RADIUS and absi(g.y - to.y) <= 2:
			out.append(r.path)
			if out.size() >= ROUTES_PER_SEARCH:
				break
	return out


## What the world, the bricks and the buildings look like now, as one number: what is worked out from them is only good while it stays.
func signature() -> int:
	var sig := world.edit_serial * 1000003 + _obstacle_signature
	if bricks != null:
		sig = sig * 31 + bricks.signature()
	return sig


## The way a unit is going to walk to a goal it can reach: later searches to a place near it follow it where they meet it.
func remember(search: PathSearch) -> void:
	if not search.reached or search.path.size() < 4:
		return
	var path := search.path.duplicate()
	for i in range(_routes.size() - 1, -1, -1):
		if _routes[i].path[0] == path[0] and _routes[i].path[-1] == path[-1]:
			_routes.remove_at(i)
	_routes.append({"goal": search.to, "path": path, "t": Time.get_ticks_msec()})
	if _routes.size() > MAX_ROUTES:
		_routes.pop_front()


## The price of walking from one cell to the next one of a way, or -1 when that cannot be done now (a step, a hop or a jump of the rules).
func move_cost(a: Vector3i, b: Vector3i) -> float:
	var dx := b.x - a.x
	var dz := b.z - a.z
	if absi(dx) <= 1 and absi(dz) <= 1 and (dx != 0 or dz != 0):
		var r := step(a, Vector2i(dx, dz))
		return r[1] if r[0] == b else -1.0
	if (dx == 0) != (dz == 0) and (absi(dx) == 2 or absi(dz) == 2):
		var j := jump(a, Vector2i(signi(dx), signi(dz)))
		return j[1] if j[0] == b else -1.0
	return -1.0


## A finished search tells what it found out. Called on the main thread with every search a unit has used.
func learn(search: PathSearch) -> void:
	if search.component.is_empty() or search.signature != signature():
		return
	_components.append(search.component)
	if _components.size() > MAX_COMPONENTS:
		_components.pop_front()


## Searches run on worker threads where something is drawn (the game); the tests step the world by hand, in order, and ask for the
## same answer every time, so there they run in slices on the calling thread.
var threaded := DisplayServer.get_name() != "headless"
var _view: Navigation
var _view_signature := []


func use_threads() -> bool:
	return threaded and (not obstacle.is_valid() or obstacle_source != null)


## The navigation a thread may read: the same rules over a copy of the bricks and of the cells of the buildings, made when something
## of them has changed (the voxels themselves are read as they are).
func view() -> Navigation:
	refresh_obstacles()
	var sig := [bricks.signature() if bricks != null else 0, _obstacle_signature]
	if _view == null or sig != _view_signature:
		_view = Navigation.new(world)
		_view.threaded = false
		_view._brick_cells = _brick_cells.duplicate()
		_view._obstacle_cells = _obstacle_cells.duplicate()
		_view._obstacle_signature = _obstacle_signature
		_view.obstacle = obstacle
		_view.obstacle_source = null
		_view_signature = sig
	return _view


func run_search(search: PathSearch, usec: int) -> void:
	if search.done:
		return
	search.advance(usec)


# --- binary heap for A* open set (used by PathSearch via static helpers) ---------------------------

static func _push(f: PackedFloat32Array, n: PackedInt32Array, cost: float, key: int) -> void:
	f.append(cost)
	n.append(key)
	var i := f.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if f[p] <= f[i]:
			break
		var tf := f[p]
		f[p] = f[i]
		f[i] = tf
		var tn := n[p]
		n[p] = n[i]
		n[i] = tn
		i = p


static func _pop(f: PackedFloat32Array, n: PackedInt32Array) -> int:
	var top := n[0]
	var last := f.size() - 1
	f[0] = f[last]
	n[0] = n[last]
	f.resize(last)
	n.resize(last)
	var i := 0
	while true:
		var l := (i << 1) + 1
		if l >= f.size():
			break
		var r := l + 1
		var m := l if r >= f.size() or f[l] <= f[r] else r
		if f[i] <= f[m]:
			break
		var tf := f[m]
		f[m] = f[i]
		f[i] = tf
		var tn := n[m]
		n[m] = n[i]
		n[i] = tn
		i = m
	return top
