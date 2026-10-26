class_name PathSearch
extends RefCounted
## One A* search over the navigation grid that can be done in slices of time. The old way was one call that ran to the end: a goal
## that cannot be reached explores everything that can be reached (a second or more on one frame), so the whole game stood still.
## Now a unit starts a search and the search takes a few milliseconds a frame (Navigation.run_search) until it is done.
##
## Result, when `done`: `path` (the cells from the start to the goal, both included, or to the closest cell found when the goal cannot
## be reached: `reached` false; [] when there is nowhere to go) and `expanded`.

var nav: Navigation
var from: Vector3i
var to: Vector3i
var stop_near := 0.0
var done := false     ## set last, from the thread that did the search: the rest of the result is there when this is true
var threaded := false ## goes to a worker thread (Navigation.run_search) instead of being done in slices
var started := false  ## and has been handed to it
var reached := false
var expanded := 0
var path: Array[Vector3i] = []

## When the goal could not be reached and the search looked at everything that can be reached from the start (not stopped by the node
## limit): these cells (their keys, sorted). Another search that starts in one of them and wants a goal that is not among them does not
## have to look again (Navigation.learn / begin_search).
var component := PackedInt32Array()
var signature := 0               ## what the world looked like when the search began (a component is only good for the same one)
var routes: Array = []           ## ways recently walked to a goal near this one (arrays of cells): the search joins one where it meets it
var restrict := PackedInt32Array()   ## set by Navigation: the cells known to be all that can be reached from the start

var _open_f := PackedFloat32Array()
var _open_n := PackedInt32Array()
var _g := {}          # key -> best cost so far
var _came := {}       # key -> previous key
var _closed := {}
var _start_key := 0
var _best_key := 0
var _best_h := 0.0
var _goal_key := -1
var _join := {}          # key of a cell on one of `routes` -> Vector2i(route, position in it)
var _joined := false
var _cut_off := false   # the goal was given up for the nearest reachable cell (see _retarget_if_cut_off)


func _init(n: Navigation, start: Vector3i, goal: Vector3i, near := 0.0) -> void:
	nav = n
	from = start
	to = goal
	stop_near = near
	if not nav.standable(from):
		from = nav.nearest_standable(from, 2)
		if from.x < 0:
			done = true
			return
	if from == to:
		reached = true
		path.append(from)
		done = true
		return
	_start_key = nav._key(from)
	_g[_start_key] = 0.0
	Navigation._push(_open_f, _open_n, Navigation._heuristic(from, to), _start_key)
	_best_key = _start_key
	_best_h = Navigation._heuristic(from, to)


## The whole search, on a worker thread.
func run_on_thread() -> void:
	advance(-1)
	WorldReaders.leave()


## Works on the search for at most `usec` microseconds (negative: until it is done). Returns the time it took.
func advance(usec: int) -> int:
	if done:
		return 0
	var t0 := Time.get_ticks_usec()
	if not restrict.is_empty():
		_retarget_if_cut_off()
	if not routes.is_empty() and not _joined:
		_joined = true
		for r in routes.size():
			var route: Array = routes[r]
			for i in route.size() - 1:
				var k := nav._key(route[i])
				if not _join.has(k):
					_join[k] = Vector2i(r, i)
	while _open_n.size() > 0:
		if usec >= 0 and (expanded & 7) == 0 and Time.get_ticks_usec() - t0 >= usec:
			return Time.get_ticks_usec() - t0
		var cur_key := Navigation._pop(_open_f, _open_n)
		if _closed.has(cur_key):
			continue
		_closed[cur_key] = true
		var cur := nav._cell(cur_key)
		expanded += 1
		var h := Navigation._heuristic(cur, to)
		if h < _best_h:
			_best_h = h
			_best_key = cur_key
		if cur == to or (stop_near > 0.0 and Vector2(cur.x - to.x, cur.z - to.z).length() <= stop_near and absi(cur.y - to.y) <= 2):
			_goal_key = cur_key
			break
		if expanded > Navigation.NODE_LIMIT:
			break
		var cur_g: float = _g[cur_key]
		if not _join.is_empty() and _join.has(cur_key):
			var at: Vector2i = _join[cur_key]
			_join.erase(cur_key)
			if _graft(cur_key, cur_g, cur, routes[at.x], at.y):
				continue   # the rest of that way is taken as it is: the search goes on from its end
		for r in nav.neighbours(cur):
			var nk := nav._key(r[0])
			if _closed.has(nk):
				continue
			var ng: float = cur_g + r[1]
			if not _g.has(nk) or ng < _g[nk]:
				_g[nk] = ng
				_came[nk] = cur_key
				Navigation._push(_open_f, _open_n, ng + Navigation._heuristic(r[0], to), nk)
	_finish()
	return Time.get_ticks_usec() - t0


## Takes the rest of a way walked before as part of this search: every cell of it gets its cost from here, and its last cell is what
## the search goes on from. False (nothing taken) when some step of it cannot be walked now.
func _graft(cur_key: int, cur_g: float, cur: Vector3i, route: Array, from_index: int) -> bool:
	var g := cur_g
	var prev := cur
	var prev_key := cur_key
	var staged: Array = []
	for i in range(from_index + 1, route.size()):
		var c: Vector3i = route[i]
		var cost := nav.move_cost(prev, c)
		if cost < 0.0:
			return false
		g += cost
		var k := nav._key(c)
		staged.append([k, g, prev_key])
		prev = c
		prev_key = k
	if staged.is_empty():
		return false
	for st in staged:
		var k: int = st[0]
		if not _g.has(k) or st[1] < _g[k]:
			_g[k] = st[1]
			_came[k] = st[2]
	Navigation._push(_open_f, _open_n, g + Navigation._heuristic(prev, to), prev_key)
	return true


## The start is in a set of cells that is all it can reach (`restrict`): when the goal is not among them, the way is looked for to the
## cell of the set nearest to it, at once, instead of finding that out by looking at all of them again.
func _retarget_if_cut_off() -> void:
	var set := restrict
	restrict = PackedInt32Array()
	var best := -1
	var best_h := INF
	for k in set:
		var c := nav._cell(k)
		if c == to or (stop_near > 0.0 and Vector2(c.x - to.x, c.z - to.z).length() <= stop_near and absi(c.y - to.y) <= 2):
			return   # the goal can be reached after all: an ordinary search
		var h := Navigation._heuristic(c, to)
		if h < best_h:
			best_h = h
			best = k
	if best < 0:
		return
	to = nav._cell(best)
	stop_near = 0.0
	_cut_off = true
	_best_h = Navigation._heuristic(from, to)
	_open_f = PackedFloat32Array()
	_open_n = PackedInt32Array()
	Navigation._push(_open_f, _open_n, _best_h, _start_key)


func _finish() -> void:
	var end_key := _goal_key if _goal_key >= 0 else _best_key
	reached = _goal_key >= 0 and not _cut_off
	if _goal_key < 0 and _open_n.size() == 0 and expanded <= Navigation.NODE_LIMIT and not _cut_off:
		component = PackedInt32Array(_closed.keys())   # everything reachable from the start was looked at
		component.sort()
	var k := end_key
	while true:
		path.append(nav._cell(k))
		if k == _start_key:
			break
		k = _came[k]
	path.reverse()
	if not reached and path.size() <= 1:
		path.clear()
	_open_f = PackedFloat32Array()
	_open_n = PackedInt32Array()
	_g = {}
	_came = {}
	_closed = {}
	done = true
