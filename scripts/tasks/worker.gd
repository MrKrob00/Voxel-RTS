class_name Worker
extends RefCounted
## The little brain of a unit that works on a dig task: find a block, walk next to it, dig it stage by stage, carry the bag
## to a stockpile, put it down, repeat. One state at a time (a plain state machine); the task board ticks it every frame.
##
##   SEEK     look for a free block of the task
##   GO_DIG   walk to a cell next to the block
##   DIG      work on the block (one stage takes DIG_TIME seconds); a stage gives one bag of what the block is made of
##   GO_STOCK walk to the stockpile with the bag
##   PUT      put the bag down
##   WAIT     the bag cannot be put anywhere (no stockpile, or all full): wait and watch
##   WAIT_BLOCK nothing left to claim right now

enum State { SEEK, GO_DIG, DIG, GO_STOCK, PUT, WAIT, WAIT_BLOCK }

const DIG_TIME := 1.3
const PUT_TIME := 0.45
const RETRY := 4.0       ## seconds before a block that could not be reached is tried again

var unit: Unit
var task: DigTask
var board: TaskBoard
var state := State.SEEK
var target := Vector3i(-1, -1, -1)      ## the block being dug
var stand := Vector3i(-1, -1, -1)       ## where the unit stands to do it
var stockpile: Stockpile
var _timer := 0.0
var _moving := false


func _init(u: Unit, t: DigTask, b: TaskBoard) -> void:
	unit = u
	task = t
	board = b
	unit.arrived.connect(_on_arrived)
	unit.path_failed.connect(_on_failed)


func detach() -> void:
	if unit.arrived.is_connected(_on_arrived):
		unit.arrived.disconnect(_on_arrived)
	if unit.path_failed.is_connected(_on_failed):
		unit.path_failed.disconnect(_on_failed)
	if target.x >= 0 and task != null:
		task.release(target)
	if stockpile != null:
		board.economy.unreserve(stockpile)
		stockpile = null
	unit.status = ""
	unit.progress = -1.0
	unit.stop()
	_moving = false


func update(delta: float) -> void:
	match state:
		State.SEEK:
			_seek()
		State.WAIT_BLOCK:
			_timer -= delta
			if _timer <= 0.0:
				state = State.SEEK
		State.DIG:
			_dig(delta)
		State.PUT:
			_timer -= delta
			if _timer <= 0.0:
				_put()
		State.WAIT:
			_timer -= delta
			if _timer <= 0.0:
				_find_stockpile()
		_:
			pass   # walking: _on_arrived / _on_failed move it on


func _seek() -> void:
	unit.status = ""
	target = task.claim(unit, unit.cell, board.now)
	if target.x < 0:
		state = State.WAIT_BLOCK
		_timer = 1.0
		return
	if not _valid_target(target):
		task.complete(target)   # the block is gone (or cannot be dug): not our business any more
		target = Vector3i(-1, -1, -1)
		return
	if not _walk_to_work():
		task.release(target, board.now + RETRY)
		target = Vector3i(-1, -1, -1)
		state = State.WAIT_BLOCK
		_timer = 1.0


func _valid_target(c: Vector3i) -> bool:
	return board.world.terrain.can_dig(c)


## Picks the nearest cell next to the block from which it can be worked on and starts walking there.
func _walk_to_work() -> bool:
	var spots := board.nav.work_cells(target)
	spots.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return Vector2(a.x - unit.cell.x, a.z - unit.cell.z).length() < Vector2(b.x - unit.cell.x, b.z - unit.cell.z).length())
	for s in spots.slice(0, 4):
		if s == unit.cell:
			stand = s
			_begin_dig()
			return true
		if unit.walk_to(s):
			stand = s
			state = State.GO_DIG
			_moving = true
			return true
	return false


func _on_arrived() -> void:
	if not _moving:
		return
	_moving = false
	match state:
		State.GO_DIG:
			_begin_dig()
		State.GO_STOCK:
			state = State.PUT
			_timer = PUT_TIME
			if _stock_ok():
				unit.face(Vector3(stockpile.origin.x + 1.0, 0.0, stockpile.origin.z + 1.0))


