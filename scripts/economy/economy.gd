class_name Economy
extends Node3D
## Everything the player owns: the stockpiles and what is in them. Units ask it where to put things.

signal changed

var world: VoxelWorld
var bricks: BrickWorld
var stockpiles: Array[Stockpile] = []
var stations: Array = []     ## Station nodes (stump, rope machine)
var blueprints: Array = []   ## Blueprint nodes: planned buildings waiting for what they cost
var walls: Array = []        ## WallPlan nodes: planned walls
var _reserved := {}          ## Stockpile -> {kind, count}: goods on their way there
var _taking := {}            ## Stockpile -> how many of its goods someone is on the way to fetch


func setup(w: VoxelWorld, b: BrickWorld) -> void:
	world = w
	bricks = b
	world.block_changed.connect(_on_block_changed)


## Puts a stockpile down. Returns null and the reason in `last_error` when it cannot stand there.
var last_error := ""
var packed_bricks := 0       ## stone bricks stacked up from frames that were filled to the brim

## Whether stockpiles cost anything when put down at once (tests and the starting buildings switch it off). The player does not do
## this: the player puts down a blueprint (place_blueprint) and units bring the price.
var charge_for_stockpiles := true

func place_stockpile(origin: Vector3i, style := Stockpile.Style.PLATFORM) -> Stockpile:
	last_error = Stockpile.can_place(world, bricks, origin, stockpiles + blueprints)
	if last_error != "":
		return null
	if charge_for_stockpiles:
		for k in Stockpile.COST:
			if stock_of(k) < Stockpile.COST[k]:
				last_error = "needs %d %s in a stockpile" % [Stockpile.COST[k], Resources.label(k).to_lower()]
				return null
		for k in Stockpile.COST:
			spend(k, Stockpile.COST[k])
	var s := Stockpile.new()
	add_child(s)
	s.build(origin, style)
	stockpiles.append(s)
	# Grass goes under a building.
	world.stamp_cover_rect(Rect2(origin.x, origin.z, Stockpile.SIZE, Stockpile.SIZE), 0.9)
	changed.emit()
	return s


## Puts a station up and takes its price out of the stockpiles. Returns null and the reason in `last_error` when it cannot be done.
func place_station(kind: int, origin: Vector3i, pay := true) -> Station:
	last_error = Station.can_place(world, bricks, kind, origin, stockpiles + blueprints, stations)
	if last_error != "":
		return null
	var cost: Dictionary = Station.DEFS[kind].cost
	if pay:
		for k in cost:
			if stock_of(k) < cost[k]:
				last_error = "needs %d %s in a stockpile" % [cost[k], Resources.label(k).to_lower()]
				return null
		for k in cost:
			spend(k, cost[k])
	var st := Station.new()
	add_child(st)
	st.build(kind, origin)
	stations.append(st)
	var sz := st.size()
	world.stamp_cover_rect(Rect2(origin.x, origin.z, sz.x, sz.y), 0.9)
	changed.emit()
	return st


## The player's way to build: a plan on the ground. Returns null (and the reason in `last_error`) when it cannot stand there.
## `type` is "stockpile" (kind: Stockpile.Style) or "station" (kind: Station.Kind).
func place_blueprint(type: String, kind: int, origin: Vector3i) -> Blueprint:
	var cost: Dictionary
	var size: Vector2i
	var title: String
	if type == "stockpile":
		last_error = Stockpile.can_place(world, bricks, origin, stockpiles + blueprints)
		cost = Stockpile.COST
		size = Vector2i(Stockpile.SIZE, Stockpile.SIZE)
		title = "Stockpile (%s)" % Stockpile.STYLE_NAMES[kind]
	else:
		last_error = Station.can_place(world, bricks, kind, origin, stockpiles + blueprints, stations)
		cost = Station.DEFS[kind].cost
		size = Station.DEFS[kind].size
		title = Station.DEFS[kind].name
	if last_error != "":
		return null
	var bp := Blueprint.new()
	add_child(bp)
	bp.build(type, kind, origin, size, cost, title)
	blueprints.append(bp)
	changed.emit()
	return bp


## Everything has arrived: the blueprint goes and the real thing stands there. Returns the Stockpile or the Station.
func finish_blueprint(bp: Blueprint) -> Node:
	blueprints.erase(bp)
	bp.done = true
	bp.queue_free()
	var made: Node
	if bp.kind_type == "stockpile":
		var was := charge_for_stockpiles
		charge_for_stockpiles = false   # it has been paid for, plank by plank
		made = place_stockpile(bp.origin, bp.kind)
		charge_for_stockpiles = was
	else:
		made = place_station(bp.kind, bp.origin, false)
	changed.emit()
	return made


