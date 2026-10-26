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
	return obstacle.is_valid() and obstacle.call(c)


func _brick(c: Vector3i) -> bool:
	return _brick_cells.has(c) or _obstacle(c)


## The flight of steps in a cell ({} if none): the unit stands IN that cell and walks up the steps.
func _flight(c: Vector3i) -> Dictionary:
	return bricks.steps_at(c) if bricks != null and _brick_cells.has(c) else {}


## A brick or other thing that carries the feet of someone standing on top of it. A flight of steps does not: its top is only reached
## by walking up it.
func _floor_brick(c: Vector3i) -> bool:
	if _obstacle(c):
		return true
	return _brick_cells.has(c) and bricks.steps_at(c).is_empty()


## Blocks a body: any solid ground, whole or partial, a brick, or water.
func blocked(c: Vector3i) -> bool:
	if _brick(c):
		return true
	var bits := _bits_of(c)
	if bits >= 0:
		return bits & NavBits.SOLID != 0
	var raw := world.get_block(c)
	return Blocks.is_solid(raw) or Blocks.mat(raw) == Blocks.WATER


## A ground piece (slope or half-dug block) is a floor the unit stands in: free for feet, not for a head.
func _feet_free(c: Vector3i) -> bool:
	if _obstacle(c):
		return false
	if _brick_cells.has(c) and bricks.steps_at(c).is_empty():
		return false
	var bits := _bits_of(c)
	if bits >= 0:
		return bits & NavBits.FEET != 0
	var raw := world.get_block(c)
	if Blocks.mat(raw) == Blocks.WATER:
		return false
	return not Blocks.is_solid(raw) or Blocks.is_partial(raw)


func standable(c: Vector3i) -> bool:
	if c.x < 0 or c.z < 0 or c.y < 1 or c.x >= _size.x or c.z >= _size.z or c.y + 2 >= _size.y:
		return false
	var bits := _bits_of(c)
	if bits < 0:
		return _standable_by_blocks(c)   # the bits of the ground are not worked out yet
	# the same rules as _standable_by_blocks, with the part that only the ground decides read from `bits` (see NavBits)
	if bits & NavBits.FEET == 0:
		return false
	var flight := false
	if _brick_cells.has(c):
		if bricks.steps_at(c).is_empty():
			return false
		flight = true
	if _obstacle(c):
		return false
	if bits & NavBits.HEAD == 0:
		return false
	var up := Vector3i(c.x, c.y + 1, c.z)
	if _brick_cells.has(up) or _obstacle(up):
		return false
	if bits & NavBits.PIECE != 0 or flight:
		return true
	if bits & NavBits.FLOOR != 0:
		return true
	return _floor_brick(Vector3i(c.x, c.y - 1, c.z))


## The same question answered from the blocks themselves (what `standable` does, slower; used while NavBits is not ready, and by tests
## that check one against the other).
func _standable_by_blocks(c: Vector3i) -> bool:
	if c.x < 0 or c.z < 0 or c.y < 1 or c.x >= _size.x or c.z >= _size.z or c.y + 2 >= _size.y:
		return false
	if _obstacle(c):
		return false
	if _brick_cells.has(c) and bricks.steps_at(c).is_empty():
		return false
	var feet := world.get_block(c)
	if Blocks.mat(feet) == Blocks.WATER or (Blocks.is_solid(feet) and not Blocks.is_partial(feet)):
		return false
	var head := c + Vector3i(0, 1, 0)
	var head_raw := world.get_block(head)
	if _brick(head) or Blocks.is_solid(head_raw) or Blocks.mat(head_raw) == Blocks.WATER:
		return false
	if Blocks.is_partial(feet) or not _flight(c).is_empty():
		return true
	var below := c + Vector3i(0, -1, 0)
	return Blocks.is_whole(world.get_block(below)) or _floor_brick(below)


## y of the unit's feet in world units, at a point (wx, wz) inside the cell.
func feet_height(c: Vector3i, wx: float, wz: float) -> float:
	var flight := _flight(c)
	if not flight.is_empty():
		var rise: Vector2i = flight.rise
		var u := (wx - c.x) if rise.x != 0 else (wz - c.z)
		if rise.x + rise.y < 0:
			u = 1.0 - u
		var n: int = flight.steps
		return c.y + minf(1.0, (floorf(clampf(u, 0.0, 0.9999) * n) + 1.0) / n)
	var raw := world.get_block(c)
	if Blocks.is_partial(raw):
		return c.y + Blocks.surface_height(Blocks.shape(raw), clampf(wx - c.x, 0.0, 1.0), clampf(wz - c.z, 0.0, 1.0), Blocks.is_stairs(raw))
	return float(c.y)


