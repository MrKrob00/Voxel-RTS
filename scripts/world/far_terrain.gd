class_name FarTerrain
extends Node3D
## The ground far from the camera, as LiteTerrain does it (its LOD "merges chunks instead of decimating"): a quadtree of nodes over the
## map. A node of level L is 16 << L blocks wide and is drawn as a grid of GRID x GRID quads (a column of the ground every 2^L blocks),
## so the farther the ground, the coarser and the wider the pieces and the fewer the triangles. Near the camera the tree is split down to
## the single chunks, and those are the voxel meshes as ever; where the tree stops higher up, the far node stands for the chunks under
## it and they are not drawn.
##
##   - what splits a node is the distance alone: nearer than SPLIT times its width it is drawn as its four halves;
##   - the height of a vertex is the height of the ground in the column there (VoxelWorld.column_levels), its colour the colour of the
##     top block of the column (grass blobs, worn earth), so the far ground looks like the near one; steep quads are coloured as a cliff;
##   - the pieces are not joined to each other: where a piece ends (or the ground ends) a skirt hangs down and hides the crack;
##   - a node is made when it is first needed and kept; a change of a block makes the nodes over it again;
##   - until the node is there the chunks stay drawn, so nothing opens a hole.

const MAX_LOD := 3                ## the top nodes are 128 blocks wide
const GRID := 16                  ## quads along a side of a node
const SPLIT := 3.5
const SKIRT := 20.0               ## blocks a skirt hangs down
const STEEP := 1.1                ## height over run from which a quad is a cliff
const BUILD_BUDGET := 3           ## nodes made in one pass
const POLL := 0.25
const MOVED := 4.0                ## blocks the camera must move for a new selection

var enabled := true
var _world: VoxelWorld
var _camera: Camera3D
var _nodes := {}                  # key -> MeshInstance3D
var _built_leaves := {}           # key -> true: the nodes drawn now
var _far_columns := {}            # Vector2i (chunk column) -> true: chunks hidden because a far node stands for them
var _dirty := {}                  # key -> true: nodes to make again
var _poll := 0.0
var _last_cam := Vector3(INF, INF, INF)
var _incomplete := true


func setup(world: VoxelWorld, camera: Camera3D) -> void:
	_world = world
	_camera = camera
	world.block_changed.connect(_on_block_changed)
	world.chunk_meshed.connect(_on_chunk_meshed)


func node_count() -> int:
	return _nodes.size()


func far_leaf_count() -> int:
	return _built_leaves.size()


func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0.0 or _camera == null or not _world.column_levels_ready:
		return
	_poll = POLL
	if not enabled:
		if not _far_columns.is_empty() or not _built_leaves.is_empty():
			_select([])
		return
	var cam := _camera.global_position
	if cam.distance_to(_last_cam) < MOVED and _dirty.is_empty() and not _incomplete:
		return
	_last_cam = cam
	var size := _world.size_blocks()
	var cx := clampi(int(cam.x), 0, size.x - 1)
	var cz := clampi(int(cam.z), 0, size.z - 1)
	var height_above := maxf(cam.y - float(_world.column_levels[cx + cz * size.x]) / Blocks.UNIT, 0.0)
	_select(select_leaves(cam, height_above, size.x, size.z))


## The nodes of level 1 and up that draw the ground now, as [lod, gx, gz]; every chunk column not under one of them is drawn as chunks.
## Pure function (see the test).
static func select_leaves(cam: Vector3, height_above: float, width: int, depth: int) -> Array:
	var out: Array = []
	var top := GRID << MAX_LOD
	for gz in range(0, ceili(float(depth) / top)):
		for gx in range(0, ceili(float(width) / top)):
			_descend(MAX_LOD, gx, gz, cam, height_above, width, depth, out)
	return out


static func _descend(lod: int, gx: int, gz: int, cam: Vector3, height_above: float, width: int, depth: int, out: Array) -> void:
	var span := float(GRID << lod)
	var x0 := gx * span
	var z0 := gz * span
	if x0 >= width or z0 >= depth:
		return
	var x1 := minf(x0 + span, float(width))
	var z1 := minf(z0 + span, float(depth))
	var dx := maxf(maxf(x0 - cam.x, 0.0), cam.x - x1)
	var dz := maxf(maxf(z0 - cam.z, 0.0), cam.z - z1)
	var d2 := dx * dx + dz * dz + height_above * height_above
	if lod == 0:
		return   # a chunk column: the voxel meshes
	if d2 < (span * SPLIT) * (span * SPLIT):
		for k in 4:
			_descend(lod - 1, gx * 2 + (k & 1), gz * 2 + (k >> 1), cam, height_above, width, depth, out)
		return
	out.append([lod, gx, gz])


static func key_of(lod: int, gx: int, gz: int) -> int:
	return (lod << 40) | ((gx & 0xFFFFF) << 20) | (gz & 0xFFFFF)


