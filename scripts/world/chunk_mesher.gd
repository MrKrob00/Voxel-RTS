class_name ChunkMesher
extends RefCounted
## Builds mesh arrays for one chunk from a 3x3x3 snapshot of chunk data (centre chunk at index 13).
## Culls hidden faces and merges neighbouring plain ones into rectangles (greedy meshing). The ambient occlusion of the plain faces is
## handed to the shader in a texture; that of the other pieces is baked into the vertex colours. Runs on worker threads.

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
## Width of the flat floor in the middle of a half-dug block, as a share of the block.
const DUG_PLATFORM := 0.5
## The light in the corners of the faces goes to the shader as a 3D texture of the chunk (see ao_data): 32 x 16 x 16 texels of 4 bytes.
const AO_TEX_SIZE := Vector3i(32, 16, 16)
## How much each block of a merged cliff face differs from its neighbours (the old per-block jitter, now done by the shader).
const COBBLE_JITTER := 0.12
const FLAT_JITTER := 0.01
const CORNER_SIGNS: Array[Vector2i] = [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1)]


class Buffers extends RefCounted:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var uvs := PackedVector2Array()   ## what the ground shader finishes (see toon_world.gdshader); (0, 0) on everything not merged
	var cover := PackedByteArray()   ## ground cover slice of this chunk (GroundCover.slice)

	## How much of the grass is gone at a chunk-local position, 0..1.
	func bare(x: float, z: float) -> float:
		return GroundCover.sample_slice(cover, Blocks.CHUNK_SIZE, x, z)

	func to_arrays() -> Array:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		uvs.resize(verts.size())
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = indices
		return arrays


static func _voxel(snap: Array, x: int, y: int, z: int) -> int:
	var arr: PackedInt32Array = snap[((x >> 4) + 1) + ((z >> 4) + 1) * 3 + ((y >> 4) + 1) * 9]
	if arr.is_empty():
		return Blocks.AIR
	return arr[(x & 15) + ((z & 15) << 4) + ((y & 15) << 8)]


## Returns [opaque_arrays, water_arrays, ao_data, cover]; an array is null when that surface is empty. `ao_data` (empty when no face uses it) is
## the light in the corners of the plain faces, per block: texel (2 x + face / 4, z, y), channel face % 4, the four corners in 2 bits each;
## `cover` is the ground cover slice the grass tops are worn by (the shader does that).
static func build(snap: Array, origin: Vector3i, preset: MapPreset, cover := PackedByteArray()) -> Array:
	var center: PackedInt32Array = snap[13]
	var solid := Buffers.new()
	solid.cover = cover
	var water := Buffers.new()
	# The plain faces wait here (per direction: block index -> what the face is) and are merged into rectangles after the scan.
	var ao_data := PackedByteArray()
	ao_data.resize(AO_TEX_SIZE.x * AO_TEX_SIZE.y * AO_TEX_SIZE.z * 4)
	var ao_used := false
	var masks: Array[PackedInt32Array] = []
	for f in 6:
		masks.append(PackedInt32Array())
		masks[f].resize(Blocks.CHUNK_SIZE * Blocks.CHUNK_SIZE * Blocks.CHUNK_SIZE)
	for y in 16:
		for z in 16:
			for x in 16:
				var raw := center[x + (z << 4) + (y << 8)]
				var id := raw & Blocks.MAT_MASK
				if id == Blocks.AIR:
					continue
				var shape := Blocks.shape(raw)
				if shape != Blocks.SHAPE_CUBE:
					if Blocks.is_stairs(raw) and Blocks.wedge_direction(shape) != Vector2i.ZERO:
						_emit_stairs(solid, snap, x, y, z, id, Blocks.wedge_direction(shape), origin, preset)
					else:
						_emit_shape(solid, snap, x, y, z, id, shape, Blocks.is_dug(raw), origin, preset)
					continue
				var is_water := id == Blocks.WATER
				for f in 6:
					var n := FACE_NORMALS[f]
					var nx := x + n.x
					var ny := y + n.y
					var nz := z + n.z
					# Inside this chunk the neighbour is read straight from it; only the edge looks into the other chunks.
					var nraw: int
					if nx >= 0 and nx < 16 and ny >= 0 and ny < 16 and nz >= 0 and nz < 16:
						nraw = center[nx + (nz << 4) + (ny << 8)]
					else:
						nraw = _voxel(snap, nx, ny, nz)
					if is_water:
						if nraw != Blocks.AIR:
							continue
						_emit_face(water, snap, x, y, z, f, id, origin, true, preset)
						continue
					var nm := nraw & Blocks.MAT_MASK   # is_opaque, by hand: this line runs for every face of every block
					if nm != Blocks.AIR and nm != Blocks.WATER and (nraw >> Blocks.SHAPE_SHIFT) & Blocks.SHAPE_MASK == Blocks.SHAPE_CUBE:
						continue
					var ao := _corner_ao(snap, x, y, z, f)
					masks[f][x + (z << 4) + (y << 8)] = id
					ao_data[((y * 16 + z) * 32 + x * 2 + (f >> 2)) * 4 + (f & 3)] = ao[0] | (ao[1] << 2) | (ao[2] << 4) | (ao[3] << 6)
					ao_used = true
	for f in 6:
		_merge_faces(solid, masks[f], f, origin, preset)
	var out := [null, null, ao_data if ao_used else PackedByteArray(), cover]
	if not solid.indices.is_empty():
		out[0] = solid.to_arrays()
	if not water.indices.is_empty():
		out[1] = water.to_arrays()
	return out


