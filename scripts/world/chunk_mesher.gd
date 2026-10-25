class_name ChunkMesher
extends RefCounted
## Builds mesh arrays for one chunk from a 3x3x3 snapshot of chunk data (centre chunk at index 13).
## Culls hidden faces and bakes ambient occlusion into vertex colour. Runs on worker threads.

const FACE_NORMALS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
# Tangent axes per face, chosen so that u x v == normal.
const FACE_U: Array[Vector3i] = [
	Vector3i(0, 1, 0), Vector3i(0, 0, 1),
	Vector3i(0, 0, 1), Vector3i(1, 0, 0),
	Vector3i(1, 0, 0), Vector3i(0, 1, 0),
]
const FACE_V: Array[Vector3i] = [
	Vector3i(0, 0, 1), Vector3i(0, 1, 0),
	Vector3i(1, 0, 0), Vector3i(0, 0, 1),
	Vector3i(0, 1, 0), Vector3i(1, 0, 0),
]
const FACE_SHADE: Array[float] = [0.82, 0.74, 1.0, 0.55, 0.9, 0.68]
const AO_LEVELS: Array[float] = [0.5, 0.68, 0.84, 1.0]
const CORNER_SIGNS: Array[Vector2i] = [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1)]


class Buffers extends RefCounted:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	func to_arrays() -> Array:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		return arrays


static func _voxel(snap: Array, x: int, y: int, z: int) -> int:
	var arr: PackedInt32Array = snap[((x >> 4) + 1) + ((z >> 4) + 1) * 3 + ((y >> 4) + 1) * 9]
	if arr.is_empty():
		return Blocks.AIR
	return arr[(x & 15) + ((z & 15) << 4) + ((y & 15) << 8)]


## Returns [opaque_arrays, water_arrays]; an entry is null when that surface is empty.
static func build(snap: Array, origin: Vector3i, preset: MapPreset) -> Array:
	var center: PackedInt32Array = snap[13]
	var solid := Buffers.new()
	var water := Buffers.new()
	for y in 16:
		for z in 16:
			for x in 16:
				var raw := center[x + (z << 4) + (y << 8)]
				var id := raw & Blocks.MAT_MASK
				if id == Blocks.AIR:
					continue
				var shape := Blocks.shape(raw)
				if shape != Blocks.SHAPE_CUBE:
					_emit_shape(solid, snap, x, y, z, id, shape, Blocks.is_dug(raw), origin, preset)
					continue
				var is_water := id == Blocks.WATER
				for f in 6:
					var n := FACE_NORMALS[f]
					var nraw := _voxel(snap, x + n.x, y + n.y, z + n.z)
					if is_water:
						if nraw != Blocks.AIR:
							continue
					elif Blocks.is_opaque(nraw):
						continue
					_emit_face(water if is_water else solid, snap, x, y, z, f, id, origin, is_water, preset)
	var out := [null, null]
	if not solid.indices.is_empty():
		out[0] = solid.to_arrays()
	if not water.indices.is_empty():
		out[1] = water.to_arrays()
	return out


