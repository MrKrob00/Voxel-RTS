class_name BlockCatalog
extends RefCounted
## Every block the player can build, as in the original's "Blocks" panel: its section, how many cells it covers along its length (1 or
## 2), what it is made of, and the shape it is drawn with. A shape is a short list of parts (boxes, wedges, cylinders...) in the
## block's own space: x along its length, centred on the middle of the block, y up, one block high. The meshes are made once from it.
##
## What a stone block costs does not depend on its shape: one block of stone (a brick in the stack) each, whether it is a cube or a
## brick (see WallPlan.Slot.halves). Wood blocks cost one plank each (not built yet).

const STONE := "stone"
const WOOD := "wood"
const SECTIONS := ["Stone Blocks", "Plugs", "Round Bricks", "Crenelations", "Wood Blocks"]

static var _defs: Array[Dictionary] = []
static var _meshes := {}


static func _b(p: Vector3, s: Vector3) -> Dictionary:
	return {"t": "box", "p": p, "s": s}


## A wedge: the top slopes from nothing at -x up to the full height at +x.
static func _w(p: Vector3, s: Vector3) -> Dictionary:
	return {"t": "wedge", "p": p, "s": s}


static func _c(p: Vector3, r: float, h: float, axis := "y", r_top := -1.0) -> Dictionary:
	return {"t": "cyl", "p": p, "r": r, "h": h, "axis": axis, "r_top": r if r_top < 0.0 else r_top}


static func _d(id: String, section: String, label: String, length: int, material: String, parts: Array, key := "", special := "") -> void:
	_defs.append({"id": id, "section": section, "label": label, "length": length, "material": material, "parts": parts, "key": key, "special": special})


static func all() -> Array[Dictionary]:
	if _defs.is_empty():
		_build()
	return _defs


static func get_def(id: String) -> Dictionary:
	for d in all():
		if d.id == id:
			return d
	return {}


static func index_of(id: String) -> int:
	var defs := all()
	for i in defs.size():
		if defs[i].id == id:
			return i
	return -1