## Plans a wall: `from` and `to` are cells (the feet height of the ground) on one line along x or z; `height` courses. Null and the reason
## in `last_error` if it cannot be laid there (the bottom course needs whole ground, nothing in the way).
func place_wall(from: Vector3i, to: Vector3i, height: int) -> WallPlan:
	var along_x := absi(to.x - from.x) >= absi(to.z - from.z)
	var axis := 0 if along_x else 1
	var lo := Vector3i(mini(from.x, to.x), from.y, mini(from.z, to.z)) if along_x else Vector3i(from.x, from.y, mini(from.z, to.z))
	var length := (absi(to.x - from.x) if along_x else absi(to.z - from.z)) + 1
	if not along_x:
		lo.x = from.x
	else:
		lo.z = from.z
	height = clampi(height, 1, WallPlan.MAX_COURSES)
	if length < WallPlan.STAIR_RUN * (height - 1) + 1:
		last_error = "a wall %d courses high must be at least %d cells long (it is climbed by its own staircase)" % [height, WallPlan.STAIR_RUN * (height - 1) + 1]
		return null
	var slots := WallPlan.layout(lo, axis, length, height)
	last_error = ""
	for s in slots:
		for c in s.cells():
			if not world.in_bounds(c) or world.get_block(c) != Blocks.AIR or bricks.occupied(c):
				last_error = "something is in the way"
			for p in stockpiles + blueprints + stations:
				if p.covers(c):
					last_error = "overlaps a building"
			for w in walls:
				if w.covers(c):
					last_error = "overlaps another wall"
		if s.course == 0 and not bricks.can_place(s.origin, s.axis, s.length):
			last_error = "the bottom course needs flat whole ground"
		if last_error != "":
			return null
	var plan := WallPlan.new()
	add_child(plan)
	plan.build(lo, axis, length, height)
	walls.append(plan)
	changed.emit()
	return plan


## Plans a stair block of 2 x 1 x 1 on the ground: stair piece at `at`, rising towards a stone cube in the next cell (`rise` is a unit step in x or z).
func place_stairs(at: Vector3i, rise: Vector2i) -> WallPlan:
	last_error = ""
	var slots := WallPlan.stairs_layout(at, rise)
	for c in slots[0].cells():
		if not world.in_bounds(c) or world.get_block(c) != Blocks.AIR or bricks.occupied(c):
			last_error = "something is in the way"
		for p in stockpiles + blueprints + stations:
			if p.covers(c):
				last_error = "overlaps a building"
		for w in walls:
			if w.covers(c):
				last_error = "overlaps another plan"
	if not Blocks.is_whole(world.get_block(at + Vector3i(0, -1, 0))):
		last_error = "needs flat whole ground"
	elif not bricks.can_place(slots[0].cells()[1], slots[0].axis, 1):
		last_error = "the stone block needs flat whole ground too"
	if last_error != "":
		return null
	var plan := WallPlan.new()
	add_child(plan)
	plan.build(at, slots[0].axis, 2, 1, slots)
	walls.append(plan)
	changed.emit()
	return plan


func cancel_wall(plan: WallPlan) -> void:
	walls.erase(plan)
	plan.queue_free()
	changed.emit()


func cancel_blueprint(bp: Blueprint) -> void:
	blueprints.erase(bp)
	bp.done = true
	bp.queue_free()
	changed.emit()


func remove_station(st: Station) -> void:
	stations.erase(st)
	st.queue_free()
	changed.emit()


func remove_stockpile(s: Stockpile) -> void:
	stockpiles.erase(s)
	_reserved.erase(s)
	s.queue_free()
	changed.emit()


## A stockpile that would take `n` more of `kind`: first one that already holds that kind (like with like), else an empty one; the
## nearest to `from` (by straight line) of those. Null when there is none. Goods already on their way count: two workers do not
## both get the last place.
func find_space(from: Vector3i, kind: int, n := 1) -> Stockpile:
	var best: Stockpile = null
	var best_d := INF
	for s in stockpiles:
		if s.capacity_for(kind) == 0:
			continue
		var r: Dictionary = _reserved.get(s, {})
		if not r.is_empty() and r.kind != kind and s.holding == Resources.Kind.NONE:
			continue   # someone is bringing another kind to this empty one
		if s.room_for(kind) - (r.get("count", 0) if (r.is_empty() or r.kind == kind) else 0) < n:
			continue
		var d := Vector2(s.origin.x - from.x, s.origin.z - from.z).length() + (0.0 if s.holding == kind else 10000.0)
		if d < best_d:
			best_d = d
			best = s
	return best


