class_name HarvestTask
extends WorkTask
## A marked area of trees or grass to be harvested. Trees are felled (4 s) and drop 3 logs as physics bodies; the same crew picks
## the logs up and carries them away, one at a time, on their backs. Grass is cut tuft by tuft into sacks.

enum Kind { TREES, GRASS }

const CHOP_TIME := 4.0
const CUT_TIME := 1.4
const PICK_TIME := 0.6
const LOGS_PER_TREE := 3
const MAX_FAILURES := 3
const MARK_COLOR := Color(0.35, 0.9, 0.3, 0.6)
const CLAIMED_COLOR := Color(1.0, 0.55, 0.1, 0.7)

## One thing to work on: a tree, a tuft, or a log lying on the ground.
class Target extends RefCounted:
	var type := ""            # "tree", "plant" or "log"
	var index := -1           # the instance in PropField for trees and tufts
	var log: LooseLog
	var pos := Vector3.ZERO
	var claimed: Unit
	var blocked_until := 0.0
	var failures := 0         ## times nobody could reach it; after MAX_FAILURES it is given up

const MIN_RADIUS := 2.0
const MAX_RADIUS := 30.0
const RESCAN_EVERY := 1.0
const RING_COLOR := Color(1.0, 0.8, 0.2, 0.85)

var harvest_kind := Kind.TREES
var targets: Array[Target] = []
## A task made with a circle (tap, then drag out the radius) is standing: it looks at the circle all the time, takes every tree
## (tuft, log) that is there, and does not end when they are gone: the player closes it or changes the radius. With radius 0 it is
## a fixed list of targets that ends when they are done.
var center := Vector2.ZERO
var radius := 0.0
var _known := {}                 ## what has been taken into the task already (so a felled tree's slot is not taken twice)
var _scan_at := -10.0


func _init(k := Kind.TREES, circle_center := Vector2.ZERO, circle_radius := 0.0) -> void:
	harvest_kind = k
	title = "Fell trees" if k == Kind.TREES else "Cut grass"
	center = circle_center
	radius = circle_radius
	persistent = circle_radius > 0.0


func logs_go_to_stump() -> bool:
	return true


func is_circle() -> bool:
	return radius > 0.0


func set_radius(r: float, board: TaskBoard) -> void:
	radius = clampf(r, MIN_RADIUS, MAX_RADIUS)
	for t in targets.duplicate():
		if t.claimed == null and t.type != "log" and Vector2(t.pos.x, t.pos.z).distance_to(center) > radius:
			targets.erase(t)
			_known.erase(_key(t))
	scan(board)
	redraw(board)


static func _key(t: Target) -> String:
	return "%s%d" % [t.type, t.index] if t.type != "log" else "log%d" % t.log.get_instance_id()


## Takes in what is in the circle and is not yet in the task: trees or tufts, and the logs that lie there.
func scan(board: TaskBoard) -> void:
	if not is_circle() or board == null or board.props == null or not board.props.is_built():
		return
	_scan_at = board.now
	var rect := Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
	if harvest_kind == Kind.TREES:
		for i in board.props.trees_in_rect(rect):
			var o: Vector3 = board.props.trees[i].origin
			if Vector2(o.x, o.z).distance_to(center) <= radius and not _known.has("tree%d" % i):
				_known["tree%d" % i] = true
				add_tree(i, o)
		if board.loose != null:
			for l in board.loose.logs:
				if is_instance_valid(l) and Vector2(l.global_position.x, l.global_position.z).distance_to(center) <= radius \
						and not _known.has("log%d" % l.get_instance_id()):
					_known["log%d" % l.get_instance_id()] = true
					add_log(l)
	else:
		for i in board.props.tufts_in_rect(rect):
			var o: Vector3 = board.props.tufts[i].origin
			if Vector2(o.x, o.z).distance_to(center) <= radius and not _known.has("plant%d" % i):
				_known["plant%d" % i] = true
				add_plant(i, o)


func update(board: TaskBoard) -> void:
	if is_circle() and board.now - _scan_at >= RESCAN_EVERY:
		scan(board)


## Somebody can work now: something is free to take (a log only when it can be carried somewhere).
func wants_workers(board: TaskBoard) -> bool:
	if not is_circle() or workers.size() >= max_workers:
		return false
	for t in targets:
		if t.claimed == null and t.blocked_until <= board.now and t.failures < MAX_FAILURES:
			if t.type != "log" or board.log_has_destination(Vector3i(floori(t.pos.x), floori(t.pos.y), floori(t.pos.z))):
				return true
	return false


func face_point(_target: Variant) -> Vector3:
	if _target != null:
		return (_target as Target).pos
	var y := float(board.world.surface_y(int(center.x), int(center.y))) + 1.0 if board != null and board.world != null else 0.0
	return Vector3(center.x, y, center.y)


func add_tree(index: int, pos: Vector3) -> void:
	var t := Target.new()
	t.type = "tree"
	t.index = index
	t.pos = pos
	targets.append(t)


func add_plant(index: int, pos: Vector3) -> void:
	var t := Target.new()
	t.type = "plant"
	t.index = index
	t.pos = pos
	targets.append(t)


func add_log(l: LooseLog) -> void:
	var t := Target.new()
	t.type = "log"
	t.log = l
	t.pos = l.global_position
	targets.append(t)
	_known["log%d" % l.get_instance_id()] = true


func detail() -> String:
	if is_circle():
		return "radius %d, %d %s" % [int(radius), targets.filter(func(t: Target) -> bool: return t.type != "log").size(), "trees" if harvest_kind == Kind.TREES else "tufts"]
	var n := 0
	var logs := 0
	for t in targets:
		if t.type == "log":
			logs += 1
		else:
			n += 1
	return "%d %s%s" % [n, "trees" if harvest_kind == Kind.TREES else "tufts", (", %d logs" % logs) if logs > 0 else ""]


