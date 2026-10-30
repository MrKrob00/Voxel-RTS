class_name BuildTask
extends WorkTask
## The ONE job of every planned structure (stockpile, stump, rope machine...), as WallTask is the one job of the planned blocks: a new
## blueprint joins the job that is already there, and a job is made only when there is none. Like a station's it is a standing job: whenever
## a stockpile has one of the things a blueprint still needs, an idle unit comes, fetches it (one load: a log, three planks), carries it to
## the blueprint that needs it and puts it in. A blueprint that has all it needs is replaced by the real building and leaves the job; the
## job ends when the last one has gone.

var blueprints: Array[Blueprint] = []


func _init(bp: Blueprint = null) -> void:
	persistent = true
	max_workers = 4
	if bp != null:
		add_blueprint(bp)
	_retitle()


func add_blueprint(bp: Blueprint) -> void:
	blueprints.append(bp)
	_retitle()


func remove_blueprint(bp: Blueprint) -> void:
	blueprints.erase(bp)
	_retitle()


## The blueprints still to be built (a freed one, or one that stands now, is not).
func live() -> Array[Blueprint]:
	var out: Array[Blueprint] = []
	for bp in blueprints:
		if is_instance_valid(bp) and not bp.done:
			out.append(bp)
	return out


func _retitle() -> void:
	var l := live()
	title = "Build " + (l[0].title.to_lower() if l.size() == 1 else "structures")


## Every frame: a log in somebody's hands that is on its way to a plan hangs over it as a ghost log (the place is taken, the work not begun).
func update(_brd: TaskBoard) -> void:
	var l := live()
	if l.is_empty():
		return
	var coming := {}
	for u in workers:
		if is_instance_valid(u) and u.carried_kind() == Resources.Kind.LOG and u.carried_amount() > 0:
			var bp := _nearest_needing(l, Resources.Kind.LOG, u.cell)
			if bp != null:
				coming[bp] = true
	for bp in l:
		bp.show_incoming_log(coming.has(bp))
	if l.size() != blueprints.size():
		blueprints.assign(l)   # the ones that stand now are out of the job
		_retitle()


static func _nearest_needing(from_list: Array[Blueprint], kind: int, from: Vector3i) -> Blueprint:
	var best: Blueprint = null
	var best_d := INF
	for bp in from_list:
		if not bp.remaining().has(kind):
			continue
		var d := Vector2(bp.origin.x - from.x, bp.origin.z - from.z).length()
		if d < best_d:
			best_d = d
			best = bp
	return best


func is_finished() -> bool:
	return live().is_empty()


func summary() -> String:
	return "%s: %s%s" % [title, detail(), "  (%d working)" % workers.size() if not workers.is_empty() else ""]


## What the plans still need, all together ("planks 2/6, log 0/1"), or the plan's own line when there is one.
func detail() -> String:
	var l := live()
	if l.is_empty():
		return "done"
	if l.size() == 1:
		return l[0].needs_text()
	var cost := {}
	var have := {}
	for bp in l:
		for k in bp.cost:
			cost[k] = cost.get(k, 0) + bp.cost[k]
			have[k] = have.get(k, 0) + bp.delivered.get(k, 0)
	var parts := PackedStringArray()
	for k in cost:
		parts.append("%s %d/%d" % [Resources.label(k).to_lower(), have[k], cost[k]])
	return "%d plans: %s" % [l.size(), ", ".join(parts)]


## The first thing a plan still misses, as a load.
static func _need_of(bp: Blueprint) -> Dictionary:
	var rem := bp.remaining()
	for k in rem:
		return {"kind": k, "amount": mini(rem[k], Resources.carry_capacity(k))}
	return {}


## What is to be fetched next: a load of what the first plan that can be served right now misses (else of what the first one misses).
func input_needed() -> Dictionary:
	return input_needed_by(null)


## The same, but a unit that carries something that a plan needs goes on with that.
func input_needed_by(unit: Unit) -> Dictionary:
	if unit != null and unit.carried_amount() == 0 and live().any(func(bp: Blueprint) -> bool: return bp.has_work()):
		return {}   # a free hand goes to what is paid for and waits to be laid, before fetching more
	var first := {}
	for bp in live():
		var need := _need_of(bp)
		if need.is_empty():
			continue
		if unit != null and unit.carried_amount() > 0 and bp.remaining().has(unit.carried_kind()):
			return {"kind": unit.carried_kind(), "amount": mini(bp.remaining()[unit.carried_kind()], Resources.carry_capacity(unit.carried_kind()))}
		if first.is_empty():
			first = need
		if board != null and board.economy.find_stock(Vector3i(bp.origin), need.kind, need.amount) != null:
			if unit == null or unit.carried_amount() == 0:
				return need
	return first


func wants_workers(brd: TaskBoard) -> bool:
	if workers.size() >= max_workers:
		return false
	for bp in live():
		if bp.has_work():
			return true
		var need := _need_of(bp)
		if not need.is_empty() and brd.economy.find_stock(Vector3i(bp.origin), need.kind, need.amount) != null:
			return true
	return false


## The nearest plan that needs what the unit carries.
func claim(unit: Unit, from: Vector3i, _now: float) -> Variant:
	var bp := _nearest_needing(live(), unit.carried_kind(), from) if unit.carried_amount() > 0 else null
	if bp == null:
		for w in live():
			if w.has_work():
				bp = w   # something to lay that has been paid for
				break
	if bp != null:
		bp.note_builder(from)
	return bp


func release(_target: Variant, _retry_after := 0.0) -> void:
	pass


func complete(_target: Variant) -> void:
	pass


func _is_live(target: Variant) -> bool:
	return is_instance_valid(target) and target is Blueprint and not (target as Blueprint).done and blueprints.has(target)   # (valid first: `is` on a freed one is an error)


func holds(target: Variant) -> bool:
	return _is_live(target)


func valid(target: Variant, _brd: TaskBoard) -> bool:
	return _is_live(target)


func stand_cells(target: Variant, brd: TaskBoard) -> Array[Vector3i]:
	if not _is_live(target):
		return []
	return (target as Blueprint).access_cells(brd.nav)


## A point to send the nearest idle unit towards: the first plan.
func face_point(target: Variant) -> Vector3:
	if _is_live(target):
		return (target as Blueprint).center()
	var l := live()
	return l[0].center() if not l.is_empty() else Vector3.ZERO


func work_time(_target: Variant) -> float:
	return 0.8


## Puts what the unit carries into the plan; when it is all there, the building stands.
func perform(target: Variant, brd: TaskBoard, unit: Unit = null) -> Dictionary:
	(target as Blueprint).perform_work(unit, brd)
	return {"done": true}