func _on_failed() -> void:
	if not _moving:
		return
	_moving = false
	match state:
		State.GO_DIG:
			task.release(target, board.now + RETRY)
			target = Vector3i(-1, -1, -1)
			state = State.WAIT_BLOCK
			_timer = 1.0
		State.GO_STOCK:
			if stockpile != null:
				board.economy.unreserve(stockpile)
				stockpile = null
			state = State.WAIT
			_timer = 1.0


func _begin_dig() -> void:
	state = State.DIG
	_timer = 0.0
	unit.face(Vector3(target.x + 0.5, unit.position.y, target.z + 0.5))


func _dig(delta: float) -> void:
	if not _valid_target(target):
		task.complete(target)
		target = Vector3i(-1, -1, -1)
		unit.progress = -1.0
		state = State.SEEK
		return
	if not board.nav.standable(unit.cell) or unit.cell == target:
		unit.progress = -1.0
		task.release(target)
		target = Vector3i(-1, -1, -1)
		state = State.SEEK
		return
	_timer += delta
	unit.progress = _timer / DIG_TIME
	# A little shake while working.
	unit.position.y = board.nav.feet_position(unit.cell).y + absf(sin(_timer * 14.0)) * 0.05
	if _timer < DIG_TIME:
		return
	unit.progress = -1.0
	var raw := board.world.get_block(target)
	var kind := Resources.from_block(Blocks.mat(raw))
	if kind != Resources.Kind.NONE and not task.collects(kind):
		kind = Resources.Kind.NONE   # not wanted: broken and thrown away, like earth
	board.world.terrain.dig_step(target)
	var gone := not board.world.terrain.can_dig(target)
	if gone:
		task.complete(target)   # nothing left of it: the claim ends with the block
		target = Vector3i(-1, -1, -1)
	if kind != Resources.Kind.NONE:
		unit.carry(kind, 1)   # every stage gives a bag, which has to be carried away before the next one
		_find_stockpile()
	else:
		state = State.SEEK if gone else State.DIG
		_timer = 0.0


func _find_stockpile() -> void:
	var kind := unit.carried_kind()
	stockpile = board.economy.find_space(unit.cell, kind)
	if stockpile == null:
		state = State.WAIT
		_timer = 1.0
		unit.status = "No free stockpile for %s" % Resources.label(kind).to_lower()
		return
	unit.status = ""
	var spots := stockpile.access_cells(board.nav)
	spots.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return Vector2(a.x - unit.cell.x, a.z - unit.cell.z).length() < Vector2(b.x - unit.cell.x, b.z - unit.cell.z).length())
	board.economy.reserve(stockpile, kind)
	for s in spots.slice(0, 3):
		if s == unit.cell:
			state = State.PUT
			_timer = PUT_TIME
			return
		if unit.walk_to(s):
			state = State.GO_STOCK
			_moving = true
			return
	board.economy.unreserve(stockpile)
	stockpile = null
	state = State.WAIT
	_timer = 1.0
	unit.status = "Can't reach a stockpile"


func _stock_ok() -> bool:
	return stockpile != null and board.economy.stockpiles.has(stockpile)


func _put() -> void:
	var kind := unit.carried_kind()
	if not _stock_ok():
		stockpile = null
		_find_stockpile()   # it was taken away (a full frame turned into bricks) while we walked
		return
	var put := board.economy.deposit(stockpile, kind, unit.carried_amount())
	stockpile = null
	if put == 0:
		_find_stockpile()   # no room after all: keep the bag, look for another place
		return
	unit.carry(Resources.Kind.NONE, 0)
	# Back to the same block if there is still something of it left, else to the next one.
	if target.x >= 0 and task.cells.has(target):
		if _valid_target(target) and _walk_to_work():
			return
		task.release(target)
	target = Vector3i(-1, -1, -1)
	state = State.SEEK