## A stockpile that has at least `n` of `kind` to give, nearest to `from`; null when none does.
func find_stock(from: Vector3i, kind: int, n := 1) -> Stockpile:
	var best: Stockpile = null
	var best_d := INF
	for s in stockpiles:
		if s.amount(kind) - _taking.get(s, 0) < n:
			continue
		var d := Vector2(s.origin.x - from.x, s.origin.z - from.z).length()
		if d < best_d:
			best_d = d
			best = s
	return best


func reserve(s: Stockpile, kind: int, n := 1) -> void:
	var r: Dictionary = _reserved.get(s, {"kind": kind, "count": 0})
	r.count += n
	_reserved[s] = r


func unreserve(s: Stockpile, n := 1) -> void:
	var r: Dictionary = _reserved.get(s, {})
	if r.is_empty():
		return
	r.count -= n
	if r.count <= 0:
		_reserved.erase(s)


## Puts a bag down. A frame filled with stone to the brim is replaced by a stack of stone bricks. Returns how many were taken.
func deposit(s: Stockpile, kind: int, n: int) -> int:
	unreserve(s, n)
	var put := s.add(kind, n)
	if s.packed_stone():
		_pack_into_bricks(s)
	changed.emit()
	return put


## The frame goes, a stack of 4 stone bricks of 2x1x1 (two layers of two) stands where it was: the material of walls.
func _pack_into_bricks(s: Stockpile) -> void:
	var at := s.origin
	remove_stockpile(s)
	var was := charge_for_stockpiles
	charge_for_stockpiles = false
	var stack := place_stockpile(at, Stockpile.Style.STACK)
	charge_for_stockpiles = was
	if stack != null:
		stack.add(Resources.Kind.BRICK, Stockpile.CAPACITY[Stockpile.Style.STACK][Resources.Kind.BRICK])
		packed_bricks += 4


## Someone is on the way to fetch `n` of its goods: nobody else is promised them.
func reserve_take(s: Stockpile, n: int) -> void:
	_taking[s] = _taking.get(s, 0) + n


func cancel_take(s: Stockpile, n: int) -> void:
	_taking[s] = maxi(0, _taking.get(s, 0) - n)


## Takes goods out of a stockpile that someone had reserved them in. Returns how many there were.
func withdraw(s: Stockpile, kind: int, n: int) -> int:
	cancel_take(s, n)
	var got := s.take(kind, n)
	if s.style == Stockpile.Style.STACK and s.count == 0 and not _reserved.has(s):
		remove_stockpile(s)   # the last brick is gone: nothing is left standing there
	changed.emit()
	return got


## How much of a kind there is in all stockpiles together.
func stock_of(kind: int) -> int:
	var n := 0
	for s in stockpiles:
		n += s.amount(kind)
	return n


## Pays for something from any stockpile (a stump costs a log). All or nothing; false if there is not enough.
func spend(kind: int, n: int) -> bool:
	if stock_of(kind) < n:
		return false
	var left := n
	for s in stockpiles:
		var got := s.take(kind, left)
		left -= got
		if left == 0:
			break
	changed.emit()
	return true


## Cells nobody can walk through: the solid crate of a frame and the stations.
func blocks_cell(c: Vector3i) -> bool:
	for s in stockpiles:
		if s.blocks(c):
			return true
	for st in stations:
		if st.blocks(c):
			return true
	return false


func total(kind: int) -> int:
	var n := 0
	for s in stockpiles:
		n += s.amount(kind)
	return n


func totals() -> Dictionary:
	var out := {}
	for s in stockpiles:
		if s.count > 0:
			out[s.holding] = out.get(s.holding, 0) + s.count
	return out


## A stockpile whose ground was dug away or built over is gone, its stock with it (a quick rule for now).
func _on_block_changed(p: Vector3i) -> void:
	for s in stockpiles.duplicate():
		if p.y == s.origin.y - 1 or p.y == s.origin.y or p.y == s.origin.y + 1:
			if p.x >= s.origin.x and p.x < s.origin.x + Stockpile.SIZE and p.z >= s.origin.z and p.z < s.origin.z + Stockpile.SIZE:
				if Stockpile.can_place(world, bricks, s.origin, []) != "":
					remove_stockpile(s)
