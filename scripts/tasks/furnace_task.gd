class_name FurnaceTask
extends WorkTask
## The standing job of a furnace: units bring the ore and the amber that the ordered ingots need (three small things at a time), and carry
## the made ingots to a stockpile. The furnace smelts by itself between, so a unit is free while it burns. The card of the task is shown
## while there is an order or an ingot waiting in the tray.

var furnace: Furnace
var _taking := false      ## somebody is on the way to take the ingots


func _init(f: Furnace) -> void:
	furnace = f
	title = "Furnace"
	persistent = true
	max_workers = 2


func is_finished() -> bool:
	return not is_instance_valid(furnace)


func shown() -> bool:
	return is_instance_valid(furnace) and furnace.queued + furnace.made > 0


func summary() -> String:
	return "%s: %s" % [title, detail()]


func detail() -> String:
	if not is_instance_valid(furnace):
		return "gone"
	return "ingots %d ordered, %d ready" % [furnace.queued, furnace.made]


func _has_place(n: int) -> bool:
	return board != null and board.economy.find_space(Vector3i(furnace.origin), Resources.Kind.INGOT, n) != null


## The next thing to fetch: ore first, then amber, in loads of three; nothing when the furnace has all it needs (or ingots wait to be taken).
func input_needed_by(unit: Unit) -> Dictionary:
	if not is_instance_valid(furnace):
		return {}
	for kind in Furnace.RECIPE:
		var miss := furnace.missing(kind)
		if unit != null and unit.carried_amount() > 0 and unit.carried_kind() == kind:
			return {"kind": kind, "amount": mini(miss, unit.carried_amount())} if miss > 0 else {}
		if miss > 0 and (unit == null or unit.carried_amount() == 0):
			return {"kind": kind, "amount": mini(miss, Resources.carry_capacity(kind))}
	return {}


func input_needed() -> Dictionary:
	return input_needed_by(null)


## Nobody fetches more than the furnace still lacks (the loads already on the way count).
func fetch_wanted(unit: Unit) -> bool:
	var need := input_needed_by(unit)
	if need.is_empty():
		return false
	if board.supplies_coming(self, need.kind, need.amount, unit) * need.amount >= furnace.missing(need.kind):
		return false
	return true


func wants_workers(brd: TaskBoard) -> bool:
	if not is_instance_valid(furnace) or workers.size() >= max_workers:
		return false
	if furnace.made > 0 and not _taking and _has_place(mini(furnace.made, Resources.carry_capacity(Resources.Kind.INGOT))):
		return true
	for kind in Furnace.RECIPE:
		var miss := furnace.missing(kind)
		if miss > 0 and brd.economy.find_stock(Vector3i(furnace.origin), kind, mini(miss, Resources.carry_capacity(kind))) != null \
				and brd.supplies_coming(self, kind, mini(miss, Resources.carry_capacity(kind))) * Resources.carry_capacity(kind) < miss:
			return true
	return false


## A unit with something for the furnace goes in; a free one goes to take the ingots when there are some.
func claim(unit: Unit, _from: Vector3i, _now: float) -> Variant:
	if not is_instance_valid(furnace):
		return null
	if unit.carried_amount() > 0:
		return furnace if furnace.missing(unit.carried_kind()) > 0 else null
	if furnace.made > 0 and not _taking and _has_place(1):
		_taking = true
		return furnace
	return null


func release(_target: Variant, _retry_after := 0.0) -> void:
	_taking = false


func complete(_target: Variant) -> void:
	_taking = false


func holds(target: Variant) -> bool:
	return target == furnace and is_instance_valid(furnace)


func valid(target: Variant, _brd: TaskBoard) -> bool:
	return target == furnace and is_instance_valid(furnace)


func stand_cells(_target: Variant, brd: TaskBoard) -> Array[Vector3i]:
	return furnace.access_cells(brd.nav)


func face_point(_target: Variant) -> Vector3:
	return furnace.center() if is_instance_valid(furnace) else Vector3.ZERO


func work_time(_target: Variant) -> float:
	return 0.5


## Puts in what the unit brought, or takes the ingots (up to three) away.
func perform(_target: Variant, _brd: TaskBoard, unit: Unit = null) -> Dictionary:
	if unit != null and unit.carried_amount() > 0:
		var kind := unit.carried_kind()
		var left := unit.carried_amount() - furnace.add_input(kind, unit.carried_amount())
		unit.carry(kind if left > 0 else Resources.Kind.NONE, left)   # what the furnace did not need stays in the hands
		return {"done": true}
	var got := furnace.take_ingots(Resources.carry_capacity(Resources.Kind.INGOT))
	_taking = false
	return {"kind": Resources.Kind.INGOT, "amount": got, "done": true}
