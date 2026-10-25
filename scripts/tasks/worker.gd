class_name Worker
extends RefCounted
## The little brain of a unit on a job: fetch what the job needs from a stockpile (crafting), find a target, walk next to it, work
## on it, carry the result to a stockpile, put it down, repeat. One state at a time (a plain state machine); the task board ticks it
## every frame. What the work IS comes from the WorkTask; this class only moves and waits.
##
##   SEEK         decide what to do next
##   GO_FETCH     walk to a stockpile that has what the job needs      TAKE   pick it up
##   GO_WORK      walk to a cell next to the target                    WORK   work on it (the task says how long)
##   GO_STOCK     walk to a stockpile that takes the result            PUT    put it down
##   WAIT_STOCK   the result cannot be put anywhere: wait and look again
##   WAIT_TARGET  nothing to claim right now
##   GO_PICKUP    walk to a log lying on the ground (for a stump)     PICKUP   pick it up

enum State { SEEK, GO_FETCH, TAKE, GO_WORK, WORK, GO_STOCK, PUT, WAIT_STOCK, WAIT_TARGET, GO_PICKUP, PICKUP }

const TAKE_TIME := 0.4
const PUT_TIME := 0.45
const RETRY := 4.0       ## seconds before a target that could not be reached is tried again

var unit: Unit
var task: WorkTask
var board: TaskBoard
var state := State.SEEK
var target: Variant = null
var stockpile: Stockpile
var _fetch := {}
var _timer := 0.0
var _moving := false
var _log: LooseLog               ## the log lying on the ground this worker is on its way to


func _init(u: Unit, t: WorkTask, b: TaskBoard) -> void:
	unit = u
	task = t
	board = b
	unit.arrived.connect(_on_arrived)
	unit.path_failed.connect(_on_failed)


## What this worker is on its way to fetch (NONE when nothing).
func fetching_kind() -> int:
	return _fetch.get("kind", Resources.Kind.NONE)


func detach() -> void:
	if unit.arrived.is_connected(_on_arrived):
		unit.arrived.disconnect(_on_arrived)
	if unit.path_failed.is_connected(_on_failed):
		unit.path_failed.disconnect(_on_failed)
	if target != null and task != null:
		task.release(target)
	_drop_stockpile_claims()
	_drop_log()
	unit.status = ""
	unit.progress = -1.0
	unit.stop()
	_moving = false


func _drop_stockpile_claims() -> void:
	if stockpile != null:
		if not _fetch.is_empty():
			board.economy.cancel_take(stockpile, _fetch.amount)
		else:
			board.economy.unreserve(stockpile, unit.carried_amount())
		stockpile = null
	_fetch = {}


func update(delta: float) -> void:
	match state:
		State.SEEK:
			_seek()
		State.WAIT_TARGET:
			_timer -= delta
			if _timer <= 0.0:
				state = State.SEEK
		State.TAKE:
			_timer -= delta
			if _timer <= 0.0:
				_take()
		State.WORK:
			_work(delta)
		State.PICKUP:
			_timer -= delta
			if _timer <= 0.0:
				_pickup()
		State.PUT:
			_timer -= delta
			if _timer <= 0.0:
				_put()
		State.WAIT_STOCK:
			_timer -= delta
			if _timer <= 0.0:
				if task.persistent and task.keeps_load(unit):
					state = State.SEEK
				else:
					_find_stockpile()
		_:
			pass   # walking: _on_arrived / _on_failed move it on


func _leave_or_wait() -> void:
	if task.persistent and unit.carried_amount() > 0 and task.keeps_load(unit):
		state = State.WAIT_TARGET   # the job will open up (the next course): keep the brick and wait
		_timer = 1.0
	elif task.persistent and unit.carried_amount() > 0 and not task.input_needed().is_empty() and state != State.WAIT_STOCK:
		_find_stockpile()   # a leftover (half a brick) that the job cannot use now: back to a stockpile
	elif task.persistent and unit.carried_amount() == 0:
		board.resume_or_free(unit)   # a station with nothing to do: back to the earlier job, or a free unit
	else:
		state = State.WAIT_TARGET
		_timer = 1.0


# --- seeking ----------------------------------------------------------------------------------------

