class_name HarvestTask
extends WorkTask
## A marked area of trees or grass to be harvested. Trees are felled (4 s) and drop 3 logs as physics bodies; the same crew picks
## the logs up and carries them away, one at a time, on their backs. Grass is cut tuft by tuft into sacks.

enum Kind { TREES, GRASS }

const CHOP_TIME := 4.0
const CUT_TIME := 1.4
const PICK_TIME := 0.6
const LOGS_PER_TREE := 3
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

var harvest_kind := Kind.TREES
var targets: Array[Target] = []


func _init(k := Kind.TREES) -> void:
	harvest_kind = k
	title = "Fell trees" if k == Kind.TREES else "Cut grass"


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


func is_finished() -> bool:
	return targets.is_empty()


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
		if t.claimed != null or t.blocked_until > now:
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


func face_point(target: Variant) -> Vector3:
	var t: Target = target
	return t.pos if t != null else Vector3.ZERO


func work_time(target: Variant) -> float:
	match (target as Target).type:
		"tree":
			return CHOP_TIME
		"plant":
			return CUT_TIME
	return PICK_TIME


func perform(target: Variant, board: TaskBoard) -> Dictionary:
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
