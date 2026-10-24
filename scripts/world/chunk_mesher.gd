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
	var arr: PackedByteArray = snap[((x >> 4) + 1) + ((z >> 4) + 1) * 3 + ((y >> 4) + 1) * 9]
	if arr.is_empty():
		return Blocks.AIR
	return arr[(x & 15) + ((z & 15) << 4) + ((y & 15) << 8)]


## Returns [opaque_arrays, water_arrays]; an entry is null when that surface is empty.
static func build(snap: Array, origin: Vector3i, preset: MapPreset) -> Array:
	var center: PackedByteArray = snap[13]
	var solid := Buffers.new()
	var water := Buffers.new()
	for y in 16:
		for z in 16:
			for x in 16:
				var id := center[x + (z << 4) + (y << 8)]
				if id == Blocks.AIR:
					continue
				var is_water := id == Blocks.WATER
				for f in 6:
					var n := FACE_NORMALS[f]
					var nid := _voxel(snap, x + n.x, y + n.y, z + n.z)
					if is_water:
						if nid != Blocks.AIR:
							continue
					elif Blocks.is_opaque(nid):
						continue
					_emit_face(water if is_water else solid, snap, x, y, z, f, id, origin, is_water, preset)
	var out := [null, null]
	if not solid.indices.is_empty():
		out[0] = solid.to_arrays()
	if not water.indices.is_empty():
		out[1] = water.to_arrays()
	return out


static func _emit_face(buf: Buffers, snap: Array, x: int, y: int, z: int, f: int, id: int, origin: Vector3i, is_water: bool, preset: MapPreset) -> void:
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
		buf.verts.append(corners[k])
		buf.normals.append(Vector3(n))
		var vc := preset.vertex_color(id, face_kind, origin.x + corners[k].x, origin.z + corners[k].z)
		var mul := shade * shade_f
		buf.colors.append(Color(vc.r * mul, vc.g * mul, vc.b * mul, vc.a))

	# Godot front faces are clockwise; flip the diagonal to avoid AO anisotropy artefacts.
	if ao[0] + ao[2] > ao[1] + ao[3]:
		buf.indices.append_array([start, start + 2, start + 1, start, start + 3, start + 2])
	else:
		buf.indices.append_array([start, start + 3, start + 1, start + 1, start + 3, start + 2])
