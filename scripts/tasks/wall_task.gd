class_name WallTask
extends WorkTask
## Building a planned wall, brick by brick, from the bottom course up. A standing job like a blueprint's: whenever a stack of bricks has
## stone and some brick can be laid (what it rests on is there), idle units come, take a brick from the stack (two halves), carry it to the wall,
## stand next to the place (on the course below, for the upper ones) and lay it. A cube takes one half and the other half is kept for the
## next cube, or taken back to the stack. Only slots whose support exists are open: the wall grows in stages.

var plan: WallPlan


func _init(p: WallPlan) -> void:
	plan = p
	title = "Build a wall"
	persistent = true
	max_workers = 4


func is_finished() -> bool:
	return plan == null or not is_instance_valid(plan) or plan.is_done()


func summary() -> String:
	if is_finished():
		return "Wall: done"
	return "Wall #%d: %d of %d halves of stone still to lay, %d working" % [id, plan.remaining_halves(), plan.total_halves(), workers.size()]


func detail() -> String:
	return "%d of %d halves left" % [plan.remaining_halves(), plan.total_halves()] if not is_finished() else "done"


## A brick (two halves) is fetched; one half is enough to start (a cube).
func input_needed() -> Dictionary:
	if is_finished():
		return {}
	return {"kind": Resources.Kind.BRICK, "amount": 2, "min": 1}


## Can this slot be laid right now: free of other claims, and something to rest on.
func _open(s: WallPlan.Slot, now := 0.0) -> bool:
	if s.done or s.claimed != null or s.blocked_until > now:
		return false
	# The body of the wall first: course k starts RUN cells further on than the course below, which leaves the start as a staircase to
	# climb. The staircase is then closed in passes with a narrower and narrower step (2 cells, 1 cell, none), so there is a way up to
	# the places that are left until the very last.
	if s.col < s.course * _run():
		return false
	if s.kind == "stairs":
		var at := s.origin
		var cube := s.cells()[1]
		var w := board.world
		return w.get_block(at) == Blocks.AIR and Blocks.is_whole(w.get_block(at + Vector3i(0, -1, 0))) and not board.economy.bricks.occupied(at) \
			and board.economy.bricks.can_place(cube, s.axis, 1)
	return board.economy.bricks.can_place(s.origin, s.axis, s.length)


## The width of a step of the staircase in the current pass: 2, then 1, then 0 (the wall is closed).
func _run() -> int:
	if plan.courses <= WallPlan.REACH_COURSES:
		return 0   # laid from the ground: no staircase is needed
	var run := WallPlan.STAIR_RUN
	while run > 0:
		for s in plan.slots:
			if not s.done and s.col >= s.course * run:
				return run   # something of this pass is still to lay
		run -= 1
	return 0


func _body_done() -> bool:
	return _run() < WallPlan.STAIR_RUN


func wants_workers(brd: TaskBoard) -> bool:
	if is_finished() or workers.size() >= max_workers:
		return false
	var any_open := false
	for s in plan.slots:
		if _open(s):
			any_open = true
			break
	return any_open and brd.economy.find_stock(Vector3i(plan.first), Resources.Kind.BRICK, 1) != null


## The nearest open slot that the load in the unit's hands can pay for.
func claim(unit: Unit, from: Vector3i, _now: float) -> Variant:
	var have := unit.carried_amount() if unit.carried_kind() == Resources.Kind.BRICK else 0
	var best: WallPlan.Slot = null
	var best_d := INF
	for s in plan.slots:
		if not _open(s, board.now) or s.halves() > have:
			continue
		# Low courses first; in the closing phase from the far end of the wall back to the start.
		var d := Vector2(s.origin.x - from.x, s.origin.z - from.z).length() + s.course * 0.4 - (s.col * 0.05 if _body_done() else 0.0)
		if d < best_d:
			best_d = d
			best = s
	if best != null:
		best.claimed = unit
	return best


## A whole brick is kept while the wall is not done (the slots above will open). A lone half only while a cube is still to be laid.
func keeps_load(unit: Unit) -> bool:
	if is_finished() or unit.carried_kind() != Resources.Kind.BRICK:
		return false
	if unit.carried_amount() >= 2:
		return true
	for s in plan.slots:
		if not s.done and s.length == 1:
			return true
	return false


func release(target: Variant, retry_after := 0.0) -> void:
	var s: WallPlan.Slot = target
	if s != null:
		s.claimed = null
		s.blocked_until = retry_after


func complete(_target: Variant) -> void:
	pass


func holds(target: Variant) -> bool:
	var s: WallPlan.Slot = target
	return s != null and not s.done


func valid(target: Variant, _brd: TaskBoard) -> bool:
	var s: WallPlan.Slot = target
	return s != null and not s.done and is_instance_valid(plan)


## Beside the place: in a neighbouring column, with the feet up to one block above or two blocks below the place (it is laid at arm's
## length: from the ground a unit reaches the third course).
func stand_cells(target: Variant, brd: TaskBoard) -> Array[Vector3i]:
	var s: WallPlan.Slot = target
	var out: Array[Vector3i] = []
	for c in s.cells():
		for w in brd.nav.work_cells(c):
			if not s.cells().has(w) and not out.has(w):
				out.append(w)
		for d in Navigation.DIRS:
			var low := Vector3i(c.x + d.x, c.y - 2, c.z + d.y)
			if not s.cells().has(low) and not out.has(low) and brd.nav.standable(low):
				out.append(low)
	return out


func face_point(target: Variant) -> Vector3:
	var s: WallPlan.Slot = target
	return BrickWorld.center_for(s.origin, s.axis, s.length) if s != null else Vector3.ZERO


func work_time(_target: Variant) -> float:
	return 0.7


## Lays the brick. If it cannot be laid after all (the support went), the slot is given back.
func perform(target: Variant, brd: TaskBoard, unit: Unit = null) -> Dictionary:
	var s: WallPlan.Slot = target
	if unit == null or unit.carried_amount() < s.halves():
		return {"done": false}
	if s.kind == "stairs":
		var cube := s.cells()[1]
		if not brd.world.terrain.make_stairs(s.origin, s.rise):
			return {"done": false}
		if brd.economy.bricks.place(cube, s.axis, BrickWorld.Kind.STONE, 1) == null:
			brd.world.set_block(s.origin, Blocks.AIR)   # the cube could not stand: take the steps back
			return {"done": false}
		plan.mark_done(s)
		var rest := unit.carried_amount() - s.halves()
		unit.carry(Resources.Kind.BRICK if rest > 0 else Resources.Kind.NONE, rest)
		return {"done": true}
	var placed := brd.economy.bricks.place(s.origin, s.axis, BrickWorld.Kind.STONE, s.length)
	if placed == null:
		return {"done": false}
	plan.mark_done(s)
	var left := unit.carried_amount() - s.halves()
	unit.carry(Resources.Kind.BRICK if left > 0 else Resources.Kind.NONE, left)
	return {"done": true}