## Any non-cube ground piece: slopes, corners and half-dug blocks. The top surface is described by the heights of its
## four corners (quarter-blocks); the sides are trapezoids between neighbouring corners. A half-dug block also has a
## centre vertex at DUG_HEIGHT, so its top is a shallow bowl: the corners next to whole blocks rise to meet them.
static func _emit_shape(buf: Buffers, snap: Array, x: int, y: int, z: int, id: int, shape: int, dug: bool, origin: Vector3i, preset: MapPreset) -> void:
	var h := Blocks.corner_heights(shape)   # quarter-blocks
	var q := 1.0 / Blocks.UNIT
	var base := Vector3(x, y, z)
	var cx := [0.0, 1.0, 1.0, 0.0]
	var cz := [0.0, 0.0, 1.0, 1.0]
	var top: Array[Vector3] = []
	var floor_pts: Array[Vector3] = []
	for k in 4:
		top.append(base + Vector3(cx[k], h[k] * q, cz[k]))
		floor_pts.append(base + Vector3(cx[k], 0.0, cz[k]))
	# Split the top along the diagonal that makes a ridge (one corner highest) or a valley (one corner lowest).
	var diag := 0   # 0: split 0-2, 1: split 1-3
	var s02: int = h[0] + h[2]
	var s13: int = h[1] + h[3]
	if s02 != s13:
		var hi: int = maxi(maxi(h[0], h[1]), maxi(h[2], h[3]))
		var lo: int = mini(mini(h[0], h[1]), mini(h[2], h[3]))
		var hi_idx: Array[int] = []
		var lo_idx: Array[int] = []
		for k in 4:
			if h[k] == hi:
				hi_idx.append(k)
			if h[k] == lo:
				lo_idx.append(k)
		if hi_idx.size() == 1:
			diag = 0 if hi_idx[0] % 2 == 0 else 1
		elif lo_idx.size() == 1:
			diag = 0 if lo_idx[0] % 2 == 0 else 1
		else:
			diag = 0 if s02 > s13 else 1
	if dug:
		var centre := base + Vector3(0.5, Blocks.DUG_HEIGHT * q, 0.5)
		for k in 4:
			_shape_tri(buf, [centre, top[k], top[(k + 1) % 4]], Vector3.UP, id, Blocks.FACE_TOP, origin, preset)
	elif diag == 0:
		_shape_tri(buf, [top[0], top[1], top[2]], Vector3.UP, id, Blocks.FACE_TOP, origin, preset)
		_shape_tri(buf, [top[0], top[2], top[3]], Vector3.UP, id, Blocks.FACE_TOP, origin, preset)
	else:
		_shape_tri(buf, [top[0], top[1], top[3]], Vector3.UP, id, Blocks.FACE_TOP, origin, preset)
		_shape_tri(buf, [top[1], top[2], top[3]], Vector3.UP, id, Blocks.FACE_TOP, origin, preset)
	if not Blocks.is_opaque(_voxel(snap, x, y - 1, z)):
		_shape_tri(buf, [floor_pts[0], floor_pts[1], floor_pts[2]], Vector3.DOWN, id, Blocks.FACE_BOTTOM, origin, preset)
		_shape_tri(buf, [floor_pts[0], floor_pts[2], floor_pts[3]], Vector3.DOWN, id, Blocks.FACE_BOTTOM, origin, preset)
	# Four side walls: each runs between two neighbouring corners; a wall whose corners are both 0 has no area.
	var walls := [[0, 1, Vector3i(0, 0, -1)], [1, 2, Vector3i(1, 0, 0)], [2, 3, Vector3i(0, 0, 1)], [3, 0, Vector3i(-1, 0, 0)]]
	for w in walls:
		var a: int = w[0]
		var b: int = w[1]
		var out: Vector3i = w[2]
		if h[a] == 0 and h[b] == 0:
			continue
		if Blocks.is_opaque(_voxel(snap, x + out.x, y, z + out.z)):
			continue
		var n := Vector3(out)
		if h[a] > 0 and h[b] > 0:
			_shape_tri(buf, [floor_pts[a], floor_pts[b], top[b]], n, id, Blocks.FACE_SIDE, origin, preset)
			_shape_tri(buf, [floor_pts[a], top[b], top[a]], n, id, Blocks.FACE_SIDE, origin, preset)
		elif h[a] > 0:
			_shape_tri(buf, [floor_pts[a], floor_pts[b], top[a]], n, id, Blocks.FACE_SIDE, origin, preset)
		else:
			_shape_tri(buf, [floor_pts[a], floor_pts[b], top[b]], n, id, Blocks.FACE_SIDE, origin, preset)