func _seek() -> void:
	unit.status = ""
	if unit.carried_amount() > 0 and task.input_needed().is_empty():
		_find_stockpile()   # still has something from before: that first
		return
	var need := task.input_needed()
	var enough: int = need.get("min", need.get("amount", 0))   # a task can start with less than a full load (a half brick for a cube)
	if not need.is_empty() and not (unit.carried_kind() == need.kind and unit.carried_amount() >= enough):
		if unit.carried_amount() > 0 and unit.carried_kind() != need.kind:
			_find_stockpile()   # something else in the hands: put it down first
			return
		if not task.fetch_wanted(unit):
			_leave_or_wait()
			return
		_start_fetch(need)
		return
	target = task.claim(unit, unit.cell, board.now)
	if target == null:
		_leave_or_wait()
		return
	if not task.valid(target, board):
		task.complete(target)   # gone (or cannot be worked on): not our business any more
		target = null
		return
	if not _walk_to_work():
		task.release(target, board.now + RETRY)
		target = null
		_leave_or_wait()


## Walks to the nearest cell next to the target from which it can be worked on.
func _walk_to_work() -> bool:
	var spots := task.stand_cells(target, board)
	spots.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return Vector2(a.x - unit.cell.x, a.z - unit.cell.z).length() < Vector2(b.x - unit.cell.x, b.z - unit.cell.z).length())
	for s in spots.slice(0, 4):
		if s == unit.cell:
			_begin_work()
			return true
		if unit.walk_to(s):
			state = State.GO_WORK
			_moving = true
			return true
	return false


func _on_arrived() -> void:
	if not _moving:
		return
	_moving = false
	match state:
		State.GO_WORK:
			_begin_work()
		State.GO_FETCH:
			state = State.TAKE
			_timer = TAKE_TIME
		State.GO_PICKUP:
			state = State.PICKUP
			_timer = HarvestTask.PICK_TIME
		State.GO_STOCK:
			state = State.PUT
			_timer = PUT_TIME
			if _stock_ok():
				unit.face(Vector3(stockpile.origin.x + 1.0, unit.position.y, stockpile.origin.z + 1.0))


func _on_failed() -> void:
	if not _moving:
		return
	_moving = false
	match state:
		State.GO_WORK:
			task.release(target, board.now + RETRY)
			target = null
			_leave_or_wait()
		State.GO_FETCH:
			_drop_stockpile_claims()
			_leave_or_wait()
		State.GO_PICKUP:
			_drop_log()
			_leave_or_wait()
		State.GO_STOCK:
			_drop_stockpile_claims()
			state = State.WAIT_STOCK
			_timer = 1.0


# --- fetching -----------------------------------------------------------------------------------------

func _start_fetch(need: Dictionary) -> void:
	var s := board.economy.find_stock(unit.cell, need.kind, need.amount)
	if s == null:
		if need.kind == Resources.Kind.LOG and _start_pickup():
			return   # no log in a stockpile, but one lies on the ground
		_leave_or_wait()
		return
	var spots := s.access_cells(board.nav)
	spots.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return Vector2(a.x - unit.cell.x, a.z - unit.cell.z).length() < Vector2(b.x - unit.cell.x, b.z - unit.cell.z).length())
	board.economy.reserve_take(s, need.amount)
	stockpile = s
	_fetch = need
	for spot in spots.slice(0, 3):
		if spot == unit.cell:
			state = State.TAKE
			_timer = TAKE_TIME
			return
		if unit.walk_to(spot):
			state = State.GO_FETCH
			_moving = true
			return
	_drop_stockpile_claims()
	_leave_or_wait()


## A log lying on the ground that nobody has claimed: walk to it (the stump's units do this by themselves).
func _start_pickup() -> bool:
	var l := board.free_loose_log(unit.cell)
	if l == null:
		return false
	var at := board.nav.nearest_standable(Vector3i(floori(l.global_position.x), floori(l.global_position.y), floori(l.global_position.z)), 1)
	if at.x < 0:
		return false
	_log = l
	l.claimed_by = unit
	if at == unit.cell:
		state = State.PICKUP
		_timer = HarvestTask.PICK_TIME
		return true
	if unit.walk_to(at):
		state = State.GO_PICKUP
		_moving = true
		return true
	_drop_log()
	return false


func _pickup() -> void:
	if _log != null and is_instance_valid(_log) and board.loose != null and board.loose.logs.has(_log):
		board.loose.remove_log(_log)
		_log = null
		unit.carry(Resources.Kind.LOG, 1)
	_drop_log()
	state = State.SEEK


func _drop_log() -> void:
	if _log != null and is_instance_valid(_log):
		_log.claimed_by = null
	_log = null


func _take() -> void:
	if _stock_ok() and not _fetch.is_empty():
		var got := board.economy.withdraw(stockpile, _fetch.kind, _fetch.amount)
		stockpile = null
		if got > 0:
			var have := unit.carried_amount() if unit.carried_kind() == _fetch.kind else 0
			unit.carry(_fetch.kind, have + got)
		_fetch = {}
	else:
		_drop_stockpile_claims()
	state = State.SEEK