## Any non-cube ground piece: slopes, corners and half-dug blocks. The top surface is described by the heights of its
## four corners (quarter-blocks); the sides are trapezoids between neighbouring corners. A half-dug block is a shallow bowl
## (see _emit_dug): the corners next to whole blocks rise to meet them, and its sides run into neighbouring dug blocks.
static func _emit_shape(buf: Buffers, snap: Array, x: int, y: int, z: int, id: int, shape: int, dug: bool, origin: Vector3i, preset: MapPreset) -> void:
	if dug:
		_emit_dug(buf, snap, x, y, z, id, shape, origin, preset)
		return
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
	var diag := Blocks.top_diagonal(h)   # 0: split 0-2, 1: split 1-3
	if diag == 0:
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


## A stair piece: STAIR_STEPS steps rising towards `dir`, each a box a step deep and one step higher than the one before. The top
## and the risers are drawn; the sides unless a whole block hides them; the back of the last step against the higher ground.
static func _emit_stairs(buf: Buffers, snap: Array, x: int, y: int, z: int, id: int, dir: Vector2i, origin: Vector3i, preset: MapPreset) -> void:
	var n := Blocks.STAIR_STEPS
	var base := Vector3(x, y, z)
	var along := Vector3(dir.x, 0.0, dir.y)             # the way up
	var across := Vector3(-dir.y, 0.0, dir.x)            # the width of a step
	var corner := base + Vector3(0.5, 0.0, 0.5) - along * 0.5 - across * 0.5   # the low end, at the start of the width
	var up := Vector3(0.0, 1.0, 0.0)
	for k in n:
		var t0 := float(k) / n
		var t1 := float(k + 1) / n
		var h0 := float(k) / n
		var h1 := float(k + 1) / n
		var p00 := corner + along * t0 + up * h1
		var p01 := corner + along * t0 + across + up * h1
		var p10 := corner + along * t1 + up * h1
		var p11 := corner + along * t1 + across + up * h1
		_shape_tri(buf, [p00, p01, p11], Vector3.UP, id, Blocks.FACE_TOP, origin, preset)
		_shape_tri(buf, [p00, p11, p10], Vector3.UP, id, Blocks.FACE_TOP, origin, preset)
		# The riser: the face of this step towards the low end.
		var r0 := corner + along * t0 + up * h0
		var r1 := corner + along * t0 + across + up * h0
		_shape_tri(buf, [r0, r1, p01], -along, id, Blocks.FACE_SIDE, origin, preset)
		_shape_tri(buf, [r0, p01, p00], -along, id, Blocks.FACE_SIDE, origin, preset)
		# The two sides of the step.
		for side in 2:
			var s_off := across * float(side)
			var outward := -across if side == 0 else across
			var out_cell := Vector3i(int(roundf(outward.x)), 0, int(roundf(outward.z)))
			if Blocks.is_opaque(_voxel(snap, x + out_cell.x, y, z + out_cell.z)):
				continue
			var a0 := corner + along * t0 + s_off
			var a1 := corner + along * t1 + s_off
			_shape_tri(buf, [a0, a1, a1 + up * h1], outward, id, Blocks.FACE_SIDE, origin, preset)
			_shape_tri(buf, [a0, a1 + up * h1, a0 + up * h1], outward, id, Blocks.FACE_SIDE, origin, preset)
	# The back of the last step, against the higher ground.
	if not Blocks.is_opaque(_voxel(snap, x + dir.x, y, z + dir.y)):
		var b0 := corner + along
		var b1 := corner + along + across
		_shape_tri(buf, [b0, b1, b1 + up], along, id, Blocks.FACE_SIDE, origin, preset)
		_shape_tri(buf, [b0, b1 + up, b0 + up], along, id, Blocks.FACE_SIDE, origin, preset)
	if not Blocks.is_opaque(_voxel(snap, x, y - 1, z)):
		_shape_tri(buf, [base, base + Vector3(1, 0, 0), base + Vector3(1, 0, 1)], Vector3.DOWN, id, Blocks.FACE_BOTTOM, origin, preset)
		_shape_tri(buf, [base, base + Vector3(1, 0, 1), base + Vector3(0, 0, 1)], Vector3.DOWN, id, Blocks.FACE_BOTTOM, origin, preset)