## World position of the feet at the middle of a cell.
func feet_position(c: Vector3i) -> Vector3:
	var wx := c.x + 0.5
	var wz := c.z + 0.5
	return Vector3(wx, feet_height(c, wx, wz), wz)


## The standable cell in a column nearest to a height (`y_hint` is a cell y), searching a few blocks up and down; (-1,-1,-1) if none.
func standable_in_column(x: int, z: int, y_hint: int, up := 3, down := 5) -> Vector3i:
	for d in range(0, maxi(up, down) + 1):
		if d <= up and standable(Vector3i(x, y_hint + d, z)):
			return Vector3i(x, y_hint + d, z)
		if d > 0 and d <= down and standable(Vector3i(x, y_hint - d, z)):
			return Vector3i(x, y_hint - d, z)
	return Vector3i(-1, -1, -1)


## Nearest standable cell to `c` (same column first, then rings outward up to `radius` columns); (-1,-1,-1) if none.
func nearest_standable(c: Vector3i, radius := 4) -> Vector3i:
	var best := Vector3i(-1, -1, -1)
	var best_d := INF
	for r in range(0, radius + 1):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var s := standable_in_column(c.x + dx, c.z + dz, c.y, 2, 4)
				if s.x < 0:
					continue
				var d := Vector2(dx, dz).length() + absf(s.y - c.y) * 0.5
				if d < best_d:
					best_d = d
					best = s
		if best.x >= 0:
			return best   # a ring that has a cell: the nearest of the next ring cannot beat it by much, stop here
	return best


## Cells a unit can stand in to work on the block at `target` (dig it, build next to it): standable, in one of the 8
## neighbouring columns, with the feet from one block below to one block above the target's own height. Never the target
## itself. Cardinal neighbours come first.
func work_cells(target: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var order: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]
	for d in order:
		for dy in [1, 0, -1]:
			var c := Vector3i(target.x + d.x, target.y + dy, target.z + d.y)
			if standable(c):
				out.append(c)
				break
	return out


## The standing cell for a point the player pointed at: `hit` comes from VoxelWorld.raycast.
func standing_for_hit(hit: Dictionary) -> Vector3i:
	var cell: Vector3i = hit.cell
	if standable(cell):
		return cell
	var above: Vector3i = cell + Vector3i(0, 1, 0)
	if standable(above):
		return above
	return nearest_standable(above, 3)


# --- moves ------------------------------------------------------------------------------------------

## The cell a unit can step to from `c` in the direction `d`, or (-1,-1,-1). Fills `cost` with the price of the move.
func step(c: Vector3i, d: Vector2i) -> Array:
	var x := c.x + d.x
	var z := c.z + d.y
	for dy in [0, MAX_STEP_UP, -1, -2, -MAX_DROP]:
		var t := Vector3i(x, c.y + dy, z)
		if not standable(t):
			continue
		if dy > 0 and blocked(c + Vector3i(0, 2, 0)):
			continue   # no room to hop
		if dy < 0:
			var clear := true
			for k in range(t.y + 1, c.y + 2):
				if blocked(Vector3i(x, k, z)):
					clear = false
					break
			if not clear:
				continue
		if d.x != 0 and d.y != 0:
			var lo := mini(c.y, t.y)
			var hi := maxi(c.y, t.y) + 1
			var side_ok := true
			for k in range(lo, hi + 1):
				for side in [Vector3i(c.x + d.x, k, c.z), Vector3i(c.x, k, c.z + d.y)]:
					if blocked(side) and not (k < hi and _feet_free(side)):
						side_ok = false
			if not side_ok:
				continue
		var cost := SQRT2 if (d.x != 0 and d.y != 0) else 1.0
		if dy > 0:
			cost += 0.6
		elif dy < 0:
			cost += 0.15 * -dy
		return [t, cost]
	return [Vector3i(-1, -1, -1), 0.0]


func neighbours(c: Vector3i) -> Array:
	var out := []
	for d in DIRS:
		var r := step(c, d)
		if r[0].x >= 0:
			out.append(r)
		elif d.x == 0 or d.y == 0:
			var j := jump(c, d)
			if j[0].x >= 0:
				out.append(j)
	return out


