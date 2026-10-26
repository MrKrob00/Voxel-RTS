extends SceneTree
## Headless: godot --headless --path . -s res://tests/mesher_test.gd
## ChunkMesher merges neighbouring plain faces into rectangles: a flat chunk is a handful of quads, and however much is merged the
## faces still cover exactly the area of the exposed block faces.

const FAIL_LINE := "FAIL "


func _init() -> void:
	var failed := 0
	var preset := MapPreset.plains()

	# A whole chunk of stone up to y = 7: one quad per side of the slab.
	var flat := _chunk(func(_x: int, y: int, _z: int) -> int: return Blocks.STONE if y < 8 else Blocks.AIR)
	var out := ChunkMesher.build(_snap(flat), Vector3i.ZERO, preset)
	failed += _check(out[0] != null and (out[0][Mesh.ARRAY_INDEX] as PackedInt32Array).size() == 6 * 6, "a flat slab is six quads (%d indices)" % (out[0][Mesh.ARRAY_INDEX] as PackedInt32Array).size())
	failed += _check(out[0] != null and (out[0][Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() == (out[0][Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), "every vertex has its UV")

	# Rough ground: grass on dirt on stone, steps of height, a few pillars. Area of the mesh = number of exposed faces.
	var rough := _chunk(func(x: int, y: int, z: int) -> int:
		var h := 5 + ((x / 4) + (z / 3)) % 3 + (2 if (x * 7 + z * 13) % 11 == 0 else 0)
		if y > h:
			return Blocks.AIR
		return Blocks.GRASS if y == h else (Blocks.DIRT if y >= h - 1 else Blocks.STONE))
	out = ChunkMesher.build(_snap(rough), Vector3i.ZERO, preset)
	var area := _area(out[0])
	var faces := _exposed_faces(rough)
	failed += _check(absf(area - faces) < 0.01, "merged faces cover the exposed block faces (%.1f of %d)" % [area, faces])
	var tris := (out[0][Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	failed += _check(tris < faces * 2 * 6 / 10, "far fewer triangles than two per face (%d for %d faces)" % [tris, faces])

	print("MESHER DONE: %d failed" % failed)
	quit(1 if failed > 0 else 0)


func _check(cond: bool, what: String) -> int:
	print(("ok   " if cond else FAIL_LINE) + what)
	return 0 if cond else 1


func _chunk(fn: Callable) -> PackedInt32Array:
	var data := PackedInt32Array()
	data.resize(16 * 16 * 16)
	for y in 16:
		for z in 16:
			for x in 16:
				data[x + (z << 4) + (y << 8)] = fn.call(x, y, z)
	return data


func _snap(center: PackedInt32Array) -> Array:
	var snap := []
	snap.resize(27)
	for i in 27:
		snap[i] = PackedInt32Array()
	snap[13] = center
	return snap


func _area(arrays: Array) -> float:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var a := 0.0
	for t in idx.size() / 3:
		a += (v[idx[t * 3 + 1]] - v[idx[t * 3]]).cross(v[idx[t * 3 + 2]] - v[idx[t * 3]]).length() * 0.5
	return a


func _exposed_faces(data: PackedInt32Array) -> int:
	var n := 0
	for y in 16:
		for z in 16:
			for x in 16:
				if data[x + (z << 4) + (y << 8)] == Blocks.AIR:
					continue
				for d in ChunkMesher.FACE_NORMALS:
					var nx := x + d.x
					var ny := y + d.y
					var nz := z + d.z
					if nx < 0 or nx > 15 or ny < 0 or ny > 15 or nz < 0 or nz > 15 or data[nx + (nz << 4) + (ny << 8)] == Blocks.AIR:
						n += 1
	return n