## A half-dug block. The top is a small flat floor at DUG_HEIGHT in the middle (DUG_PLATFORM wide) with a ring of slopes from
## it out to the edge of the block. The ring has the four corners (raised to a full block where a whole neighbour touches
## them, else DUG_HEIGHT) and, per side, either one midpoint on the straight line between the corners, or, where the side
## borders another half-dug block, two points at DUG_HEIGHT a quarter in from each corner: the edge dips in a flat-bottomed
## groove, and two neighbouring pits become one trough with no fin or divider between their floors. Turf stays only where the
## ground rises to a whole block; the rest shows the earth.
static func _emit_dug(buf: Buffers, snap: Array, x: int, y: int, z: int, id: int, shape: int, origin: Vector3i, preset: MapPreset) -> void:
	var h := Blocks.corner_heights(shape)
	var dips := Blocks.dug_dip_mask(shape)
	var q := 1.0 / Blocks.UNIT
	var base := Vector3(x, y, z)
	var cx := [0.0, 1.0, 1.0, 0.0]
	var cz := [0.0, 0.0, 1.0, 1.0]
	var edge_bit := [3, 0, 2, 1]   # the dip bit (+x, -x, +z, -z) of the side between corner k and k + 1
	var earth_id := Blocks.dug_bottom_material(id)
	var floor_pts: Array[Vector3] = []
	var top: Array[Vector3] = []
	var turf_corner: Array[float] = []
	for k in 4:
		floor_pts.append(base + Vector3(cx[k], 0.0, cz[k]))
		top.append(base + Vector3(cx[k], h[k] * q, cz[k]))
		turf_corner.append(1.0 if h[k] >= Blocks.UNIT else 0.0)
	var floor_top := Blocks.DUG_HEIGHT * q
	# The flat floor in the middle.
	var inner: Array[Vector3] = []
	var inner_col: Array[Color] = []
	for k in 4:
		var ip := base + Vector3(0.5 + (cx[k] - 0.5) * DUG_PLATFORM, floor_top, 0.5 + (cz[k] - 0.5) * DUG_PLATFORM)
		inner.append(ip)
		inner_col.append(preset.vertex_color(earth_id, Blocks.FACE_TOP, origin.x + ip.x, origin.z + ip.z))
	_shape_tri(buf, [inner[0], inner[1], inner[2]], Vector3.UP, earth_id, Blocks.FACE_TOP, origin, preset, [inner_col[0], inner_col[1], inner_col[2]])
	_shape_tri(buf, [inner[0], inner[2], inner[3]], Vector3.UP, earth_id, Blocks.FACE_TOP, origin, preset, [inner_col[0], inner_col[2], inner_col[3]])
	var outs := [Vector3i(0, 0, -1), Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(-1, 0, 0)]
	for k in 4:
		var n := (k + 1) % 4
		var sunk: bool = ((dips >> int(edge_bit[k])) & 1) == 1
		var col_k := _dug_top_color(buf, preset, id, earth_id, turf_corner[k], origin, top[k])
		var col_n := _dug_top_color(buf, preset, id, earth_id, turf_corner[n], origin, top[n])
		if sunk:
			# Groove along a shared edge: corner, a point a quarter in, a point three quarters in, corner.
			var e1 := base + Vector3(lerpf(cx[k], cx[n], 0.25), floor_top, lerpf(cz[k], cz[n], 0.25))
			var e2 := base + Vector3(lerpf(cx[k], cx[n], 0.75), floor_top, lerpf(cz[k], cz[n], 0.75))
			var c1 := _dug_top_color(buf, preset, id, earth_id, 0.0, origin, e1)
			var c2 := _dug_top_color(buf, preset, id, earth_id, 0.0, origin, e2)
			_shape_tri(buf, [top[k], e1, inner[k]], Vector3.UP, earth_id, Blocks.FACE_TOP, origin, preset, [col_k, c1, inner_col[k]])
			_shape_tri(buf, [e1, e2, inner[n]], Vector3.UP, earth_id, Blocks.FACE_TOP, origin, preset, [c1, c2, inner_col[n]])
			_shape_tri(buf, [e1, inner[n], inner[k]], Vector3.UP, earth_id, Blocks.FACE_TOP, origin, preset, [c1, inner_col[n], inner_col[k]])
			_shape_tri(buf, [e2, top[n], inner[n]], Vector3.UP, earth_id, Blocks.FACE_TOP, origin, preset, [c2, col_n, inner_col[n]])
			continue   # no wall: the neighbouring pit is open here and its floor is at the same height
		var mid := base + Vector3((cx[k] + cx[n]) * 0.5, (h[k] + h[n]) * 0.5 * q, (cz[k] + cz[n]) * 0.5)
		var col_m := _dug_top_color(buf, preset, id, earth_id, (turf_corner[k] + turf_corner[n]) * 0.5, origin, mid)
		# The band between this side of the block and the matching side of the floor (corner, midpoint, corner).
		_shape_tri(buf, [top[k], mid, inner[k]], Vector3.UP, earth_id, Blocks.FACE_TOP, origin, preset, [col_k, col_m, inner_col[k]])
		_shape_tri(buf, [mid, inner[n], inner[k]], Vector3.UP, earth_id, Blocks.FACE_TOP, origin, preset, [col_m, inner_col[n], inner_col[k]])
		_shape_tri(buf, [mid, top[n], inner[n]], Vector3.UP, earth_id, Blocks.FACE_TOP, origin, preset, [col_m, col_n, inner_col[n]])
		var out: Vector3i = outs[k]
		if not Blocks.is_opaque(_voxel(snap, x + out.x, y, z + out.z)):
			var mid_floor := (floor_pts[k] + floor_pts[n]) * 0.5
			var nrm := Vector3(out)
			_shape_tri(buf, [floor_pts[k], mid_floor, mid], nrm, earth_id, Blocks.FACE_SIDE, origin, preset)
			_shape_tri(buf, [floor_pts[k], mid, top[k]], nrm, earth_id, Blocks.FACE_SIDE, origin, preset)
			_shape_tri(buf, [mid_floor, floor_pts[n], top[n]], nrm, earth_id, Blocks.FACE_SIDE, origin, preset)
			_shape_tri(buf, [mid_floor, top[n], mid], nrm, earth_id, Blocks.FACE_SIDE, origin, preset)
	if not Blocks.is_opaque(_voxel(snap, x, y - 1, z)):
		_shape_tri(buf, [floor_pts[0], floor_pts[1], floor_pts[2]], Vector3.DOWN, earth_id, Blocks.FACE_BOTTOM, origin, preset)
		_shape_tri(buf, [floor_pts[0], floor_pts[2], floor_pts[3]], Vector3.DOWN, earth_id, Blocks.FACE_BOTTOM, origin, preset)