## A jump from `c` over one cell in the cardinal direction `d`: the cell between must be free to fly over (body height, nothing
## standing in it as a floor), the landing is standable at the same height or one up or down. Returns [cell, cost] or [(-1,-1,-1), 0].
func jump(c: Vector3i, d: Vector2i) -> Array:
	var over_x := c.x + d.x
	var over_z := c.z + d.y
	for dy in [0, 1, -1]:
		# The air the body passes through: over the gap, at the height of the start and of the landing.
		var lo := mini(c.y, c.y + dy)
		var hi := maxi(c.y, c.y + dy) + 1
		var clear := true
		for k in range(lo, hi + 1):
			if blocked(Vector3i(over_x, k, over_z)):
				clear = false
				break
		if not clear:
			continue
		if dy > 0 and blocked(c + Vector3i(0, 2, 0)):
			continue
		var land := Vector3i(c.x + d.x * 2, c.y + dy, c.z + d.y * 2)
		if not standable(land):
			continue
		if blocked(land + Vector3i(0, 1, 0)):
			continue   # standable() already says so; kept for clarity
		return [land, JUMP_COST + (0.6 if dy > 0 else 0.0)]
	return [Vector3i(-1, -1, -1), 0.0]


# --- search -----------------------------------------------------------------------------------------

func _key(c: Vector3i) -> int:
	return c.x + c.z * _size.x + c.y * _size.x * _size.z


func _cell(key: int) -> Vector3i:
	var layer := _size.x * _size.z
	var y := key / layer
	var rest := key - y * layer
	return Vector3i(rest % _size.x, y, rest / _size.x)


static func _heuristic(a: Vector3i, b: Vector3i) -> float:
	var dx := absf(a.x - b.x)
	var dz := absf(a.z - b.z)
	return (dx + dz) + (SQRT2 - 2.0) * minf(dx, dz) + absf(a.y - b.y) * 0.3


## A* from one standable cell to another. Returns the cells from `from` to `to` (both included), or, when the goal cannot be
## reached (`last_reached` false), the way to the closest cell the search found, which is [] if there is nowhere to go.
## `stop_near`: accept any cell within that many columns of the goal (to reach a thing to work on, not its exact cell).
## Runs to the end at once (tests, one-off questions); units use `begin_search` and give it a few milliseconds a frame.
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
	if not s.done:
		s.routes = routes_for(to, stop_near)
	if not s.done:
		var start_key := _key(s.from)
		for comp in _components:
			var i: int = comp.bsearch(start_key)
			if i < comp.size() and comp[i] == start_key:
				s.restrict = comp
				break
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
		if bricks != null:
			_view.bricks = bricks.snapshot()
		if obstacle_source != null:
			_view.obstacle_source = obstacle_source   # (only to say that the cells are in a set; the view never asks it)
			_view._obstacle_cells = _obstacle_cells   # a set that is replaced, never changed, so the thread may read it
		_view_signature = sig
	return _view


## All the searches of a frame together may take about this long (the units share it); the window is 16 ms of real time.
const FRAME_USEC := 4000
const WINDOW_USEC := 16000
## Whether the searches of a frame share one budget. Only where something is drawn: the tests step the world by hand, not by frames.
var share_frame := DisplayServer.get_name() != "headless"
var _window_start := -WINDOW_USEC
var _left := FRAME_USEC


## Gives `search` up to `usec` microseconds of what is left of this frame's budget (and uses it).
func run_search(search: PathSearch, usec: int) -> void:
	if search.threaded:
		if not search.started and not search.done:
			search.started = true
			WorldReaders.enter()
			WorkerThreadPool.add_task(search.run_on_thread, true)
		return
	if not share_frame:
		search.advance(usec)   # headless (tests, a server): there is no frame to keep short, every search gets its slice
		return
	var now := Time.get_ticks_usec()
	if now - _window_start >= WINDOW_USEC:
		_window_start = now
		_left = FRAME_USEC
	var grant := mini(usec, _left)
	if grant <= 0:
		return
	_left -= search.advance(grant)


# --- a small binary min-heap (cost, node) -------------------------------------------------------------

static func _push(f: PackedFloat32Array, n: PackedInt32Array, cost: float, node: int) -> void:
	f.append(cost)
	n.append(node)
	var i := f.size() - 1
	while i > 0:
		var p := (i - 1) / 2
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
		var l := i * 2 + 1
		var r := l + 1
		var m := i
		if l < last and f[l] < f[m]:
			m = l
		if r < last and f[r] < f[m]:
			m = r
		if m == i:
			break
		var tf := f[m]
		f[m] = f[i]
		f[i] = tf
		var tn := n[m]
		n[m] = n[i]
		n[i] = tn
		i = m
	return top
