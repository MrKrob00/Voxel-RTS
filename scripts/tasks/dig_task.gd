class_name DigTask
extends WorkTask
## A marked area of ground to be dug away: the player marks columns, workers take the marked blocks one at a time. A block takes
## two stages (whole -> half dug -> gone); every stage gives one bag of what the block is made of, and earth gives nothing.

const WORK_TIME := 1.3
const MARK_COLOR := Color(1.0, 0.82, 0.15, 0.55)

## A quarry digs down layer by layer: `depth` layers over `columns`, but column (x, z) only down to `limits[(x, z)]` layers (default
## `depth`). Along the edge of the area the limits climb 0, 1, 2, 3, ...: what is left standing there is a staircase down into the pit
## (made of whatever the ground is: earth or stone) that units walk down and climb back out of. Every column of it is one step down
## and ends in a stair piece, back to back, so the staircase is as short as it can be. Only at a corner, where it has to turn, is there a
## flat landing.
var depth := 1
var columns: Array[Vector2i] = []
var limits := {}         ## Vector2i -> how many layers that column is dug
var layer := 0           ## the layer being dug now (0: none opened yet)
var stair_columns: Array[Vector2i] = []   ## the columns of the staircase, from the top down
var stair_rise := {}                      ## Vector2i -> the way its stair piece rises (towards the column before it); landings have none
var cells := {}          ## Vector3i -> Unit that claimed it (or null) -- the blocks of the current layer
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
	return cells.is_empty() and layer >= depth


func summary() -> String:
	if depth > 1:
		return "Quarry #%d: layer %d of %d, %d blocks left in it, %d/%d workers" % [id, mini(layer, depth), depth, cells.size(), workers.size(), max_workers]
	return "Dig #%d: %d blocks, %d/%d workers" % [id, cells.size(), workers.size(), max_workers]


func detail() -> String:
	return "%d blocks%s" % [cells.size(), (", layer %d/%d" % [mini(layer, depth), depth]) if depth > 1 else ""]


## Opens the next layer when the one before is dug: marks the top block of every column that is still to be dug that deep.
func update(board: TaskBoard) -> void:
	while cells.is_empty() and layer < depth:
		layer += 1
		for col in columns:
			if limits.get(col, depth) < layer:
				continue
			var c := board.world.terrain.surface_target(col.x, col.y)
			if c.x >= 0 and board.world.terrain.can_dig(c):
				cells[c] = null
		if depth == 1:
			break


## Is there a block nobody has claimed and that is not being left alone after a failed try? Then a free unit should come and help.
func wants_workers(brd: TaskBoard) -> bool:
	if workers.size() >= max_workers:
		return false
	for c in cells:
		if cells[c] == null and blocked.get(c, 0.0) <= brd.now:
			return true
	return false


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
	if target == null:
		# Where the job is, for the unit that comes to help: its first block.
		for first in cells:
			return Vector3(first.x + 0.5, first.y + 0.5, first.z + 0.5)
		return Vector3.ZERO
	var c: Vector3i = target
	return Vector3(c.x + 0.5, c.y + 0.5, c.z + 0.5)


func work_time(_target: Variant) -> float:
	return WORK_TIME


func perform(target: Variant, board: TaskBoard, _unit: Unit = null) -> Dictionary:
	var c: Vector3i = target
	var kind := Resources.from_block(Blocks.mat(board.world.get_block(c)))
	if kind != Resources.Kind.NONE and not collects(kind):
		kind = Resources.Kind.NONE   # not wanted: broken and thrown away, like earth
	board.world.terrain.dig_step(c)
	var gone := not board.world.terrain.can_dig(c)
	if gone:
		_leave_stair_step(c, board)
	return {"kind": kind, "amount": 1 if kind != Resources.Kind.NONE else 0, "done": gone}


## At every column of the staircase but the landings, once its last layer is dug, a stair piece is left on the new floor: four small
## steps from this floor up to the one before it, instead of a jump of a whole block.
func _leave_stair_step(dug: Vector3i, board: TaskBoard) -> void:
	var col := Vector2i(dug.x, dug.z)
	if not stair_rise.has(col) or limits.get(col, depth) != layer:
		return
	board.world.terrain.make_stairs(Vector3i(dug.x, dug.y, dug.z), stair_rise[col])


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
