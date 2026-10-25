class_name Navigation
extends RefCounted
## Where units can stand and how they walk from A to B over the voxel ground, slopes, pits, bricks and bridges.
##
## A NODE is the cell the unit's feet are in. A cell can be stood in when
##   - it is open air, or a ground piece (slope / half-dug block, which the unit stands IN), never a whole block, a brick or water;
##   - the cell above it is free (the unit is one block tall plus a hat);
##   - in open air there is a whole block or a brick under it (a ground piece carries itself).
## Moves go to the 8 neighbouring columns and change height by at most MAX_STEP_UP up (a hop onto a block) or MAX_DROP down.
## A diagonal needs both of the cells beside it to be free, so nobody cuts a corner through a wall.
## Pure rules on voxel data: no scene access, so it can run on a worker thread and in headless tests.

const MAX_STEP_UP := 1
const MAX_DROP := 3
const NODE_LIMIT := 60000   ## a search gives up (and returns the closest it got) after expanding this many nodes
const SQRT2 := 1.41421356

const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
]

var world: VoxelWorld
var bricks: BrickWorld   ## optional: bricks are obstacles and floors
var obstacle := Callable()   ## optional (cell) -> bool: other things that fill a cell (a stockpile frame, a station)
var _size: Vector3i

## Result of the last find_path: false when the goal could not be reached and the path only gets as near as it could.
var last_reached := false
var last_expanded := 0


func _init(w: VoxelWorld, b: BrickWorld = null) -> void:
	world = w
	bricks = b
	_size = w.size_blocks()


# --- cells ------------------------------------------------------------------------------------------

func _brick(c: Vector3i) -> bool:
	return (bricks != null and bricks.occupied(c)) or (obstacle.is_valid() and obstacle.call(c))


## Blocks a body: any solid ground, whole or partial, a brick, or water.
func blocked(c: Vector3i) -> bool:
	if _brick(c):
		return true
	var raw := world.get_block(c)
	return Blocks.is_solid(raw) or Blocks.mat(raw) == Blocks.WATER


## A ground piece (slope or half-dug block) is a floor the unit stands in: free for feet, not for a head.
func _feet_free(c: Vector3i) -> bool:
	if _brick(c):
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
	if Blocks.is_partial(raw):
		return true
	var below := c + Vector3i(0, -1, 0)
	return Blocks.is_whole(world.get_block(below)) or _brick(below)


## y of the unit's feet in world units, at a point (wx, wz) inside the cell.
func feet_height(c: Vector3i, wx: float, wz: float) -> float:
	var raw := world.get_block(c)
	if Blocks.is_partial(raw):
		return c.y + Blocks.surface_height(Blocks.shape(raw), clampf(wx - c.x, 0.0, 1.0), clampf(wz - c.z, 0.0, 1.0))
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
	return out


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
func find_path(from: Vector3i, to: Vector3i, stop_near := 0.0) -> Array[Vector3i]:
	last_reached = false
	last_expanded = 0
	var result: Array[Vector3i] = []
	if not standable(from):
		from = nearest_standable(from, 2)
		if from.x < 0:
			return result
	if from == to:
		last_reached = true
		result.append(from)
		return result
	var open_f := PackedFloat32Array()
	var open_n := PackedInt32Array()
	var g := {}          # key -> best cost so far
	var came := {}       # key -> previous key
	var closed := {}
	var start_key := _key(from)
	g[start_key] = 0.0
	_push(open_f, open_n, _heuristic(from, to), start_key)
	var best_key := start_key
	var best_h := _heuristic(from, to)
	var goal_key := -1
	while open_n.size() > 0:
		var cur_key := _pop(open_f, open_n)
		if closed.has(cur_key):
			continue
		closed[cur_key] = true
		var cur := _cell(cur_key)
		last_expanded += 1
		var h := _heuristic(cur, to)
		if h < best_h:
			best_h = h
			best_key = cur_key
		if cur == to or (stop_near > 0.0 and Vector2(cur.x - to.x, cur.z - to.z).length() <= stop_near and absi(cur.y - to.y) <= 2):
			goal_key = cur_key
			break
		if last_expanded > NODE_LIMIT:
			break
		var cur_g: float = g[cur_key]
		for r in neighbours(cur):
			var nk := _key(r[0])
			if closed.has(nk):
				continue
			var ng: float = cur_g + r[1]
			if not g.has(nk) or ng < g[nk]:
				g[nk] = ng
				came[nk] = cur_key
				_push(open_f, open_n, ng + _heuristic(r[0], to), nk)
	var end_key := goal_key if goal_key >= 0 else best_key
	last_reached = goal_key >= 0
	var k := end_key
	while true:
		result.append(_cell(k))
		if k == start_key:
			break
		k = came[k]
	result.reverse()
	if not last_reached and result.size() <= 1:
		result.clear()
	return result


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