# --- working ------------------------------------------------------------------------------------------

## A unit standing IN the block it is told to dig (a slope piece or a pit) has to step out first.
func _standing_in_target() -> bool:
	return target is Vector3i and unit.cell == target


func _begin_work() -> void:
	state = State.WORK
	_timer = 0.0
	unit.face(task.face_point(target))


func _work(delta: float) -> void:
	if not task.valid(target, board):
		task.complete(target)
		target = null
		unit.progress = -1.0
		state = State.SEEK
		return
	if not board.nav.standable(unit.cell) or _standing_in_target():
		unit.progress = -1.0
		task.release(target)
		target = null
		state = State.SEEK
		return
	_timer += delta
	if task is CraftTask and is_instance_valid(task.station):
		task.station.show_working()
	var total := task.work_time(target)
	unit.progress = _timer / total
	unit.position.y = board.nav.feet_position(unit.cell).y + absf(sin(_timer * 14.0)) * 0.05   # a little shake while working
	if _timer < total:
		return
	unit.progress = -1.0
	var res := task.perform(target, board, unit)
	if task is CraftTask and is_instance_valid(task.station):
		task.station.show_made()
	if res.get("consumed", false):
		unit.carry(Resources.Kind.NONE, 0)
	if res.get("done", false):
		task.complete(target)
		target = null
	var kind: int = res.get("kind", Resources.Kind.NONE)
	if kind != Resources.Kind.NONE and res.get("amount", 0) > 0:
		unit.carry(kind, res.amount)   # carried away before the next stage
		# A log goes to a free stump first, to be made into planks (what is made of it is what goes on the stockpile).
		if kind == Resources.Kind.LOG and task.logs_go_to_stump() and board.detour_to_stump(unit):
			return
		_find_stockpile()
	elif res.get("consumed", false):
		# Put into the job (a blueprint was given what it needs): that was the trip, back for the next load.
		if target != null:
			task.release(target)
			target = null
		state = State.SEEK
	else:
		state = State.SEEK if target == null else State.WORK
		_timer = 0.0


# --- carrying -----------------------------------------------------------------------------------------

func _stock_ok() -> bool:
	return stockpile != null and board.economy.stockpiles.has(stockpile)


func _find_stockpile() -> void:
	var kind := unit.carried_kind()
	var n := unit.carried_amount()
	if n == 0:
		state = State.SEEK
		return
	# A building that is waiting for what the unit carries comes first (planks from a stump go to the plan that needs them),
	# then a stockpile with room.
	if not (task is BuildTask) and board.divert_to_build(unit):
		return
	stockpile = board.economy.find_space(unit.cell, kind, n)
	if stockpile == null:
		if not (task is BuildTask) and board.divert_to_build(unit):
			return
		state = State.WAIT_STOCK
		_timer = 1.0
		unit.status = "No free stockpile for %s" % Resources.label(kind).to_lower()
		return
	unit.status = ""
	var spots := stockpile.access_cells(board.nav)
	spots.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return Vector2(a.x - unit.cell.x, a.z - unit.cell.z).length() < Vector2(b.x - unit.cell.x, b.z - unit.cell.z).length())
	board.economy.reserve(stockpile, kind, n)
	for s in spots.slice(0, 3):
		if s == unit.cell:
			state = State.PUT
			_timer = PUT_TIME
			return
		if unit.walk_to(s):
			state = State.GO_STOCK
			_moving = true
			return
	board.economy.unreserve(stockpile, n)
	stockpile = null
	state = State.WAIT_STOCK
	_timer = 1.0
	unit.status = "Can't reach a stockpile"


func _put() -> void:
	var kind := unit.carried_kind()
	var n := unit.carried_amount()
	if not _stock_ok():
		stockpile = null
		_find_stockpile()   # it was taken away (a full frame turned into bricks) while we walked
		return
	var put := board.economy.deposit(stockpile, kind, n)
	stockpile = null
	if put < n:
		unit.carry(kind, n - put)   # no room after all: keep what is left, look for another place
		_find_stockpile()
		return
	unit.carry(Resources.Kind.NONE, 0)
	# Back to the same target if there is still something of it left and nothing has to be fetched, else to the next one.
	if target != null and task.holds(target) and task.input_needed().is_empty():
		if task.valid(target, board) and _walk_to_work():
			return
	if target != null:
		task.release(target)
	target = null
	state = State.SEEK
