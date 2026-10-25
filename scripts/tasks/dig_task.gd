class_name DigTask
extends WorkTask
## A marked area of ground to be dug away: the player marks columns, workers take the marked blocks one at a time. A block takes
## two stages (whole -> half dug -> gone); every stage gives one bag of what the block is made of, and earth gives nothing.

const WORK_TIME := 1.3
const MARK_COLOR := Color(1.0, 0.82, 0.15, 0.55)

var cells := {}          ## Vector3i -> Unit that claimed it (or null)
var blocked := {}        ## Vector3i -> time until which nobody tries it again (unreachable just now)
## Which of the things this task digs up are brought home. The rest (and all earth) is broken and thrown away: a quarry can be
## told to bring iron only, and the stone it breaks on the way just disappears.
var collect := {Resources.Kind.STONE: true, Resources.Kind.COAL: true, Resources.Kind.IRON: true, Resources.Kind.AMBER: true}


func _init() -> void:
	title = "Dig"


func collects(kind: int) -> bool:
	return collect.get(kind, false)


func cell_count() -> int:
	return cells.size()


func is_finished() -> bool:
	return cells.is_empty()


func summary() -> String:
	return "Dig #%d: %d blocks, %d/%d workers" % [id, cells.size(), workers.size(), max_workers]


func has_free_cell() -> bool:
	for c in cells:
		if cells[c] == null:
			return true
	return false


func claim(unit: Unit, from: Vector3i, now: float) -> Variant:
	var best: Variant = null
	var best_d := INF
	for c in cells:
		if cells[c] != null or blocked.get(c, 0.0) > now:
			continue
		var d := Vector2(c.x - from.x, c.z - from.z).length() + absf(c.y - from.y) * 0.5
		if d < best_d:
			best_d = d
			best = c
	if best != null:
		cells[best] = unit
	return best


func release(target: Variant, retry_after := 0.0) -> void:
	if cells.has(target):
		cells[target] = null
		if retry_after > 0.0:
			blocked[target] = retry_after


func complete(target: Variant) -> void:
	cells.erase(target)
	blocked.erase(target)


func holds(target: Variant) -> bool:
	return cells.has(target)


func valid(target: Variant, board: TaskBoard) -> bool:
	return board.world.terrain.can_dig(target)


func stand_cells(target: Variant, board: TaskBoard) -> Array[Vector3i]:
	return board.nav.work_cells(target)


func face_point(target: Variant) -> Vector3:
	var c: Vector3i = target
	return Vector3(c.x + 0.5, c.y + 0.5, c.z + 0.5)


func work_time(_target: Variant) -> float:
	return WORK_TIME


func perform(target: Variant, board: TaskBoard) -> Dictionary:
	var c: Vector3i = target
	var kind := Resources.from_block(Blocks.mat(board.world.get_block(c)))
	if kind != Resources.Kind.NONE and not collects(kind):
		kind = Resources.Kind.NONE   # not wanted: broken and thrown away, like earth
	board.world.terrain.dig_step(c)
	return {"kind": kind, "amount": 1 if kind != Resources.Kind.NONE else 0, "done": not board.world.terrain.can_dig(c)}


func mark_dirty() -> void:
	pass


func redraw(board: TaskBoard) -> void:
	if overlay == null:
		return
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var idx := PackedInt32Array()
	for c in cells:
		var raw := board.world.get_block(c)
		var top: float = Blocks.max_height(Blocks.shape(raw)) / float(Blocks.UNIT) if Blocks.is_partial(raw) else 1.0
		var y: float = c.y + top + 0.03
		var col := MARK_COLOR if cells[c] == null else Color(1.0, 0.55, 0.1, 0.7)
		var base := verts.size()
		verts.append_array([Vector3(c.x + 0.06, y, c.z + 0.06), Vector3(c.x + 0.94, y, c.z + 0.06), Vector3(c.x + 0.94, y, c.z + 0.94), Vector3(c.x + 0.06, y, c.z + 0.94)])
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
