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


func input_needed() -> Dictionary:
	return station.def().input


func wants_workers(board: TaskBoard) -> bool:
	if not is_instance_valid(station) or workers.size() >= max_workers:
		return false
	var d := station.def()
	return board.economy.find_stock(Vector3i(station.origin), d.input.kind, d.input.amount) != null \
		and board.economy.find_space(Vector3i(station.origin), d.output.kind, d.output.amount) != null


func claim(unit: Unit, _from: Vector3i, _now: float) -> Variant:
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
	return station.def().time


func perform(_target: Variant, _board: TaskBoard, _unit: Unit = null) -> Dictionary:
	var d := station.def()
	return {"kind": d.output.kind, "amount": d.output.amount, "consumed": true, "done": false}