static func _dug_top_color(buf: Buffers, preset: MapPreset, id: int, earth_id: int, turf: float, origin: Vector3i, p: Vector3) -> Color:
	var earth := preset.vertex_color(earth_id, Blocks.FACE_TOP, origin.x + p.x, origin.z + p.z)
	if turf <= 0.0:
		return earth
	return earth.lerp(preset.vertex_color(id, Blocks.FACE_TOP, origin.x + p.x, origin.z + p.z, buf.bare(p.x, p.z)), turf)


## One triangle of a ground piece, wound clockwise (Godot front face) as seen from the side `outward` points to.
## `top_colors` (one per point) overrides the colour of a top face.
static func _shape_tri(buf: Buffers, pts: Array, outward: Vector3, id: int, face_kind: int, origin: Vector3i, preset: MapPreset, top_colors: Array = []) -> void:
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
		if not top_colors.is_empty():
			top_colors = [top_colors[0], top_colors[2], top_colors[1]]
	var start := buf.verts.size()
	var i := -1
	for p in [a, b, c]:
		i += 1
		var col: Color
		if face_kind == Blocks.FACE_TOP and not top_colors.is_empty():
			col = top_colors[i]
		elif face_kind == Blocks.FACE_TOP:
			col = preset.vertex_color(id, Blocks.FACE_TOP, origin.x + p.x, origin.z + p.z, buf.bare(p.x, p.z))
		elif face_kind == Blocks.FACE_SIDE:
			col = Blocks.color_of(id, Blocks.FACE_SIDE) * 0.78
		else:
			col = Blocks.color_of(id, Blocks.FACE_BOTTOM) * 0.55
		col.a = 1.0
		buf.verts.append(p)
		buf.normals.append(nrm)
		buf.colors.append(col)
	buf.indices.append_array([start, start + 2, start + 1])