## Done when nothing is left that anybody can still get to (a log that rolled off a ledge is given up after a few tries).
func is_finished() -> bool:
	if is_circle():
		return false
	for t in targets:
		if t.failures < MAX_FAILURES or t.claimed != null:
			return false
	return true


func summary() -> String:
	var trees := 0
	var logs := 0
	for t in targets:
		if t.type == "log":
			logs += 1
		else:
			trees += 1
	var what := ("%d trees" % trees) if harvest_kind == Kind.TREES else ("%d tufts" % trees)
	return "%s #%d: %s%s, %d/%d workers" % [title, id, what, (", %d logs on the ground" % logs) if logs > 0 else "", workers.size(), max_workers]


## Logs lying about come first (they are what a felling is for), then the nearest tree or tuft.
func claim(unit: Unit, from: Vector3i, now: float) -> Variant:
	var best: Target = null
	var best_score := INF
	for t in targets:
		if t.claimed != null or t.blocked_until > now or t.failures >= MAX_FAILURES:
			continue
		# A log is only picked up when there is somewhere to take it: otherwise it stays where it lies.
		if t.type == "log" and board != null and not board.log_has_destination(from):
			continue
		var pos := t.log.global_position if (t.type == "log" and is_instance_valid(t.log)) else t.pos
		var d := Vector2(pos.x - from.x, pos.z - from.z).length() + (0.0 if t.type == "log" else 12.0)
		if d < best_score:
			best_score = d
			best = t
	if best != null:
		best.claimed = unit
		if best.type == "log" and is_instance_valid(best.log):
			best.log.claimed_by = unit
	return best


func release(target: Variant, retry_after := 0.0) -> void:
	var t: Target = target
	if t == null:
		return
	t.claimed = null
	if t.log != null and is_instance_valid(t.log):
		t.log.claimed_by = null
	t.blocked_until = retry_after
	if retry_after > 0.0:
		t.failures += 1


func complete(target: Variant) -> void:
	targets.erase(target)


func holds(target: Variant) -> bool:
	return targets.has(target)


func valid(target: Variant, board: TaskBoard) -> bool:
	var t: Target = target
	match t.type:
		"tree":
			return board.props != null and t.index < board.props.tree_alive.size() and board.props.tree_alive[t.index] == 1
		"plant":
			return board.props != null and t.index < board.props.tuft_alive.size() and board.props.tuft_alive[t.index] == 1
		"log":
			return is_instance_valid(t.log) and board.loose != null and board.loose.logs.has(t.log)
	return false


func _cell_of(t: Target) -> Vector3i:
	var pos := t.log.global_position if (t.type == "log" and is_instance_valid(t.log)) else t.pos
	return Vector3i(floori(pos.x), floori(pos.y), floori(pos.z))


func stand_cells(target: Variant, board: TaskBoard) -> Array[Vector3i]:
	var t: Target = target
	var cell := _cell_of(t)
	var out: Array[Vector3i] = board.nav.work_cells(cell)
	if t.type != "tree":
		var here := board.nav.nearest_standable(cell, 1)
		if here.x >= 0:
			out.push_front(here)   # a log or a tuft can be picked up from the cell it lies in
	return out


func work_time(target: Variant) -> float:
	match (target as Target).type:
		"tree":
			return CHOP_TIME
		"plant":
			return CUT_TIME
	return PICK_TIME


func perform(target: Variant, board: TaskBoard, _unit: Unit = null) -> Dictionary:
	var t: Target = target
	match t.type:
		"tree":
			board.props.fell_tree(t.index)
			# The tree falls: three logs drop from where its trunk was and tumble off a little.
			for i in LOGS_PER_TREE:
				var drop := t.pos + Vector3(randf_range(-0.5, 0.5), 1.0 + i * 0.55, randf_range(-0.5, 0.5))
				var l := board.loose.spawn_log(drop, Vector3(randf_range(-1.2, 1.2), 0.5, randf_range(-1.2, 1.2)))
				add_log(l)
			return {"kind": Resources.Kind.NONE, "done": true}
		"plant":
			board.props.cut_tuft(t.index)
			return {"kind": Resources.Kind.PLANT, "amount": 1, "done": true}
		"log":
			board.loose.remove_log(t.log)
			return {"kind": Resources.Kind.LOG, "amount": 1, "done": true}
	return {"done": true}


func redraw(board: TaskBoard) -> void:
	if overlay == null:
		return
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var idx := PackedInt32Array()
	if is_circle() and board.world != null:
		var steps := 64
		for i in steps:
			var a0 := TAU * i / steps
			var a1 := TAU * (i + 1) / steps
			var base := verts.size()
			for a in [a0, a1]:
				for r in [radius - 0.15, radius + 0.15]:
					var x: float = center.x + cos(a) * r
					var z: float = center.y + sin(a) * r
					verts.append(Vector3(x, float(board.world.surface_y(int(x), int(z))) + 1.12, z))
					colors.append(RING_COLOR)
			idx.append_array([base, base + 1, base + 3, base, base + 3, base + 2])
	for t in targets:
		if t.type == "log":
			continue
		var col := MARK_COLOR if t.claimed == null else CLAIMED_COLOR
		var base := verts.size()
		var p := t.pos + Vector3(0.0, 0.05, 0.0)
		var r := 0.55 if t.type == "tree" else 0.35
		verts.append_array([p + Vector3(-r, 0, -r), p + Vector3(r, 0, -r), p + Vector3(r, 0, r), p + Vector3(-r, 0, r)])
		colors.append_array([col, col, col, col])
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var mesh := ArrayMesh.new()
	if not verts.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	overlay.mesh = mesh
