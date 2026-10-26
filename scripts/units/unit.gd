class_name Unit
extends Node3D
## One worker (a Bricktron stand-in: a yellow blob with a scarf). Knows how to walk a path and how to look; WHAT it does is
## decided by whoever gives it orders (UnitManager for walking, the task system for work), never here.
##
## Position is always `feet` (world units, the ground under it); `cell` is the navigation cell it is in.

signal arrived              ## the end of the current path was reached
signal path_failed          ## no way to the goal (or it was cut off on the way and no other way was found)

const HEIGHT := 1.7          ## blocks tall and 0.8 wide: fits a one-block corridor, needs two free cells in height
const WIDTH := 0.8
const SPEED := 3.6          ## blocks per second on the flat
const TURN_SPEED := 12.0
const BODY_COLOR := Color("f3c22b")
const SCARF_COLOR := Color("3d6fd1")

var nav: Navigation
var cell := Vector3i.ZERO
var selected := false:
	set(v):
		selected = v
		if _ring != null:
			_ring.visible = v
var goal := Vector3i(-1, -1, -1)     ## where the current move order ends
var stop_near := 0.0                  ## accept arriving within this many blocks of the goal (to work on something next to it)

var path: Array[Vector3i] = []
var _seg_t := 0.0
var _seg_len := 1.0
var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _walk_phase := 0.0
## The parts of the model are nodes of scenes/units/unit.tscn: change the look there, in the editor.
@onready var _body: Node3D = $Body
@onready var _ring: MeshInstance3D = $SelectionRing
@onready var _pack: Node3D = $Body/Pack
@onready var _label: Label3D = $StatusLabel
@onready var _bar: MeshInstance3D = $ProgressBar
var _idle_time := 0.0
var _falling := false

## What it carries: {Resources.Kind: bags}; drawn as a sack on its back, coloured by the material.
var carrying := {}
## A short line over its head about what is wrong or going on ("No free stockpile"); empty when all is well.
var status := ""
## 0..1 while it works on something (a bar over its head), -1 when not working.
var progress := -1.0:
	set(v):
		progress = v
		if _bar != null:
			_bar.visible = v >= 0.0
			_bar.scale.x = maxf(v, 0.001)
			_bar.position.x = -0.4 + 0.4 * maxf(v, 0.001)


func _ready() -> void:
	_ring.visible = selected
	_bar.visible = progress >= 0.0
	_label.visible = false


func place_at(c: Vector3i) -> void:
	cell = c
	position = nav.feet_position(c)


func is_moving() -> bool:
	return not path.is_empty()


func is_idle() -> bool:
	return path.is_empty() and not _falling


func carry(kind: int, n: int) -> void:
	carrying = {kind: n} if n > 0 and kind != Resources.Kind.NONE else {}
	_rebuild_carry()


## What is on the unit's back: a sack for stone, ore and grass, a log across the shoulders, three planks lying flat, a coil of rope.
func _rebuild_carry() -> void:
	if _pack == null:
		return
	for c in _pack.get_children():
		c.queue_free()
	var kind := carried_kind()
	var n := carried_amount()
	if n == 0:
		return
	var col: Color = Resources.COLORS.get(kind, Color("8a5a2b"))
	match kind:
		Resources.Kind.LOG:
			_carry_part(_cylinder(LooseLog.RADIUS, LooseLog.LENGTH), Vector3(0.0, 0.2, 0.0), Vector3.ZERO, col)   # the real log, standing upright on the back
		Resources.Kind.PLANK:
			for i in n:
				_carry_part(_box(Stockpile.PLANK_SIZE - Vector3(0.0, 0.02, 0.04)), Vector3(0.0, 0.1 + i * Stockpile.PLANK_SIZE.y, 0.0), Vector3(0.0, 0.0, 0.0), col)   # the real planks, a stack of up to three
		Resources.Kind.ROPE:
			var ring := TorusMesh.new()
			ring.inner_radius = 0.1
			ring.outer_radius = 0.26
			_carry_part(ring, Vector3(0.0, 0.0, 0.0), Vector3(deg_to_rad(90.0), 0.0, 0.0), col)
		_:
			_carry_part(_box(Vector3(0.5, 0.5, 0.28)), Vector3.ZERO, Vector3.ZERO, col)   # a sack


func _carry_part(mesh: Mesh, pos: Vector3, rot: Vector3, col: Color) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _flat_material(col)
	mi.position = pos
	mi.rotation = rot
	_pack.add_child(mi)


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