## Takes the nodes to draw: makes the missing ones (a few per pass), shows them, hides the chunks they stand for.
func _select(leaves: Array) -> void:
	var size := _world.size_blocks()
	var budget := BUILD_BUDGET
	var ready := {}
	_incomplete = false
	for leaf in leaves:
		var key := key_of(leaf[0], leaf[1], leaf[2])
		if not _nodes.has(key):
			if budget <= 0:
				_incomplete = true
				continue
			budget -= 1
			_make_node(key, leaf[0], leaf[1], leaf[2])
		ready[key] = leaf
	for key: int in _dirty.keys():
		if _nodes.has(key) and budget > 0:
			budget -= 1
			_make_node(key, key >> 40, (key >> 20) & 0xFFFFF, key & 0xFFFFF)
			_dirty.erase(key)
		elif not _nodes.has(key):
			_dirty.erase(key)
		else:
			_incomplete = true
	for key: int in _nodes:
		(_nodes[key] as MeshInstance3D).visible = ready.has(key)
	_built_leaves = ready
	# the chunk columns the drawn nodes stand for
	var columns := {}
	for key: int in ready:
		var leaf: Array = ready[key]
		var chunks: int = 1 << int(leaf[0])
		for cz in range(leaf[2] * chunks, mini((leaf[2] + 1) * chunks, size.z / Blocks.CHUNK_SIZE)):
			for cx in range(leaf[1] * chunks, mini((leaf[1] + 1) * chunks, size.x / Blocks.CHUNK_SIZE)):
				columns[Vector2i(cx, cz)] = true
	for col: Vector2i in _far_columns.keys():
		if not columns.has(col):
			_hide_column(col, false)
	for col: Vector2i in columns:
		if not _far_columns.has(col):
			_hide_column(col, true)
	_far_columns = columns


func _hide_column(col: Vector2i, hidden: bool) -> void:
	for cy in _world.size_chunks.y:
		ChunkHide.set_hidden(_world.chunk_instance(Vector3i(col.x, cy, col.y)), "far", hidden)


func _on_chunk_meshed(cpos: Vector3i) -> void:
	if _far_columns.has(Vector2i(cpos.x, cpos.z)):
		ChunkHide.set_hidden(_world.chunk_instance(cpos), "far", true)


func _on_block_changed(p: Vector3i) -> void:
	for lod in range(1, MAX_LOD + 1):
		var span := GRID << lod
		var key := key_of(lod, p.x / span, p.z / span)
		if _nodes.has(key):
			_dirty[key] = true


func _make_node(key: int, lod: int, gx: int, gz: int) -> void:
	var size := _world.size_blocks()
	var arrays: Variant = build_arrays(_world.column_levels, _world.column_materials, size.x, size.z, lod, gx, gz, _world.preset, _world.cover)
	var node: MeshInstance3D = _nodes.get(key)
	if arrays == null:
		if node != null:
			node.mesh = null
		else:
			node = MeshInstance3D.new()
			node.name = "Far_%d_%d_%d" % [lod, gx, gz]
			add_child(node)
			_nodes[key] = node
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _world.solid_material())
	if node == null:
		node = MeshInstance3D.new()
		node.name = "Far_%d_%d_%d" % [lod, gx, gz]
		node.visible = false
		add_child(node)
		_nodes[key] = node
	node.mesh = mesh


## The mesh of a node (arrays of one surface), or null when there is no ground in it. Pure function (see the test).
static func build_arrays(levels: PackedInt32Array, mats: PackedByteArray, width: int, depth: int, lod: int, gx: int, gz: int, preset: MapPreset, cover: GroundCover) -> Variant:
	var step := 1 << lod
	var x0 := gx * GRID * step
	var z0 := gz * GRID * step
	var n := GRID + 1
	var height := PackedFloat32Array()
	height.resize(n * n)
	var mat := PackedByteArray()
	mat.resize(n * n)
	var colour := PackedColorArray()
	colour.resize(n * n)
	var any := false
	for j in n:
		for i in n:
			var cx := x0 + i * step
			var cz := z0 + j * step
			var v := j * n + i
			if cx >= width or cz >= depth:
				height[v] = -1.0
				continue
			var idx := cx + cz * width
			var level := levels[idx]
			if level <= 0:
				height[v] = -1.0
				continue
			any = true
			height[v] = float(level) / Blocks.UNIT
			mat[v] = mats[idx]
			var bare := float(cover.get_bare(cx, cz)) / 255.0 if cover != null else 0.0
			colour[v] = preset.vertex_color(mat[v], Blocks.FACE_TOP, cx, cz, bare)
	if not any:
		return null
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var edges := {}   # edge (a * 4096 + b, a < b) -> [count, triangle centroid x, z, a, b]
	for j in GRID:
		for i in GRID:
			var a := j * n + i
			var b := a + 1
			var d := a + n
			var c := d + 1
			# the diagonal that gives the most triangles over ground, then the flatter one
			var ground := PackedByteArray([int(height[a] >= 0.0), int(height[b] >= 0.0), int(height[c] >= 0.0), int(height[d] >= 0.0)])
			var tris_ac := int(ground[0] + ground[1] + ground[2] == 3) + int(ground[0] + ground[2] + ground[3] == 3)
			var tris_bd := int(ground[0] + ground[1] + ground[3] == 3) + int(ground[1] + ground[2] + ground[3] == 3)
			var use_ac := tris_ac > tris_bd or (tris_ac == tris_bd and absf(height[a] - height[c]) <= absf(height[b] - height[d]))
			var tris: Array
			if use_ac:
				tris = [[a, b, c], [a, c, d]]
			else:
				tris = [[a, b, d], [b, c, d]]
			for t in tris:
				if height[t[0]] < 0.0 or height[t[1]] < 0.0 or height[t[2]] < 0.0:
					continue
				_add_tri(t, i, j, step, x0, z0, n, height, mat, colour, verts, normals, colors, edges)
	# a skirt along every edge that only one triangle has: the end of the node or of the ground
	for e in edges.values():
		if e[0] != 1:
			continue
		_add_skirt(e, x0, z0, step, n, height, mat, verts, normals, colors)
	if verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	return arrays


