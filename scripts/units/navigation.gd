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
## ...and does not go on to places that cost more than this to reach: COST_FACTOR times the distance to the goal plus COST_EXTRA (a way
## that is longer than that round a cliff is not looked for; idea of Zylann's VoxelAStarGrid3D, `max_path_cost`)
const COST_FACTOR := 5.0
const COST_EXTRA := 100.0
## Costs that differ by less than this are the same (float noise made searches look at places again, as the same plugin notes)
const COST_EPSILON := 0.001
const SQRT2 := 1.41421356
const JUMP_COST := 3.2

const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
]

var world: VoxelWorld
var bricks   ## optional: bricks are obstacles and floors (a BrickWorld, or a BrickSnapshot in the copy a thread reads)
var obstacle := Callable()   ## optional (cell) -> bool: other things that fill a cell (a stockpile frame, a station)
## optional: whoever the cells of `obstacle` come from, with blocked_cells() -> Dictionary and obstacle_signature() -> int (the Economy);
## a thread reads a copy of them.
var obstacle_source: Object
var _size: Vector3i

## Result of the last find_path: false when the goal could not be reached and the path only gets as near as it could.
var last_reached := false
var last_expanded := 0


func _init(w: VoxelWorld, b = null) -> void:
	world = w
	bricks = b
	_size = w.size_blocks()


# --- cells ------------------------------------------------------------------------------------------

func _brick(c: Vector3i) -> bool:
	return (bricks != null and bricks.occupied(c)) or (obstacle.is_valid() and obstacle.call(c))


## The flight of steps in a cell ({} if none): the unit stands IN that cell and walks up the steps.
func _flight(c: Vector3i) -> Dictionary:
	return bricks.steps_at(c) if bricks != null else {}


## A brick or other thing that carries the feet of someone standing on top of it. A flight of steps does not: its top is only reached
## by walking up it.
func _floor_brick(c: Vector3i) -> bool:
	if obstacle.is_valid() and obstacle.call(c):
		return true
	return bricks != null and bricks.occupied(c) and bricks.steps_at(c).is_empty()


## Blocks a body: any solid ground, whole or partial, a brick, or water.
func blocked(c: Vector3i) -> bool:
	if _brick(c):
		return true
	var raw := world.get_block(c)
	return Blocks.is_solid(raw) or Blocks.mat(raw) == Blocks.WATER


## A ground piece (slope or half-dug block) is a floor the unit stands in: free for feet, not for a head.
func _feet_free(c: Vector3i) -> bool:
	if obstacle.is_valid() and obstacle.call(c):
		return false
	if bricks != null and bricks.occupied(c) and bricks.steps_at(c).is_empty():
		return false
	var raw := world.get_block(c)
	if Blocks.mat(raw) == Blocks.WATER:
		return false
	return not Blocks.is_solid(raw) or Blocks.is_partial(raw)


func standable(c: Vector3i) -> bool:
	if c.x < 0 or c.z < 0 or c.y < 1 or c.x >= _size.x or c.z >= _size.z or c.y + 2 >= _size.y:
		return false
	if not _feet_free(c):
		return false
	if blocked(c + Vector3i(0, 1, 0)):
		return false
	var raw := world.get_block(c)
	if Blocks.is_partial(raw) or not _flight(c).is_empty():
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
	var s := PathSearch.new(self, from, to, stop_near)
	s.advance(-1)
	last_reached = s.reached
	last_expanded = s.expanded
	return s.path


## A search that is done in slices of time, or on a worker thread (see PathSearch).
func begin_search(from: Vector3i, to: Vector3i, stop_near := 0.0) -> PathSearch:
	if not use_threads():
		return PathSearch.new(self, from, to, stop_near)
	var s := PathSearch.new(view(), from, to, stop_near)
	s.threaded = true
	return s


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
	var sig := [bricks.signature() if bricks != null else 0, obstacle_source.call("obstacle_signature") if obstacle_source != null else 0]
	if _view == null or sig != _view_signature:
		_view = Navigation.new(world)
		_view.threaded = false
		if bricks != null:
			_view.bricks = bricks.snapshot()
		if obstacle_source != null:
			var blocked: Dictionary = obstacle_source.call("blocked_cells")
			_view.obstacle = func(c: Vector3i) -> bool: return blocked.has(c)
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
