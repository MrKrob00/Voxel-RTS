class_name TaskBoard
extends Node3D
## The list of jobs and the people on them. The player creates a dig task by marking ground; units are assigned to it and
## each assigned unit runs a Worker brain, which this board ticks every frame. Marked ground is drawn as yellow squares.

signal changed

const MARK_COLOR := Color(1.0, 0.82, 0.15, 0.55)

var world: VoxelWorld
var nav: Navigation
var economy: Economy
var tasks: Array[DigTask] = []
var now := 0.0                       ## seconds since start, for retry timers
var _workers := {}                   ## Unit -> Worker
var _next_id := 1
var _dirty := true
var _redraw_timer := 0.0


func setup(w: VoxelWorld, n: Navigation, e: Economy) -> void:
	world = w
	nav = n
	economy = e
	world.block_changed.connect(func(_p: Vector3i) -> void: _dirty = true)


func _process(delta: float) -> void:
	now += delta
	for u in _workers.keys():
		var worker: Worker = _workers[u]
		worker.update(delta)
	# A finished task goes once nobody is still carrying a bag from it to a stockpile.
	for t in tasks.duplicate():
		if t.is_finished() and not t.workers.any(func(u: Unit) -> bool: return u.carried_amount() > 0):
			remove_task(t)
	_redraw_timer -= delta
	if _redraw_timer <= 0.0:
		_redraw_timer = 0.3
		_dirty = true   # claims change the colour of marks
	if _dirty:
		_dirty = false
		for t in tasks:
			_redraw(t)


## Marks the surface block of every column in the rectangle (columns x0..x1, z0..z1, inclusive). Returns the task, or null
## when there was nothing to dig there.
func create_dig(x0: int, z0: int, x1: int, z1: int) -> DigTask:
	var t := DigTask.new()
	for z in range(mini(z0, z1), maxi(z0, z1) + 1):
		for x in range(mini(x0, x1), maxi(x0, x1) + 1):
			var c := world.terrain.surface_target(x, z)
			if c.x >= 0 and world.terrain.can_dig(c):
				t.cells[c] = null
	if t.cells.is_empty():
		return null
	t.id = _next_id
	_next_id += 1
	t.overlay = MeshInstance3D.new()
	t.overlay.name = "DigTask%d" % t.id
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	t.overlay.material_override = m
	add_child(t.overlay)
	tasks.append(t)
	_redraw(t)
	changed.emit()
	return t


func remove_task(t: DigTask) -> void:
	for u in t.workers.duplicate():
		unassign(u)
	tasks.erase(t)
	if t.overlay != null:
		t.overlay.queue_free()
	changed.emit()


func task_of(u: Unit) -> DigTask:
	var w: Worker = _workers.get(u)
	return w.task if w != null else null


func assign(u: Unit, t: DigTask) -> bool:
	if task_of(u) == t:
		return true
	if t.workers.size() >= t.max_workers:
		return false
	unassign(u)
	t.workers.append(u)
	_workers[u] = Worker.new(u, t, self)
	changed.emit()
	return true


func unassign(u: Unit) -> void:
	var w: Worker = _workers.get(u)
	if w == null:
		return
	w.detach()
	w.task.workers.erase(u)
	_workers.erase(u)
	if u.carried_amount() > 0:
		pass   # keeps the bag until it can put it down; manual orders just carry it along
	changed.emit()


## The task a marked cell belongs to, if any (tapping a mark picks the task).
func task_at(c: Vector3i) -> DigTask:
	for t in tasks:
		if t.cells.has(c):
			return t
	return null


func _redraw(t: DigTask) -> void:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var idx := PackedInt32Array()
	for c in t.cells:
		var raw := world.get_block(c)
		var top: float = Blocks.max_height(Blocks.shape(raw)) / float(Blocks.UNIT) if Blocks.is_partial(raw) else 1.0
		var y: float = c.y + top + 0.03
		var claimed: bool = t.cells[c] != null
		var col := MARK_COLOR if not claimed else Color(1.0, 0.55, 0.1, 0.7)
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
	t.overlay.mesh = mesh
