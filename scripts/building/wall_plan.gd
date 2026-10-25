class_name WallPlan
extends Node3D
## A wall the player has planned: a straight run of cells, some courses high, laid as a real wall: each course is offset from the one
## below by a cell (a running bond), 2x1x1 bricks along it and 1x1x1 cubes where a half is needed (the ends of the offset courses, an odd
## length). The wall is built from the bottom up, brick by brick: a slot can be laid only when what it rests on is there.
## A 2x1x1 brick is 2 halves of stone, a cube 1.

class Slot extends RefCounted:
	var origin: Vector3i
	var axis: int          # 0: the brick spans origin and origin + X, 1: origin and origin + Z
	var length: int        # 2 (a brick) or 1 (a cube)
	var kind := "brick"    # "brick" (a brick or cube) or "stairs" (a stair piece in `origin` rising towards a cube next to it)
	var rise := Vector2i.ZERO
	var course: int
	var col := 0           # how many cells from the start of the wall (the entry end) its first cell is
	var done := false
	var claimed: Unit
	var blocked_until := 0.0   ## nobody could get to it: not tried again before this time
	var ghost: MeshInstance3D

	func halves() -> int:
		return 2 if kind == "stairs" else length

	func cells() -> Array[Vector3i]:
		if kind == "stairs":
			return [origin, origin + Vector3i(rise.x, 0, rise.y)]
		return BrickWorld.cells_for(origin, axis, length)


## A unit reaches 2 blocks above its feet to lay a brick, which is enough for 3 courses from the ground. Higher, it climbs the wall's own
## bricks: the course k is started STAIR_RUN cells further along than the course k - 1, so the start of the wall is a staircase one block
## up every STAIR_RUN cells; the units walk up it and lay the courses from the top of the wall. When the body is done the staircase is
## closed in passes with a narrower step (2 cells, then 1 cell, then none), so there is a way up to what is left until the end.
## Such a wall must be long enough: STAIR_RUN * (courses - 1) + 1 cells.
## A taller wall (laid by climbing its own staircase) is NOT reliable yet: see WallTask._run. Until it is, walls are at most REACH_COURSES high.
const REACH_COURSES := 3
const MAX_COURSES := 3
const STAIR_RUN := 2

var slots: Array[Slot] = []
var run_axis := 0           ## 0 along x, 1 along z
var first := Vector3i.ZERO  ## the first cell of the bottom course
var run_length := 1
var courses := 1


## The layout: which bricks and cubes go where. `first` is the lowest cell of the bottom course, the wall runs `length` cells along
## `axis` and stands `height` courses high. Pure data (no scene), so tests can use it.
static func layout(first_cell: Vector3i, axis: int, length: int, height: int) -> Array[Slot]:
	var out: Array[Slot] = []
	var step := Vector3i(1, 0, 0) if axis == 0 else Vector3i(0, 0, 1)
	for course in height:
		var pos := 0
		if course % 2 == 1 and length > 1:
			out.append(_slot(first_cell + step * pos + Vector3i(0, course, 0), axis, 1, course, pos))   # the offset course starts with a cube
			pos = 1
		while pos < length:
			var len := 2 if pos + 1 < length else 1
			out.append(_slot(first_cell + step * pos + Vector3i(0, course, 0), axis, len, course, pos))
			pos += len
	return out


## A stair block of 2 x 1 x 1: a stair piece in `at`, rising towards a whole cube in the next cell `rise` away.
static func stairs_layout(at: Vector3i, rise: Vector2i) -> Array[Slot]:
	var s := _slot(at, 0 if rise.x != 0 else 1, 2, 0)
	s.kind = "stairs"
	s.rise = rise
	var out: Array[Slot] = [s]
	return out


static func _slot(origin_cell: Vector3i, axis: int, len: int, course: int, column := 0) -> Slot:
	var s := Slot.new()
	s.col = column
	s.origin = origin_cell
	s.axis = axis
	s.length = len
	s.course = course
	return s


func covers(c: Vector3i) -> bool:
	for s in slots:
		if not s.done and s.cells().has(c):
			return true
	return false


func total_halves() -> int:
	var n := 0
	for s in slots:
		n += s.halves()
	return n


func remaining_halves() -> int:
	var n := 0
	for s in slots:
		if not s.done:
			n += s.halves()
	return n


func is_done() -> bool:
	for s in slots:
		if not s.done:
			return false
	return true


func build(first_cell: Vector3i, axis: int, length: int, height: int, prepared: Array[Slot] = []) -> void:
	first = first_cell
	run_axis = axis
	run_length = length
	courses = height
	slots = prepared if not prepared.is_empty() else layout(first_cell, axis, length, height)
	name = "Wall_%d_%d" % [first_cell.x, first_cell.z]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.35, 0.65, 1.0, 0.38)
	for s in slots:
		var g := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = (Vector3(2, 1, 1) if s.axis == 0 else Vector3(1, 1, 2)) * 0.96 if s.length == 2 else Vector3.ONE * 0.96
		g.mesh = box
		g.material_override = m
		var cs := s.cells()
		g.position = (Vector3(cs[0]) + Vector3(cs[-1]) + Vector3(1, 1, 1)) * 0.5 - position
		add_child(g)
		s.ghost = g


func mark_done(s: Slot) -> void:
	s.done = true
	s.claimed = null
	if s.ghost != null:
		s.ghost.queue_free()
		s.ghost = null