static func _build() -> void:
	var S := "Stone Blocks"
	var m := STONE
	_d("brick", S, "Brick", 2, m, [_b(Vector3.ZERO, Vector3(2, 1, 1))], "B")
	_d("cube", S, "Cube", 1, m, [_b(Vector3.ZERO, Vector3.ONE)], "H")
	_d("stairs", S, "Stairs", 2, m, [], "R", "stairs")      # steps of ground and a cube: built as terrain (see Economy.place_stairs)
	_d("stairs_cube", S, "Steps", 1, m, [_b(Vector3(0.0, -0.25, 0.0), Vector3(1, 0.5, 1)), _b(Vector3(0.25, 0.25, 0.0), Vector3(0.5, 0.5, 1))])
	_d("ramp", S, "Ramp", 2, m, [_w(Vector3.ZERO, Vector3(2, 1, 1))])
	_d("ramp_cube", S, "Ramp 1", 1, m, [_w(Vector3.ZERO, Vector3(1, 1, 1))])
	_d("slab", S, "Slab", 2, m, [_b(Vector3(0, -0.25, 0), Vector3(2, 0.5, 1))])
	_d("slab_cube", S, "Slab 1", 1, m, [_b(Vector3(0, -0.25, 0), Vector3(1, 0.5, 1))])
	_d("step", S, "Step", 2, m, [_b(Vector3(0, -0.25, 0), Vector3(2, 0.5, 1)), _b(Vector3(0.5, 0.25, 0), Vector3(1, 0.5, 1))])
	_d("corner", S, "Corner", 2, m, [_b(Vector3(0, -0.25, 0), Vector3(2, 0.5, 1)), _b(Vector3(0.5, 0.25, 0.25), Vector3(1, 0.5, 0.5))])
	_d("pyramid", S, "Pyramid", 1, m, [_b(Vector3(0, -0.375, 0), Vector3(1, 0.25, 1)), _b(Vector3(0, -0.125, 0), Vector3(0.7, 0.25, 0.7)), _b(Vector3(0, 0.125, 0), Vector3(0.4, 0.25, 0.4)), _b(Vector3(0, 0.375, 0), Vector3(0.18, 0.25, 0.18))])
	_d("cone", S, "Cone", 1, m, [_c(Vector3.ZERO, 0.5, 1.0, "y", 0.12)])
	_d("tower_top", S, "Tower top", 1, m, [_c(Vector3(0, -0.15, 0), 0.3, 0.7), _c(Vector3(0, 0.35, 0), 0.5, 0.3)], "I")
	_d("tower_foot", S, "Tower foot", 1, m, [_c(Vector3(0, -0.35, 0), 0.5, 0.3), _c(Vector3(0, 0.15, 0), 0.3, 0.7)])
	_d("pillar", S, "Pillar", 1, m, [_c(Vector3.ZERO, 0.4, 1.0)])
	_d("pillar_thin", S, "Post", 1, m, [_c(Vector3.ZERO, 0.22, 1.0)])
	_d("pillar_short", S, "Stump", 1, m, [_c(Vector3(0, -0.25, 0), 0.4, 0.5)])

	var P := "Plugs"      # a notch, to put a wooden beam or post into
	_d("plug_side", P, "Plug", 1, m, [_b(Vector3(-0.2, 0, 0), Vector3(0.6, 1, 1)), _b(Vector3(0.3, 0.3, 0), Vector3(0.4, 0.4, 1)), _b(Vector3(0.3, -0.3, 0), Vector3(0.4, 0.4, 1))], "U")
	_d("plug_top", P, "Plug top", 1, m, [_b(Vector3(0, -0.2, 0), Vector3(1, 0.6, 1)), _b(Vector3(-0.3, 0.3, 0), Vector3(0.4, 0.4, 1)), _b(Vector3(0.3, 0.3, 0), Vector3(0.4, 0.4, 1))])
	_d("plug_two", P, "Plug 2", 1, m, [_b(Vector3(0, 0, 0), Vector3(0.4, 1, 1)), _b(Vector3(-0.35, 0.3, 0), Vector3(0.3, 0.4, 1)), _b(Vector3(0.35, 0.3, 0), Vector3(0.3, 0.4, 1)), _b(Vector3(-0.35, -0.3, 0), Vector3(0.3, 0.4, 1)), _b(Vector3(0.35, -0.3, 0), Vector3(0.3, 0.4, 1))])
	_d("plug_low", P, "Plug low", 1, m, [_b(Vector3(0, -0.25, 0), Vector3(1, 0.5, 1)), _b(Vector3(-0.2, 0.25, 0), Vector3(0.6, 0.5, 1)), _b(Vector3(0.4, 0.25, 0), Vector3(0.2, 0.5, 1))])
	_d("plug_long", P, "Plug long", 2, m, [_b(Vector3(0, -0.2, 0), Vector3(2, 0.6, 1)), _b(Vector3(-0.8, 0.3, 0), Vector3(0.4, 0.4, 1)), _b(Vector3(0.8, 0.3, 0), Vector3(0.4, 0.4, 1)), _b(Vector3(0, 0.3, 0), Vector3(0.4, 0.4, 1))])

	var R := "Round Bricks"
	_d("round_brick", R, "Round", 2, m, [_c(Vector3.ZERO, 0.5, 2.0, "x")], "O")
	_d("round_half", R, "Round half", 2, m, [_b(Vector3(0, -0.25, 0), Vector3(2, 0.5, 1)), _c(Vector3(0, 0.0, 0), 0.5, 2.0, "x")])
	_d("round_end", R, "Round end", 2, m, [_b(Vector3(0, 0, 0), Vector3(1.0, 1, 1)), _c(Vector3(0.5, 0, 0), 0.5, 1.0, "x"), _b(Vector3(-0.5, -0.25, 0), Vector3(1, 0.5, 1))])
	_d("round_cube", R, "Round 1", 1, m, [_c(Vector3.ZERO, 0.5, 1.0, "x")])

	var C := "Crenelations"
	_d("merlon", C, "Merlon", 2, m, [_b(Vector3(0, -0.25, 0), Vector3(2, 0.5, 1)), _b(Vector3(-0.75, 0.25, 0), Vector3(0.5, 0.5, 1)), _b(Vector3(0.75, 0.25, 0), Vector3(0.5, 0.5, 1))], "Y")
	_d("merlon_cube", C, "Merlon 1", 1, m, [_b(Vector3(0, -0.25, 0), Vector3(1, 0.5, 1)), _b(Vector3(0, 0.25, 0), Vector3(0.5, 0.5, 1))], "L")
	_d("crenel_wedge", C, "Wedge", 1, m, [_w(Vector3(0, -0.25, 0), Vector3(1, 0.5, 1)), _b(Vector3(0.0, -0.375, 0), Vector3(1, 0.25, 1))], "M")
	_d("crenel_ramp", C, "Wedge 2", 2, m, [_w(Vector3(0, -0.25, 0), Vector3(2, 0.5, 1)), _b(Vector3(0.0, -0.375, 0), Vector3(2, 0.25, 1))])
	_d("crenel_tower", C, "Tower", 1, m, [_b(Vector3(0, -0.25, 0), Vector3(1, 0.5, 1)), _b(Vector3(-0.35, 0.25, -0.35), Vector3(0.3, 0.5, 0.3)), _b(Vector3(0.35, 0.25, -0.35), Vector3(0.3, 0.5, 0.3)), _b(Vector3(-0.35, 0.25, 0.35), Vector3(0.3, 0.5, 0.3)), _b(Vector3(0.35, 0.25, 0.35), Vector3(0.3, 0.5, 0.3))], "J")
	_d("crenel_half", C, "Cap", 2, m, [_b(Vector3(0, -0.25, 0), Vector3(2, 0.5, 1)), _b(Vector3(0, 0.1, 0), Vector3(1.2, 0.2, 0.6))])

	var W := "Wood Blocks"
	var w := WOOD
	_d("log", W, "Log", 2, w, [_c(Vector3.ZERO, 0.32, 2.0, "x")], "N")
	_d("beam", W, "Beam", 2, w, [_b(Vector3.ZERO, Vector3(2, 0.3, 0.3))])
	_d("post", W, "Post", 1, w, [_c(Vector3.ZERO, 0.18, 1.0)], "V")
	_d("wood_wedge", W, "Wedge", 1, w, [_w(Vector3.ZERO, Vector3(1, 1, 0.3))])
	_d("board", W, "Board", 2, w, [_b(Vector3(0, -0.44, 0), Vector3(2, 0.12, 1))], "K")
	_d("plank", W, "Plank", 2, w, [_b(Vector3(0, -0.44, 0), Vector3(2, 0.12, 0.5))], "Z")
	_d("plank_small", W, "Small plank", 1, w, [_b(Vector3(0, -0.44, 0), Vector3(1, 0.12, 0.5))])


