class_name DigTask
extends RefCounted
## A marked area of ground to be dug away: the player marks columns, workers take the marked blocks one at a time.
## The task keeps the list of cells still to do and who has claimed which; the marker mesh is drawn by TaskBoard.

var id := 0
var max_workers := 8
var cells := {}          ## Vector3i -> Unit that claimed it (or null)
var workers: Array[Unit] = []
var blocked := {}        ## Vector3i -> time until which nobody tries it again (unreachable just now)
var overlay: MeshInstance3D
## Which of the things this task digs up are brought home. The rest (and all earth) is broken and thrown away: a quarry can be
## told to bring iron only, and the stone it breaks on the way just disappears.
var collect := {Resources.Kind.STONE: true, Resources.Kind.COAL: true, Resources.Kind.IRON: true, Resources.Kind.AMBER: true}


func collects(kind: int) -> bool:
	return collect.get(kind, false)


func cell_count() -> int:
	return cells.size()


func is_finished() -> bool:
	return cells.is_empty()


func has_free_cell() -> bool:
	for c in cells:
		if cells[c] == null:
			return true
	return false


## The nearest unclaimed cell to `from`, claimed for `unit`; (-1,-1,-1) when nothing is free. `now` skips cells that failed lately.
func claim(unit: Unit, from: Vector3i, now: float) -> Vector3i:
	var best := Vector3i(-1, -1, -1)
	var best_d := INF
	for c in cells:
		if cells[c] != null or blocked.get(c, 0.0) > now:
			continue
		var d := Vector2(c.x - from.x, c.z - from.z).length() + absf(c.y - from.y) * 0.5
		if d < best_d:
			best_d = d
			best = c
	if best.x >= 0:
		cells[best] = unit
	return best


func release(c: Vector3i, retry_after := 0.0) -> void:
	if cells.has(c):
		cells[c] = null
		if retry_after > 0.0:
			blocked[c] = retry_after


func complete(c: Vector3i) -> void:
	cells.erase(c)
	blocked.erase(c)