## The lighting of the four corners of a face (0 darkest .. 3 open), in the order of the face's corners.
static func _corner_ao(snap: Array, x: int, y: int, z: int, f: int) -> Array:
	var n := FACE_NORMALS[f]
	var u := FACE_U[f]
	var v := FACE_V[f]
	var ao := [3, 3, 3, 3]
	var px := x + n.x
	var py := y + n.y
	var pz := z + n.z
	for k in 4:
		var s := CORNER_SIGNS[k]
		var s1 := 1 if Blocks.is_opaque(_voxel(snap, px + u.x * s.x, py + u.y * s.x, pz + u.z * s.x)) else 0
		var s2 := 1 if Blocks.is_opaque(_voxel(snap, px + v.x * s.y, py + v.y * s.y, pz + v.z * s.y)) else 0
		var c := 1 if Blocks.is_opaque(_voxel(snap, px + u.x * s.x + v.x * s.y, py + u.y * s.x + v.y * s.y, pz + u.z * s.x + v.z * s.y)) else 0
		ao[k] = 0 if (s1 == 1 and s2 == 1) else 3 - (s1 + s2 + c)
	return ao


## Greedy meshing of one direction: neighbouring faces of the same block, lit the same, become one rectangle. `mask` holds, per block,
## 0 (no face) or the material.
static func _merge_faces(buf: Buffers, mask: PackedInt32Array, f: int, origin: Vector3i, preset: MapPreset) -> void:
	var n := FACE_NORMALS[f]
	var u := FACE_U[f]
	var v := FACE_V[f]
	var s_n := absi(n.x) + absi(n.z) * 16 + absi(n.y) * 256   # index step along the normal / the two tangents
	var s_u := u.x + u.z * 16 + u.y * 256
	var s_v := v.x + v.z * 16 + v.y * 256
	var face_kind := Blocks.FACE_SIDE
	if f == 2:
		face_kind = Blocks.FACE_TOP
	elif f == 3:
		face_kind = Blocks.FACE_BOTTOM
	for layer in 16:
		for j in 16:
			var i := 0
			while i < 16:
				var at := layer * s_n + i * s_u + j * s_v
				var key := mask[at]
				if key == 0:
					i += 1
					continue
				var w := 1
				while i + w < 16 and mask[at + w * s_u] == key:
					w += 1
				var h := 1
				var grow := true
				while j + h < 16 and grow:
					for k in w:
						if mask[at + k * s_u + h * s_v] != key:
							grow = false
							break
					if grow:
						h += 1
				for dj in h:
					for di in w:
						mask[at + di * s_u + dj * s_v] = 0
				_emit_rect(buf, at, w, h, key, f, face_kind, origin, preset)
				i += w