static func _cylinder(radius: float, height: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = height
	return c


func carried_kind() -> int:
	for k in carrying:
		return k
	return Resources.Kind.NONE


## Turns to face a point (workers face what they dig).
func face(point: Vector3) -> void:
	var d := point - position
	if Vector2(d.x, d.z).length() > 0.01:
		rotation.y = atan2(d.x, d.z)


func carried_amount() -> int:
	var n := 0
	for k in carrying:
		n += carrying[k]
	return n


## Starts walking to `to`. Returns false when there is no way at all; when the goal is cut off the unit walks as close as it
## can (and reports path_failed when it gets there).
func walk_to(to: Vector3i, near := 0.0) -> bool:
	goal = to
	stop_near = near
	return _repath()


func stop() -> void:
	path.clear()
	goal = Vector3i(-1, -1, -1)


func _repath() -> bool:
	var found := nav.find_path(cell, goal, stop_near)
	if found.size() < 2:
		path.clear()
		if found.size() == 1 and nav.last_reached:
			return true
		return false
	path = found
	path.remove_at(0)   # the first cell is where it stands
	_begin_segment()
	return true


func _begin_segment() -> void:
	_from = position
	_to = nav.feet_position(path[0])
	_seg_len = maxf(Vector2(_to.x - _from.x, _to.z - _from.z).length(), 0.35)
	_seg_t = 0.0


func _process(delta: float) -> void:
	_check_ground(delta)
	if not path.is_empty() and not _falling:
		_walk(delta)
	elif not _falling:
		_idle_time += delta
	_animate(delta)


func _walk(delta: float) -> void:
	var next := path[0]
	if not nav.standable(next):
		# The world changed under the path (a block was dug or built): look for another way.
		if not _repath():
			path.clear()
			path_failed.emit()
		return
	var climb := 1.0 + clampf(absf(_to.y - _from.y), 0.0, 1.0) * 0.5 + (0.5 if _seg_len > 1.6 else 0.0)   # hopping and jumping are slower
	_seg_t += delta * SPEED / climb / _seg_len
	if _seg_t >= 1.0:
		position = _to
		cell = next
		path.remove_at(0)
		_idle_time = 0.0
		if path.is_empty():
			var reached := goal.x < 0 or cell == goal or (stop_near > 0.0 and Vector2(cell.x - goal.x, cell.z - goal.z).length() <= stop_near)
			if reached:
				arrived.emit()
			else:
				path_failed.emit()
			return
		_begin_segment()
		return
	var t := smoothstep(0.0, 1.0, _seg_t) if absf(_to.y - _from.y) > 0.3 else _seg_t
	var p := _from.lerp(_to, _seg_t)
	p.y = lerpf(_from.y, _to.y, t)
	var dir := Vector3(_to.x - _from.x, 0.0, _to.z - _from.z)
	if dir.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z), minf(1.0, delta * TURN_SPEED))
	position = p
	# A small hop when going up or down a block, a big jump over a gap.
	if _seg_len > 1.6:
		position.y += sin(_seg_t * PI) * 0.8
	elif absf(_to.y - _from.y) > 0.3:
		position.y += sin(_seg_t * PI) * 0.35
	_walk_phase += delta * 11.0


## If the ground under the unit was dug away it falls to the next floor below (or is lifted out of a block that was built into it).
func _check_ground(delta: float) -> void:
	if not path.is_empty() and not _falling:
		return
	if not _falling and nav.standable(cell):
		var rest := nav.feet_position(cell)
		if absf(position.y - rest.y) > 0.02 and path.is_empty():
			position.y = move_toward(position.y, rest.y, delta * 6.0)   # a slope piece changed shape under it
		return
	if not _falling:
		var below := nav.standable_in_column(cell.x, cell.z, cell.y, 2, 40)
		if below.x < 0:
			below = nav.nearest_standable(cell, 6)
			if below.x < 0:
				return
			position = nav.feet_position(below)
			cell = below
			return
		cell = below
		_falling = true
	var floor_y := nav.feet_position(cell).y
	position.y = move_toward(position.y, floor_y, delta * 14.0)
	if absf(position.y - floor_y) < 0.01:
		_falling = false
		if not path.is_empty() or goal.x >= 0:
			_repath()


func _animate(delta: float) -> void:
	var moving := not path.is_empty() and not _falling
	if moving:
		_body.position.y = absf(sin(_walk_phase)) * 0.07
		_body.rotation.z = sin(_walk_phase) * 0.07
	else:
		_body.position.y = lerpf(_body.position.y, 0.0, minf(1.0, delta * 10.0))
		_body.rotation.z = lerpf(_body.rotation.z, 0.0, minf(1.0, delta * 10.0))
	if status != "":
		_label.text = status
		_label.visible = true
	else:
		_label.text = "Nothing to do"
		_label.visible = selected and is_idle() and _idle_time > 1.0


static func _flat_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	return m