## The mesh of a block, lying along x (turn it 90 degrees about y for the z axis).
static func mesh(id: String) -> ArrayMesh:
	if _meshes.has(id):
		return _meshes[id]
	var d := get_def(id)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in d.get("parts", []):
		match part.t:
			"box":
				_box(st, part.p, part.s)
			"wedge":
				_wedge(st, part.p, part.s)
			"cyl":
				_cyl(st, part.p, part.r, part.r_top, part.h, part.axis)
	if d.get("parts", []).is_empty():
		_box(st, Vector3.ZERO, Vector3(d.get("length", 1), 1, 1))
	st.generate_normals()
	var m := st.commit()
	_meshes[id] = m
	return m


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(c)   # Godot's front faces are clockwise: callers pass counter-clockwise seen from outside
	st.add_vertex(b)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(st, a, b, c)
	_tri(st, a, c, d)


static func _box(st: SurfaceTool, p: Vector3, s: Vector3) -> void:
	var h := s * 0.5
	var v := func(x: int, y: int, z: int) -> Vector3: return p + Vector3(h.x * x, h.y * y, h.z * z)
	_quad(st, v.call(1, -1, -1), v.call(1, 1, -1), v.call(1, 1, 1), v.call(1, -1, 1))      # +x
	_quad(st, v.call(-1, -1, 1), v.call(-1, 1, 1), v.call(-1, 1, -1), v.call(-1, -1, -1))  # -x
	_quad(st, v.call(-1, 1, -1), v.call(-1, 1, 1), v.call(1, 1, 1), v.call(1, 1, -1))      # +y
	_quad(st, v.call(-1, -1, 1), v.call(-1, -1, -1), v.call(1, -1, -1), v.call(1, -1, 1))  # -y
	_quad(st, v.call(-1, -1, 1), v.call(1, -1, 1), v.call(1, 1, 1), v.call(-1, 1, 1))      # +z
	_quad(st, v.call(1, -1, -1), v.call(-1, -1, -1), v.call(-1, 1, -1), v.call(1, 1, -1))  # -z


