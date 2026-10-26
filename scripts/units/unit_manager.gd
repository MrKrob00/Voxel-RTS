class_name UnitManager
extends Node3D
## Owns the units, the selection and walking orders. Task work (digging, hauling) is layered on top by the task system, which
## also gives units orders through `command_move`/`Unit.walk_to`; this class only knows how to select and send people somewhere.

signal selection_changed(selected: Array)
const UNIT_SCENE := preload("res://scenes/units/unit.tscn")

signal ordered(unit: Unit)   ## the player told this unit to go somewhere: any job it had is over

var world: VoxelWorld
var nav: Navigation
var units: Array[Unit] = []
var selection: Array[Unit] = []

var _marker: MeshInstance3D
var _marker_time := 99.0


func setup(w: VoxelWorld, b: BrickWorld) -> void:
	world = w
	nav = Navigation.new(w, b)
	_marker = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.32
	ring.outer_radius = 0.42
	_marker.mesh = ring
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.95, 0.4)
	m.no_depth_test = true
	_marker.material_override = m
	_marker.visible = false
	add_child(_marker)


func _process(delta: float) -> void:
	if _marker_time < 0.8:
		_marker_time += delta
		var t := _marker_time / 0.8
		_marker.scale = Vector3.ONE * lerpf(1.6, 0.7, t)
		_marker.visible = t < 1.0
	elif _marker.visible:
		_marker.visible = false


# --- units ------------------------------------------------------------------------------------------

func spawn(c: Vector3i) -> Unit:
	var u := UNIT_SCENE.instantiate() as Unit
	u.nav = nav
	u.name = "Unit%d" % units.size()
	add_child(u)
	u.place_at(c)
	u.rotation.y = randf() * TAU
	units.append(u)
	return u


## `count` units on free standable cells around `centre` (a standable cell), at least `ring` blocks away from it.
func spawn_squad(centre: Vector3i, count: int, ring := 2) -> Array[Unit]:
	var made: Array[Unit] = []
	for c in formation_cells(centre, count, ring):
		made.append(spawn(c))
	return made


## `count` distinct standable cells near `centre`, spiralling outwards, none closer than `min_ring` columns.
func formation_cells(centre: Vector3i, count: int, min_ring := 0, taken := {}) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var used := taken.duplicate()
	var r := min_ring
	while out.size() < count and r <= 12:
		var ring_cells: Array[Vector3i] = []
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var c := nav.standable_in_column(centre.x + dx, centre.z + dz, centre.y, 2, 3)
				if c.x >= 0 and not used.has(c):
					ring_cells.append(c)
		ring_cells.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
			return Vector2(a.x - centre.x, a.z - centre.z).length() < Vector2(b.x - centre.x, b.z - centre.z).length())
		for c in ring_cells:
			if out.size() >= count:
				break
			out.append(c)
			used[c] = true
		r += 1
	return out


# --- selection --------------------------------------------------------------------------------------

func unit_at(screen_pos: Vector2, camera: Camera3D) -> Unit:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var best: Unit = null
	var best_t := INF
	for u in units:
		var centre := u.position + Vector3(0, Unit.HEIGHT * 0.5, 0)
		var to := centre - from
		var t := to.dot(dir)
		if t < 0.0:
			continue
		if (from + dir * t).distance_to(centre) < 0.95 and t < best_t:   # a little more than the body: fingers are not precise
			best_t = t
			best = u
	return best


func select_only(u: Unit) -> void:
	_set_selection([u] if u != null else [])


func toggle(u: Unit) -> void:
	var s := selection.duplicate()
	if s.has(u):
		s.erase(u)
	else:
		s.append(u)
	_set_selection(s)


func select_rect(rect: Rect2, camera: Camera3D, additive := false) -> void:
	var picked: Array = selection.duplicate() if additive else []
	for u in units:
		var p := u.position + Vector3(0, Unit.HEIGHT * 0.5, 0)
		if camera.is_position_behind(p):
			continue
		if rect.has_point(camera.unproject_position(p)) and not picked.has(u):
			picked.append(u)
	_set_selection(picked)


func select_all() -> void:
	_set_selection(units.duplicate())


## Selects the units that are idle (the ones with "Nothing to do").
func select_idle() -> void:
	_set_selection(units.filter(func(u: Unit) -> bool: return u.is_idle()))


func clear_selection() -> void:
	_set_selection([])


func _set_selection(list: Array) -> void:
	for u in selection:
		u.selected = false
	selection.clear()
	for u in list:
		selection.append(u)
		u.selected = true
	selection_changed.emit(selection)


# --- orders -----------------------------------------------------------------------------------------

## Sends the selected units to stand around a cell. Returns how many found a way.
func command_move(goal: Vector3i) -> int:
	if selection.is_empty():
		return 0
	var cells := formation_cells(goal, selection.size())
	if cells.is_empty():
		return 0
	# The nearest unit takes the nearest slot, so that nobody crosses over.
	var free: Array[Unit] = selection.duplicate()
	var moved := 0
	for c in cells:
		if free.is_empty():
			break
		var best: Unit = free[0]
		for u in free:
			if Vector2(u.cell.x - c.x, u.cell.z - c.z).length() < Vector2(best.cell.x - c.x, best.cell.z - c.z).length():
				best = u
		free.erase(best)
		ordered.emit(best)
		if best.walk_to(c):
			moved += 1
	show_marker(nav.feet_position(goal))
	return moved


func show_marker(at: Vector3) -> void:
	_marker.position = at + Vector3(0, 0.08, 0)
	_marker_time = 0.0
	_marker.visible = true
