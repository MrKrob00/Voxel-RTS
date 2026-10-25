class_name Props
extends RefCounted
## Procedural low-poly models for ground cover: no external assets. Each mesh carries vertex colours and is flat shaded,
## so one StandardMaterial with vertex_color_use_as_albedo draws all of them (and MultiMesh batches each kind).

const _ICO_V := [
	Vector3(-0.526, 0.851, 0.0), Vector3(0.526, 0.851, 0.0), Vector3(-0.526, -0.851, 0.0), Vector3(0.526, -0.851, 0.0),
	Vector3(0.0, -0.526, 0.851), Vector3(0.0, 0.526, 0.851), Vector3(0.0, -0.526, -0.851), Vector3(0.0, 0.526, -0.851),
	Vector3(0.851, 0.0, -0.526), Vector3(0.851, 0.0, 0.526), Vector3(-0.851, 0.0, -0.526), Vector3(-0.851, 0.0, 0.526),
]
const _ICO_F := [
	[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
	[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
]


static func material(double_sided := false) -> Material:
	return DayCycle.world_material(double_sided)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	# Godot front faces are clockwise; callers pass triangles counter-clockwise seen from outside.
	st.set_color(col)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(b)


static func _finish(st: SurfaceTool) -> ArrayMesh:
	st.generate_normals()
	return st.commit()


static func _cone(st: SurfaceTool, base_y: float, height: float, radius: float, sides: int, col_low: Color, col_high: Color, twist := 0.0) -> void:
	var tip := Vector3(0, base_y + height, 0)
	for i in sides:
		var a0 := TAU * i / sides + twist
		var a1 := TAU * (i + 1) / sides + twist
		var p0 := Vector3(cos(a0) * radius, base_y, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, base_y, sin(a1) * radius)
		var shade := 0.88 + 0.12 * float(i % 2)
		_tri(st, p0, tip, p1, col_low.lerp(col_high, 0.5) * shade)
		_tri(st, p0, p1, Vector3(0, base_y, 0), col_low * 0.6)


static func pine() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bark := Color("6b4a2b")
	var sides := 6
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var r := 0.28
		var b0 := Vector3(cos(a0) * r, 0, sin(a0) * r)
		var b1 := Vector3(cos(a1) * r, 0, sin(a1) * r)
		var t0 := b0 + Vector3(0, 1.4, 0)
		var t1 := b1 + Vector3(0, 1.4, 0)
		_tri(st, b0, b1, t1, bark)
		_tri(st, b0, t1, t0, bark)
	var low := Color("2f7a2e")
	var high := Color("4fa23a")
	_cone(st, 0.9, 1.9, 1.5, 7, low, high, 0.0)
	_cone(st, 1.9, 1.7, 1.15, 7, low, high, 0.4)
	_cone(st, 2.9, 1.6, 0.8, 7, low, high, 0.2)
	return _finish(st)


static func boulder(seed_value: int = 0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var verts: Array[Vector3] = []
	for i in _ICO_V.size():
		var v: Vector3 = _ICO_V[i]
		var k := 1.0 + 0.22 * sin(float(i * 12 + seed_value) * 12.9898)
		verts.append(Vector3(v.x * 0.75 * k, v.y * 0.6 * k + 0.15, v.z * 0.75 * k))
	for f in _ICO_F:
		var shade := 0.82 + 0.18 * fmod(absf(sin(float(f[0] * 7 + f[1] * 3 + seed_value))), 1.0)
		_tri(st, verts[f[0]], verts[f[1]], verts[f[2]], Color("8f8f93") * shade)
	return _finish(st)


## A cluster of orange crystals (the furnace ore): tall four-sided pyramids leaning out of one base.
static func crystals() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var specs := [
		[Vector3(0.0, 0.0, 0.0), 1.15, 0.26, 0.0], [Vector3(0.3, 0.0, 0.15), 0.8, 0.2, 0.5],
		[Vector3(-0.28, 0.0, 0.1), 0.9, 0.22, 1.1], [Vector3(0.05, 0.0, -0.3), 0.65, 0.18, 0.8],
		[Vector3(-0.1, 0.0, 0.32), 0.55, 0.16, 1.7], [Vector3(0.42, 0.0, -0.18), 0.5, 0.15, 0.3],
	]
	for sp in specs:
		var base: Vector3 = sp[0]
		var h: float = sp[1]
		var r: float = sp[2]
		var rot: float = sp[3]
		var lean := Vector3(sin(rot) * 0.18, 0, cos(rot) * 0.18)
		var tip := base + Vector3(0, h, 0) + lean
		var mid := base + Vector3(0, h * 0.35, 0)
		for i in 4:
			var a0 := TAU * i / 4.0 + rot
			var a1 := TAU * (i + 1) / 4.0 + rot
			var q0 := mid + Vector3(cos(a0) * r, 0, sin(a0) * r)
			var q1 := mid + Vector3(cos(a1) * r, 0, sin(a1) * r)
			var b0 := base + Vector3(cos(a0) * r * 0.7, 0, sin(a0) * r * 0.7)
			var b1 := base + Vector3(cos(a1) * r * 0.7, 0, sin(a1) * r * 0.7)
			var col := Color("f2931f").lerp(Color("ffb23d"), 0.5 * float(i % 2))
			_tri(st, q0, tip, q1, col)
			_tri(st, b0, q0, q1, col * 0.85)
			_tri(st, b0, q1, b1, col * 0.85)
	return _finish(st)


## A fern / leafy bush: six broad leaves fanning out and curling down at the tips. Used with a double-sided material.
static func tuft() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var leaves := 6
	for i in leaves:
		var a := TAU * i / leaves + 0.35 * (i % 2)
		var dir := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-dir.z, 0, dir.x)
		var lift := 0.34 + 0.12 * float(i % 3)
		var base := dir * 0.08 + Vector3(0, 0.05, 0)
		var left := dir * 0.5 + side * 0.24 + Vector3(0, lift, 0)
		var right := dir * 0.5 - side * 0.24 + Vector3(0, lift, 0)
		var tip := dir * 1.0 + Vector3(0, lift * 0.55, 0)
		var dark := Color("2f7a3a").lerp(Color("3f9440"), fmod(float(i) * 0.37, 1.0))
		var light := Color("58b04a").lerp(Color("7ac85a"), fmod(float(i) * 0.29, 1.0))
		_tri(st, base, left, right, dark)
		_tri(st, left, tip, right, light)
	return _finish(st)
