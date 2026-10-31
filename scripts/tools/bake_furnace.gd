extends SceneTree
## Bakes the furnace model: assets/structures/furnace_src.obj (art/blockgen.py, one mesh) -> assets/structures/furnace.res (surface 0 the body with
## its colours: the alpha is the class of the surface for furnace.gdshader, surface 1 the see-through dark panes across the mouths) and
## assets/structures/furnace_glow.res (the glow of the fire in the arches, shown while it burns).
## Run:  godot --headless -s scripts/tools/bake_furnace.gd

const SRC := "res://assets/structures/furnace_src.obj"
const CLAY := Color(0.86, 0.52, 0.31, 1.0)
const STONE := Color(0.70, 0.71, 0.74, 0.66)
const NICHE := Color(0.34, 0.19, 0.11, 0.33)
const CX := 1.01
const CZ := 1.04
const FACE := 0.86            ## half the width of the body at the foot (the plane of the walls of the mouths)


func _initialize() -> void:
	var body := _read()
	var panes := _mouths(0.1)
	var pane_arrays := []
	pane_arrays.resize(Mesh.ARRAY_MAX)
	pane_arrays[Mesh.ARRAY_VERTEX] = panes
	body.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, pane_arrays)
	print("furnace.res ", ResourceSaver.save(body, "res://assets/structures/furnace.res"))
	var glow_arrays := []
	glow_arrays.resize(Mesh.ARRAY_MAX)
	glow_arrays[Mesh.ARRAY_VERTEX] = _mouths(0.23)
	var glow := ArrayMesh.new()
	glow.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, glow_arrays)
	print("furnace_glow.res ", ResourceSaver.save(glow, "res://assets/structures/furnace_glow.res"))
	quit()


func _colour(c: Vector3) -> Color:
	if c.y < 0.435 or (c.x > 1.95 and c.y < 0.44):
		return STONE
	if c.y > 0.42 and c.y < 0.66 and c.z < 0.21 and c.x > 0.5 and c.x < 1.5:
		return STONE   # the stone step of the left mouth
	if c.y > 0.43 and c.y < 1.3:   # the niches of the mouths
		if absf(c.z - CZ) < 0.42 and c.x > CX + FACE - 0.27 and c.x < CX + FACE - 0.001:
			return NICHE
		if absf(c.x - CX) < 0.42 and c.z < CZ - FACE + 0.27 and c.z > CZ - FACE + 0.001:
			return NICHE
	return CLAY


func _read() -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var vs: Array[Vector3] = []
	var ns: Array[Vector3] = []
	for line in FileAccess.get_file_as_string(SRC).split("\n"):
		var p := line.split(" ", false)
		if p.size() == 4 and p[0] == "v":
			vs.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
		elif p.size() == 4 and p[0] == "vn":
			ns.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
		elif p.size() == 4 and p[0] == "f":
			var idx := []
			for k in 3:
				idx.append(int(p[k + 1].split("//")[0]) - 1)
			var col := _colour((vs[idx[0]] + vs[idx[1]] + vs[idx[2]]) / 3.0)
			for k in [0, 2, 1]:   # (clockwise for Godot)
				verts.append(vs[idx[k]])
				norms.append(ns[idx[k]])
				cols.append(col)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The openings of both mouths as flat shapes (a rectangle under a half ellipse) `depth` inside the wall plane.
func _mouths(depth: float) -> PackedVector3Array:
	var out := _opening(true, CZ, 0.6, CX + FACE - depth)
	out.append_array(_opening(false, CX, 0.84, CZ - FACE + depth))
	return out


func _opening(face_x: bool, centre: float, width: float, plane: float) -> PackedVector3Array:
	var y0 := 0.43
	var rect_h := 0.5
	var rise := 0.22
	var out := PackedVector3Array()
	var outline: Array[Vector2] = [Vector2(y0, -width / 2), Vector2(y0, width / 2), Vector2(y0 + rect_h, width / 2)]
	for i in range(1, 8):
		var a := PI * i / 8.0
		outline.append(Vector2(y0 + rect_h + rise * sin(a), width / 2 * cos(a)))
	outline.append(Vector2(y0 + rect_h, -width / 2))
	var mid := Vector2(y0 + 0.1, 0.0)
	for k in outline.size():
		var p0: Vector2 = outline[k]
		var p1: Vector2 = outline[(k + 1) % outline.size()]
		for q in [mid, p0, p1]:
			out.append(Vector3(plane, q.x, centre + q.y) if face_x else Vector3(centre + q.y, q.x, plane))
	return out