static func _point(v: int, x0: int, z0: int, step: int, n: int, height: PackedFloat32Array) -> Vector3:
	return Vector3(x0 + (v % n) * step, height[v], z0 + (v / n) * step)


static func _side_colour(m: int) -> Color:
	# the wall of a cliff: earth under grass, the block's own side otherwise
	var c := Blocks.color_of(Blocks.DIRT if m == Blocks.GRASS else m, Blocks.FACE_SIDE)
	return Color(c.r * 0.8, c.g * 0.8, c.b * 0.8, 1.0)


static func _add_tri(t: Array, i: int, j: int, step: int, x0: int, z0: int, n: int, height: PackedFloat32Array, mat: PackedByteArray, colour: PackedColorArray, verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, edges: Dictionary) -> void:
	var pa := _point(t[0], x0, z0, step, n, height)
	var pb := _point(t[1], x0, z0, step, n, height)
	var pc := _point(t[2], x0, z0, step, n, height)
	# a face is drawn when its corners run clockwise seen from the front: (c - a) x (b - a) points out of it
	var nrm := (pc - pa).cross(pb - pa)
	if nrm.length_squared() < 0.000001:
		return
	nrm = nrm.normalized()
	if nrm.y < 0.0:   # it looks down: turn it round
		nrm = -nrm
		var tmp := pb
		pb = pc
		pc = tmp
		var t1: int = t[1]
		t[1] = t[2]
		t[2] = t1
	var lo := minf(minf(pa.y, pb.y), pc.y)
	var hi := maxf(maxf(pa.y, pb.y), pc.y)
	var steep := (hi - lo) > STEEP * step + 0.5
	var top_vertex: int = t[0]
	for v: int in t:
		if height[v] > height[top_vertex]:
			top_vertex = v
	var cliff := _side_colour(mat[top_vertex])
	verts.append(pa)
	verts.append(pb)
	verts.append(pc)
	for v in [t[0], t[1], t[2]]:
		normals.append(nrm)
		colors.append(cliff if steep else colour[v])
	var cx := (pa.x + pb.x + pc.x) / 3.0
	var cz := (pa.z + pb.z + pc.z) / 3.0
	for k in 3:
		var a: int = t[k]
		var b: int = t[(k + 1) % 3]
		var key := mini(a, b) * 4096 + maxi(a, b)
		if edges.has(key):
			edges[key][0] += 1
		else:
			edges[key] = [1, cx, cz, a, b]


static func _add_skirt(e: Array, x0: int, z0: int, step: int, n: int, height: PackedFloat32Array, mat: PackedByteArray, verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray) -> void:
	var pa := _point(e[3], x0, z0, step, n, height)
	var pb := _point(e[4], x0, z0, step, n, height)
	var mid := (pa + pb) * 0.5
	var out := Vector3(mid.x - e[1], 0.0, mid.z - e[2])   # away from the triangle that has the edge
	if out.length_squared() < 0.000001:
		return
	out = out.normalized()
	var qa := pa - Vector3(0.0, SKIRT, 0.0)
	var qb := pb - Vector3(0.0, SKIRT, 0.0)
	var colour := _side_colour(mat[e[3]])
	colour = Color(colour.r * 0.85, colour.g * 0.85, colour.b * 0.85, 1.0)
	for tri in [[pa, pb, qb], [pa, qb, qa]]:
		var a: Vector3 = tri[0]
		var b: Vector3 = tri[1]
		var c: Vector3 = tri[2]
		var nrm := (c - a).cross(b - a)
		if nrm.length_squared() < 0.000001:
			continue
		nrm = nrm.normalized()
		if nrm.dot(out) < 0.0:
			nrm = -nrm
			var tmp := b
			b = c
			c = tmp
		verts.append(a)
		verts.append(b)
		verts.append(c)
		for k in 3:
			normals.append(nrm)
			colors.append(colour)