static func _wedge(st: SurfaceTool, p: Vector3, s: Vector3) -> void:
	var h := s * 0.5
	var lo := p.y - h.y
	var hi := p.y + h.y
	var x0 := p.x - h.x
	var x1 := p.x + h.x
	var z0 := p.z - h.z
	var z1 := p.z + h.z
	_quad(st, Vector3(x1, lo, z0), Vector3(x1, hi, z0), Vector3(x1, hi, z1), Vector3(x1, lo, z1))        # the tall end
	_quad(st, Vector3(x0, lo, z1), Vector3(x1, lo, z1), Vector3(x1, lo, z0), Vector3(x0, lo, z0))        # the bottom
	_quad(st, Vector3(x0, lo, z0), Vector3(x1, hi, z0), Vector3(x1, hi, z1), Vector3(x0, lo, z1))        # the slope
	_tri(st, Vector3(x0, lo, z0), Vector3(x1, lo, z0), Vector3(x1, hi, z0))                              # sides
	_tri(st, Vector3(x1, hi, z1), Vector3(x1, lo, z1), Vector3(x0, lo, z1))


static func _cyl(st: SurfaceTool, p: Vector3, r: float, r_top: float, h: float, axis: String) -> void:
	var n := 14
	var to_world := func(local: Vector3) -> Vector3:
		return p + (local if axis == "y" else Vector3(local.y, local.x, local.z))   # along x: the cylinder's y is the block's x
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		var b0 := Vector3(cos(a0) * r, -h * 0.5, sin(a0) * r)
		var b1 := Vector3(cos(a1) * r, -h * 0.5, sin(a1) * r)
		var t0 := Vector3(cos(a0) * r_top, h * 0.5, sin(a0) * r_top)
		var t1 := Vector3(cos(a1) * r_top, h * 0.5, sin(a1) * r_top)
		var flip := axis == "y"   # (the along-x cylinder is mirrored by the axis swap, which turns the winding round)
		var wb0: Vector3 = to_world.call(b0)
		var wb1: Vector3 = to_world.call(b1)
		var wt0: Vector3 = to_world.call(t0)
		var wt1: Vector3 = to_world.call(t1)
		var wc_b: Vector3 = to_world.call(Vector3(0, -h * 0.5, 0))
		var wc_t: Vector3 = to_world.call(Vector3(0, h * 0.5, 0))
		if flip:
			_quad(st, wb1, wb0, wt0, wt1)
			_tri(st, wc_t, wt1, wt0)
			_tri(st, wc_b, wb0, wb1)
		else:
			_quad(st, wb0, wb1, wt1, wt0)
			_tri(st, wc_t, wt0, wt1)
			_tri(st, wc_b, wb1, wb0)
