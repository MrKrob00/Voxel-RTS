class_name CraftTask
extends WorkTask
## The standing job of a station. It has no end: whenever the stockpiles hold what the station needs and have room for what it
## makes, an idle unit comes (TaskBoard auto-assigns), fetches the input, makes the output, carries it to a stockpile, and goes on
## until the input runs out, then it is a free unit again.

var station: Station
var claimed_by: Unit


func _init(s: Station) -> void:
	station = s
	title = s.def().name
	persistent = true
	max_workers = 1


func is_finished() -> bool:
	return not is_instance_valid(station)


func summary() -> String:
	var d := station.def()
	return "%s: %d %s makes %d %s%s" % [title, d.input.amount, Resources.label(d.input.kind).to_lower(), d.output.amount, Resources.label(d.output.kind).to_lower(), "  (working)" if not workers.is_empty() else ""]


func detail() -> String:
	var d := station.def()
	return "%d %s -> %d %s" % [d.input.amount, Resources.label(d.input.kind).to_lower(), d.output.amount, Resources.label(d.output.kind).to_lower()]


## A stump works by itself and has no card in the ribbon; a station that is switched on by hand (the rope machine) has one.
func shown() -> bool:
	return is_instance_valid(station) and station.enabled and not station.def().get("auto", true)


func input_needed() -> Dictionary:
	if is_instance_valid(station) and station.waiting > 0:
		return {}   # what was made lies on the station: it is taken away before anything new is made
	return station.def().input


## Is there a place for `n` of what the station makes: a stockpile with room, or a building that is waiting for it?
func _output_has_place(n: int) -> bool:
	var d := station.def()
	return board != null and (board.economy.find_space(Vector3i(station.origin), d.output.kind, n) != null or board.build_task_needing(d.output.kind) != null)


func wants_workers(board: TaskBoard) -> bool:
	if not is_instance_valid(station) or not station.enabled or workers.size() >= max_workers:
		return false
	var d := station.def()
	if station.waiting > 0:
		return _output_has_place(station.waiting)   # what lies there is fetched as soon as there is a place for it
	# Something to make it of, and somewhere to take what is made: a stockpile with room, or a building that is waiting for it
	# (the planks of a stump go to the stockpile that is being built when there is no other).
	var has_input: bool = board.economy.find_stock(Vector3i(station.origin), d.input.kind, d.input.amount) != null \
		or (d.input.kind == Resources.Kind.LOG and board.free_loose_log(Vector3i(station.origin)) != null)   # a log on the ground will do
	return has_input \
		and (board.economy.find_space(Vector3i(station.origin), d.output.kind, d.output.amount) != null or board.build_task_needing(d.output.kind) != null)


func claim(unit: Unit, _from: Vector3i, _now: float) -> Variant:
	if station.waiting > 0 and not _output_has_place(station.waiting):
		return null   # nothing to do here until a stockpile has room
	if claimed_by == null or claimed_by == unit:
		claimed_by = unit
		return station
	return null


func release(_target: Variant, _retry_after := 0.0) -> void:
	claimed_by = null


func complete(_target: Variant) -> void:
	claimed_by = null


func holds(target: Variant) -> bool:
	return target == station and is_instance_valid(station)


func valid(target: Variant, _board: TaskBoard) -> bool:
	return target == station and is_instance_valid(station)


func stand_cells(_target: Variant, board: TaskBoard) -> Array[Vector3i]:
	return station.access_cells(board.nav)


func face_point(_target: Variant) -> Vector3:
	return station.center() if is_instance_valid(station) else Vector3.ZERO


func work_time(_target: Variant) -> float:
	return 0.4 if station.waiting > 0 else station.def().time


func perform(_target: Variant, _board: TaskBoard, _unit: Unit = null) -> Dictionary:
	var d := station.def()
	if station.waiting > 0:
		# Taking away what lay on the station.
		return {"kind": d.output.kind, "amount": station.take_output(), "done": false}
	if not _output_has_place(d.output.amount):
		station.leave_output(d.output.amount)   # nowhere to put it now: it lies on the station
		return {"consumed": true, "done": false}
	return {"kind": d.output.kind, "amount": d.output.amount, "consumed": true, "done": false}
