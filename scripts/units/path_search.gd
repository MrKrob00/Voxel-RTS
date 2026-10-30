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

var _open_f := PackedFloat32Array()
var _open_n := PackedInt32Array()
var _g := {}          # key -> best cost so far
var _came := {}       # key -> previous key
var _closed := {}
var _start_key := 0
var _best_key := 0
var _best_h := 0.0
var _goal_key := -1
var _cost_cap := INF


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
	_cost_cap = Navigation.COST_FACTOR * _best_h + Navigation.COST_EXTRA


## The whole search, on a worker thread.
func run_on_thread() -> void:
	advance(-1)
	WorldReaders.leave()


## Works on the search for at most `usec` microseconds (negative: until it is done). Returns the time it took.
func advance(usec: int) -> int:
	if done:
		return 0
	var t0 := Time.get_ticks_usec()
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
		for r in nav.neighbours(cur):
			var nk := nav._key(r[0])
			if _closed.has(nk):
				continue
			var ng: float = cur_g + r[1]
			if ng > _cost_cap:
				continue
			if not _g.has(nk) or ng + Navigation.COST_EPSILON < _g[nk]:
				_g[nk] = ng
				_came[nk] = cur_key
				Navigation._push(_open_f, _open_n, ng + Navigation._heuristic(r[0], to), nk)
	_finish()
	return Time.get_ticks_usec() - t0


func _finish() -> void:
	var end_key := _goal_key if _goal_key >= 0 else _best_key
	reached = _goal_key >= 0
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
