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
	var course: int
	var done := false
	var claimed: Unit
	var blocked_until := 0.0   ## nobody could get to it: not tried again before this time
	var ghost: MeshInstance3D

	func halves() -> int:
		return length

	func cells() -> Array[Vector3i]:
		return BrickWorld.cells_for(origin, axis, length)


## A unit reaches this far above its feet to lay a brick (2 blocks up from the cell it stands in), so a wall can be built from the ground
## to 3 courses; higher needs scaffolding, which does not exist yet.
const MAX_COURSES := 3

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
			out.append(_slot(first_cell + step * pos + Vector3i(0, course, 0), axis, 1, course))   # the offset course starts with a cube
			pos = 1
		while pos < length:
			var len := 2 if pos + 1 < length else 1
			out.append(_slot(first_cell + step * pos + Vector3i(0, course, 0), axis, len, course))
			pos += len
	return out


static func _slot(origin_cell: Vector3i, axis: int, len: int, course: int) -> Slot:
	var s := Slot.new()
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


func build(first_cell: Vector3i, axis: int, length: int, height: int) -> void:
	first = first_cell
	run_axis = axis
	run_length = length
	courses = height
	slots = layout(first_cell, axis, length, height)
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
		g.position = BrickWorld.center_for(s.origin, s.axis, s.length) - position
		add_child(g)
		s.ghost = g


func mark_done(s: Slot) -> void:
	s.done = true
	s.claimed = null
	if s.ghost != null:
		s.ghost.queue_free()
		s.ghost = null
