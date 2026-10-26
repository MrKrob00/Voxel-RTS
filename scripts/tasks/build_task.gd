class_name BuildTask
extends WorkTask
## The job of a blueprint. Like a station's, it is a standing job: whenever a stockpile has one of the things the blueprint still needs,
## an idle unit comes, fetches it (one load: a log, three planks), carries it over and puts it in. When everything is in, the blueprint
## is replaced by the real building and the job ends.

var blueprint: Blueprint


func _init(bp: Blueprint) -> void:
	blueprint = bp
	title = "Build " + bp.title.to_lower()
	persistent = true
	max_workers = 2


## Every frame: a log in somebody's hands that is on its way to this plan hangs over it as a ghost log (the place is taken, the work not begun).
func update(_brd: TaskBoard) -> void:
	if blueprint == null or not is_instance_valid(blueprint) or blueprint.done:
		return
	var coming := false
	if blueprint.remaining().has(Resources.Kind.LOG):
		for u in workers:
			if is_instance_valid(u) and u.carried_kind() == Resources.Kind.LOG and u.carried_amount() > 0:
				coming = true
	blueprint.show_incoming_log(coming)


func is_finished() -> bool:
	return blueprint == null or not is_instance_valid(blueprint) or blueprint.done


func summary() -> String:
	return "%s: %s%s" % [title, blueprint.needs_text() if not is_finished() else "done", "  (%d working)" % workers.size() if not workers.is_empty() else ""]


func detail() -> String:
	return blueprint.needs_text() if not is_finished() else "done"


## What is to be fetched next: a load of the first thing still missing.
func input_needed() -> Dictionary:
	if is_finished():
		return {}   # the blueprint is done and gone (a worker may still be on the job): nothing more to fetch
	var rem := blueprint.remaining()
	for k in rem:
		return {"kind": k, "amount": mini(rem[k], Resources.carry_capacity(k))}
	return {}


func wants_workers(brd: TaskBoard) -> bool:
	if is_finished() or workers.size() >= max_workers:
		return false
	var need := input_needed()
	return not need.is_empty() and brd.economy.find_stock(Vector3i(blueprint.origin), need.kind, need.amount) != null


func claim(_unit: Unit, _from: Vector3i, _now: float) -> Variant:
	return null if is_finished() else blueprint


func release(_target: Variant, _retry_after := 0.0) -> void:
	pass


func complete(_target: Variant) -> void:
	pass


func holds(target: Variant) -> bool:
	return target == blueprint and not is_finished()


func valid(target: Variant, _brd: TaskBoard) -> bool:
	return target == blueprint and not is_finished()


func stand_cells(_target: Variant, brd: TaskBoard) -> Array[Vector3i]:
	if is_finished():
		return []
	return blueprint.access_cells(brd.nav)


func face_point(_target: Variant) -> Vector3:
	return blueprint.center() if is_instance_valid(blueprint) else Vector3.ZERO


func work_time(_target: Variant) -> float:
	return 0.8


## Puts what the unit carries into the blueprint; when it is all there, the building stands.
func perform(_target: Variant, brd: TaskBoard, unit: Unit = null) -> Dictionary:
	if unit != null and unit.carried_amount() > 0:
		var kind := unit.carried_kind()
		var left := unit.carried_amount() - blueprint.deliver(kind, unit.carried_amount())
		unit.carry(kind if left > 0 else Resources.Kind.NONE, left)   # what the blueprint did not need stays in the hands
	if blueprint.is_complete():
		brd.finish_blueprint(blueprint)
	return {"done": true}