static func _emit_rect(buf: Buffers, at: int, w: int, h: int, key: int, f: int, face_kind: int, origin: Vector3i, preset: MapPreset) -> void:
	var id := key & Blocks.MAT_MASK
	var n := FACE_NORMALS[f]
	var u := Vector3(FACE_U[f])
	var v := Vector3(FACE_V[f])
	var base := Vector3(at & 15, at >> 8, (at >> 4) & 15) + Vector3(maxi(n.x, 0), maxi(n.y, 0), maxi(n.z, 0))
	var mul: float = FACE_SHADE[f]
	var grass_top := id == preset.top_block and face_kind == Blocks.FACE_TOP
	var colour := Color(1.0, 1.0, 1.0, 1.0) if grass_top else Blocks.color_of(id, face_kind)
	var jitter := FLAT_JITTER
	if face_kind == Blocks.FACE_SIDE and id != Blocks.GRASS and id != Blocks.DIRT:
		jitter = COBBLE_JITTER
	var start := buf.verts.size()
	var corners := [base, base + u * w, base + u * w + v * h, base + v * h]
	buf.uvs.resize(start)
	for k in 4:
		buf.verts.append(corners[k])
		buf.normals.append(Vector3(n))
		buf.colors.append(Color(colour.r * mul, colour.g * mul, colour.b * mul, colour.a))
		buf.uvs.append(Vector2(3.0 if grass_top else 2.0, jitter))   # x: 1 grass top | 2 light from the texture
	buf.indices.append_array([start, start + 3, start + 1, start + 1, start + 3, start + 2])   # the diagonal of an evenly lit face


static func _emit_face(buf: Buffers, snap: Array, x: int, y: int, z: int, f: int, id: int, origin: Vector3i, is_water: bool, preset: MapPreset, height := 1.0, ao_in: Array = []) -> void:
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
	if not is_water:
		ao = ao_in if not ao_in.is_empty() else _corner_ao(snap, x, y, z, f)
	var corners := [base, base + Vector3(u), base + Vector3(u) + Vector3(v), base + Vector3(v)]
	for k in 4:
		var shade: float = AO_LEVELS[ao[k]]
		var pos: Vector3 = corners[k]
		pos.y = y + (pos.y - y) * height
		buf.verts.append(pos)
		buf.normals.append(Vector3(n))
		var vc := preset.vertex_color(id, face_kind, origin.x + corners[k].x, origin.z + corners[k].z, buf.bare(corners[k].x, corners[k].z) if face_kind == Blocks.FACE_TOP else 0.0)
		var mul := shade * shade_f
		buf.colors.append(Color(vc.r * mul, vc.g * mul, vc.b * mul, vc.a))

	# Godot front faces are clockwise; flip the diagonal to avoid AO anisotropy artefacts.
	if ao[0] + ao[2] > ao[1] + ao[3]:
		buf.indices.append_array([start, start + 2, start + 1, start, start + 3, start + 2])
	else:
		buf.indices.append_array([start, start + 3, start + 1, start + 1, start + 3, start + 2])
