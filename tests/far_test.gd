extends SceneTree
## Headless: godot --headless --path . -s res://tests/far_test.gd
## FarTerrain: the quadtree covers every chunk column once, and a node of ground is a mesh that faces up with skirts at its ends.

func _init() -> void:
	var failed := 0
	var width := 448
	var depth := 448
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var overlap := 0
	for k in 40:
		var cam := Vector3(rng.randf_range(-50, 500), rng.randf_range(20, 250), rng.randf_range(-50, 500))
		var leaves := FarTerrain.select_leaves(cam, rng.randf_range(0.0, 200.0), width, depth)
		var seen := {}
		for leaf: Array in leaves:
			var chunks: int = 1 << leaf[0]
			for cz in range(leaf[2] * chunks, mini((leaf[2] + 1) * chunks, depth / 16)):
				for cx in range(leaf[1] * chunks, mini((leaf[1] + 1) * chunks, width / 16)):
					if seen.has(Vector2i(cx, cz)):
						overlap += 1
					seen[Vector2i(cx, cz)] = true
	failed += _check(overlap == 0, "no chunk column is under two far nodes (%d)" % overlap)
	# near the camera nothing is far; far from it the nodes are wide
	var low := FarTerrain.select_leaves(Vector3(224, 50, 224), 4.0, width, depth)
	var near_far := 0
	var widest := 0
	for leaf: Array in low:
		widest = maxi(widest, leaf[0])
		var span: int = 16 << leaf[0]
		var cx: float = (leaf[1] + 0.5) * span
		var cz: float = (leaf[2] + 0.5) * span
		if Vector2(cx - 224, cz - 224).length() < 60.0:
			near_far += 1
	failed += _check(near_far == 0, "close to a low camera there is no far node")
	failed += _check(widest >= 2, "far from it the nodes are wide (level %d)" % widest)
	var high := FarTerrain.select_leaves(Vector3(224, 300, 224), 250.0, width, depth)
	failed += _check(high.size() > 0 and high.size() < low.size() + 40, "a camera high above sees the ground as far nodes (%d, against %d from a low one)" % [high.size(), low.size()])

	# with the camera's frustum: what is behind the camera is left out
	var proj := Projection.create_perspective(60.0, 16.0 / 9.0, 0.1, 1400.0)
	var eye := Transform3D(Basis.looking_at(Vector3(0, -10, 176).normalized(), Vector3.UP), Vector3(224, 60, 224))   # looks along +z
	var planes: Array = []
	var probe := eye * Vector3(0, 0, -50)   # a point in front of the camera: inside every plane
	for k in 6:
		var pl: Plane = eye * proj.get_projection_plane(k)
		planes.append(pl if pl.distance_to(probe) < 0.0 else Plane(-pl.normal, -pl.d))   # (the planes face outward, like Camera3D.get_frustum)
	var in_view := FarTerrain.select_leaves(Vector3(224, 60, 224), 10.0, width, depth, planes, 24.0)
	var all_leaves := FarTerrain.select_leaves(Vector3(224, 60, 224), 10.0, width, depth)
	var behind := 0
	for leaf: Array in in_view:
		var span: int = 16 << leaf[0]
		if (leaf[2] + 1) * span < 224 - 24:
			behind += 1
	failed += _check(behind == 0 and in_view.size() < all_leaves.size(), "far nodes behind the camera are left out (%d of %d, none behind)" % [in_view.size(), all_leaves.size()])
	# a node: flat ground
	var levels := PackedInt32Array()
	levels.resize(width * depth)
	levels.fill(4 * 40)
	var mats := PackedByteArray()
	mats.resize(width * depth)
	mats.fill(Blocks.GRASS)
	var preset := MapPreset.plains()
	var arrays = FarTerrain.build_arrays(levels, mats, width, depth, 1, 3, 3, preset, null)
	failed += _check(arrays != null, "a node over ground has a mesh")
	if arrays != null:
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var up := 0
		for nrm in normals:
			if nrm.y > 0.99:
				up += 1
		failed += _check(up == 16 * 16 * 2 * 3, "flat ground is 512 triangles facing up (%d vertices up)" % up)
		failed += _check(verts.size() == 16 * 16 * 2 * 3 + 4 * 16 * 2 * 3, "and 128 triangles of skirt round it (%d vertices)" % verts.size())
		# every triangle is clockwise seen from the way its normal points
		var wrong := 0
		for t in verts.size() / 3:
			var n := (verts[t * 3 + 2] - verts[t * 3]).cross(verts[t * 3 + 1] - verts[t * 3]).normalized()
			if n.dot(normals[t * 3]) < 0.99:
				wrong += 1
		failed += _check(wrong == 0, "every triangle is wound the way its normal says (%d wrong)" % wrong)
	# ground that ends: no triangles over the void
	var half := levels.duplicate()
	for z in depth:
		for x in range(100, width):
			half[x + z * width] = 0
	var cut = FarTerrain.build_arrays(half, mats, width, depth, 1, 3, 3, preset, null)
	var void_nodes = FarTerrain.build_arrays(half, mats, width, depth, 1, 10, 10, preset, null)
	failed += _check(void_nodes == null, "a node over nothing has no mesh")
	failed += _check(cut == null or (cut[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() > 0, "a node at the edge of the ground is made")
	# the occluder lies under the ground everywhere and has nothing where the ground ends
	var occ := GroundOccluder.make_arrays(levels, width, depth)
	var verts_o: PackedVector3Array = occ[0]
	var high_ok := true
	for v in verts_o:
		high_ok = high_ok and v.y <= 40.0 - GroundOccluder.UNDER + 0.001
	failed += _check(high_ok and (occ[1] as PackedInt32Array).size() == (width / GroundOccluder.STEP) * (depth / GroundOccluder.STEP) * 6, "the occluder of flat ground is a flat sheet one block under it")
	var occ_cut := GroundOccluder.make_arrays(half, width, depth)
	var over_void := false
	for t in (occ_cut[1] as PackedInt32Array).size() / 3:
		for k in 3:
			var vv: Vector3 = (occ_cut[0] as PackedVector3Array)[(occ_cut[1] as PackedInt32Array)[t * 3 + k]]
			if vv.x > 104.0:
				over_void = true
	failed += _check(not over_void, "and none where the ground ends")
	print("FAR DONE: %d failed" % failed)
	quit(1 if failed > 0 else 0)


func _check(cond: bool, what: String) -> int:
	print(("ok   " if cond else "FAIL ") + what)
	return 0 if cond else 1