## One triangle of a ground piece, wound clockwise (Godot front face) as seen from the side `outward` points to.
static func _shape_tri(buf: Buffers, pts: Array, outward: Vector3, id: int, face_kind: int, origin: Vector3i, preset: MapPreset) -> void:
	var a: Vector3 = pts[0]
	var b: Vector3 = pts[1]
	var c: Vector3 = pts[2]
	var nrm := (b - a).cross(c - a)
	if nrm.length_squared() < 0.000001:
		return
	nrm = nrm.normalized()
	if nrm.dot(outward) < 0.0:
		nrm = -nrm
		var t := b
		b = c
		c = t   # now counter-clockwise from outside
	var start := buf.verts.size()
	for p in [a, b, c]:
		var col: Color
		if face_kind == Blocks.FACE_TOP:
			col = preset.vertex_color(id, Blocks.FACE_TOP, origin.x + p.x, origin.z + p.z)
		elif face_kind == Blocks.FACE_SIDE:
			col = Blocks.color_of(id, Blocks.FACE_SIDE) * 0.78
		else:
			col = Blocks.color_of(id, Blocks.FACE_BOTTOM) * 0.55
		col.a = 1.0
		buf.verts.append(p)
		buf.normals.append(nrm)
		buf.colors.append(col)
	buf.indices.append_array([start, start + 2, start + 1])


static func _emit_face(buf: Buffers, snap: Array, x: int, y: int, z: int, f: int, id: int, origin: Vector3i, is_water: bool, preset: MapPreset, height := 1.0) -> void:
	var n := FACE_NORMALS[f]
	var u := FACE_U[f]
	var v := FACE_V[f]
	var base := Vector3(x + maxi(n.x, 0), y + maxi(n.y, 0), z + maxi(n.z, 0))
	var face_kind := Blocks.FACE_SIDE
	if f == 2:
		face_kind = Blocks.FACE_TOP
	elif f == 3:
		face_kind = Blocks.FACE_BOTTOM
	# Cheap per-voxel variation so flat areas do not look like one slab; surface colour itself is per vertex.
	var hash := ((origin.x + x) * 73856093) ^ ((origin.y + y) * 19349663) ^ ((origin.z + z) * 83492791)
	var jitter := 0.99 + float(hash & 255) / 255.0 * 0.02
	if face_kind == Blocks.FACE_SIDE and id != Blocks.GRASS and id != Blocks.DIRT:
		jitter = 0.88 + float(hash & 255) / 255.0 * 0.24   # rough cobble look on cliff walls
	var shade_f: float = FACE_SHADE[f] * jitter

	var start := buf.verts.size()
	var ao := [3, 3, 3, 3]
	var corners := [base, base + Vector3(u), base + Vector3(u) + Vector3(v), base + Vector3(v)]
	for k in 4:
		if not is_water:
			var s := CORNER_SIGNS[k]
			var px := x + n.x
			var py := y + n.y
			var pz := z + n.z
			var s1 := 1 if Blocks.is_opaque(_voxel(snap, px + u.x * s.x, py + u.y * s.x, pz + u.z * s.x)) else 0
			var s2 := 1 if Blocks.is_opaque(_voxel(snap, px + v.x * s.y, py + v.y * s.y, pz + v.z * s.y)) else 0
			var c := 1 if Blocks.is_opaque(_voxel(snap, px + u.x * s.x + v.x * s.y, py + u.y * s.x + v.y * s.y, pz + u.z * s.x + v.z * s.y)) else 0
			ao[k] = 0 if (s1 == 1 and s2 == 1) else 3 - (s1 + s2 + c)
		var shade: float = AO_LEVELS[ao[k]]
		var pos: Vector3 = corners[k]
		pos.y = y + (pos.y - y) * height
		buf.verts.append(pos)
		buf.normals.append(Vector3(n))
		var vc := preset.vertex_color(id, face_kind, origin.x + corners[k].x, origin.z + corners[k].z)
		var mul := shade * shade_f
		buf.colors.append(Color(vc.r * mul, vc.g * mul, vc.b * mul, vc.a))

	# Godot front faces are clockwise; flip the diagonal to avoid AO anisotropy artefacts.
	if ao[0] + ao[2] > ao[1] + ao[3]:
		buf.indices.append_array([start, start + 2, start + 1, start, start + 3, start + 2])
	else:
		buf.indices.append_array([start, start + 3, start + 1, start + 1, start + 3, start + 2])
