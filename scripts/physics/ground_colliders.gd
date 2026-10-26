class_name GroundColliders
extends Node3D
## The terrain has no permanent physics colliders (it is voxel data, picked with a ray, walked with
## pathfinding). Things that need to hit the ground — falling bricks, felled logs — get short-lived
## static collision patches around them. A patch is one StaticBody3D whose CollisionShape3D boxes are
## *merged* (greedy runs of same-height cells), so a flat 8x8 floor is a handful of shapes, not 64.
## Bodies are also tracked automatically (RigidBody3D / CharacterBody3D in the scene): the patch under
## a body and along its velocity corridor stays alive; sleeping bodies cost nothing; unused patches
## are freed after KEEP_SECONDS. When a voxel inside a live patch changes, the patch is rebuilt.

const PATCH := 8
const KEEP_SECONDS := 3.0
const LOOKAHEAD := 1.2          ## seconds of velocity to cover ahead of a moving body (XZ only)
const XY_PAD := 1               ## extra patches in X/Z around the body (1 → 3×3 columns)

var world: VoxelWorld
var _patches := {}              ## Vector3i -> {body: StaticBody3D, t: int msec}
var _shapes := {}               ## height in quarter-blocks -> BoxShape3D (1xHx1, shared)
var _bodies: Array = []         ## tracked PhysicsBody3D
var _tracking := false


func _init() -> void:
	for quarters in range(1, Blocks.UNIT + 1):
		var box := BoxShape3D.new()
		box.size = Vector3(1, float(quarters) / Blocks.UNIT, 1)
		_shapes[quarters] = box


func setup(w: VoxelWorld) -> void:
	world = w
	world.block_changed.connect(_on_block_changed)
	call_deferred("_start_tracking")


func patch_count() -> int:
	return _patches.size()


func shape_count() -> int:
	var n := 0
	for key in _patches:
		var b: StaticBody3D = _patches[key].body
		if is_instance_valid(b):
			n += b.get_child_count()
	return n


## Makes sure there is ground to land on around `pos`. Still useful at spawn; tracked bodies also
## keep patches alive without calling this every frame.
func touch(pos: Vector3) -> void:
	_touch_point(pos, Vector3.ZERO)


func _touch_point(pos: Vector3, vel: Vector3) -> void:
	var now := Time.get_ticks_msec()
	# Corridor only in XZ (a falling log must not light up a tower of Y patches).
	var p0 := Vector2(pos.x, pos.z)
	var p1 := p0 + Vector2(vel.x, vel.z) * LOOKAHEAD
	var x0 := floori(minf(p0.x, p1.x) / PATCH) - XY_PAD
	var x1 := floori(maxf(p0.x, p1.x) / PATCH) + XY_PAD
	var z0 := floori(minf(p0.y, p1.y) / PATCH) - XY_PAD
	var z1 := floori(maxf(p0.y, p1.y) / PATCH) + XY_PAD
	# Y: the body's own patch and one below (landing). Never ±pad in Y.
	var y_body := floori(pos.y / PATCH)
	for y in [y_body, y_body - 1]:
		for z in range(z0, z1 + 1):
			for x in range(x0, x1 + 1):
				var key := Vector3i(x, y, z)
				if _patches.has(key):
					_patches[key].t = now
				else:
					_build_patch(key, now)


# --- auto-tracking (LiteTerrain-style) -----------------------------------------------------------

func _start_tracking() -> void:
	var tree := get_tree()
	if tree == null:
		return
	_tracking = true
	var root := tree.current_scene
	if root != null:
		for n in root.find_children("*", "PhysicsBody3D", true, false):
			_register_body(n)
	if not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)
		tree.node_removed.connect(_on_node_removed)


func _is_trackable(n: Node) -> bool:
	return n is RigidBody3D or n is CharacterBody3D


func _top_body(n: Node) -> Node:
	var top: Node = n
	var p := n.get_parent()
	while p != null:
		if _is_trackable(p):
			top = p
		p = p.get_parent()
	return top


func _on_node_added(n: Node) -> void:
	if _is_trackable(n):
		call_deferred("_register_body", n)


func _on_node_removed(n: Node) -> void:
	if _is_trackable(n):
		_bodies.erase(n)


func _register_body(n: Node) -> void:
	if not _tracking or not is_instance_valid(n) or not _is_trackable(n):
		return
	if is_ancestor_of(n) or _top_body(n) != n or _bodies.has(n):
		return
	# Static patches themselves are StaticBody3D — never track those.
	if n is StaticBody3D:
		return
	_bodies.append(n)


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	var dead := false
	for raw in _bodies:
		if raw == null or not is_instance_valid(raw):
			dead = true
			continue
		var body: Node3D = raw
		if body is RigidBody3D:
			var rb := body as RigidBody3D
			if rb.sleeping and not rb.freeze:
				continue
			_touch_point(body.global_position, rb.linear_velocity)
		else:
			_touch_point(body.global_position, Vector3.ZERO)
	if dead:
		var alive: Array = []
		for b in _bodies:
			if b != null and is_instance_valid(b):
				alive.append(b)
		_bodies = alive
	for key in _patches.keys():
		if now - int(_patches[key].t) > KEEP_SECONDS * 1000.0:
			(_patches[key].body as StaticBody3D).queue_free()
			_patches.erase(key)


# --- patch build with greedy box merge -----------------------------------------------------------

func _build_patch(key: Vector3i, now: int) -> void:
	var origin := key * PATCH
	# Collect solid exposed cells as [x, y, z, quarters].
	var cells: Array = []
	for y in PATCH:
		for z in PATCH:
			for x in PATCH:
				var p := origin + Vector3i(x, y, z)
				var raw := world.get_block(p)
				if not Blocks.is_solid(raw):
					continue
				var quarters := Blocks.max_height(Blocks.shape(raw)) if Blocks.is_partial(raw) else Blocks.UNIT
				var exposed := Blocks.is_partial(raw)
				if not exposed:
					for n in ChunkMesher.FACE_NORMALS:
						if not Blocks.is_opaque(world.get_block(p + n)):
							exposed = true
							break
				if not exposed:
					continue
				cells.append([x, y, z, maxi(quarters, 1)])
	if cells.is_empty():
		return   # pure air: no StaticBody3D

	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector3(origin)

	# Greedy merge: group by y-layer and height, merge runs in X then Z.
	var by_layer := {}   # Vector2i(y, quarters) -> Dictionary{ Vector2i(x,z): true }
	for c in cells:
		var k := Vector2i(c[1], c[3])
		if not by_layer.has(k):
			by_layer[k] = {}
		by_layer[k][Vector2i(c[0], c[2])] = true

	for layer_key in by_layer:
		var y: int = layer_key.x
		var quarters: int = layer_key.y
		var mask: Dictionary = by_layer[layer_key]
		var visited := {}
		var h := float(quarters) / Blocks.UNIT
		var shape: BoxShape3D = _shapes[quarters]
		for z in PATCH:
			for x in PATCH:
				var cell := Vector2i(x, z)
				if not mask.has(cell) or visited.has(cell):
					continue
				var x1 := x
				while x1 + 1 < PATCH and mask.has(Vector2i(x1 + 1, z)) and not visited.has(Vector2i(x1 + 1, z)):
					x1 += 1
				var z1 := z
				while z1 + 1 < PATCH:
					var ok := true
					for xx in range(x, x1 + 1):
						var c2 := Vector2i(xx, z1 + 1)
						if not mask.has(c2) or visited.has(c2):
							ok = false
							break
					if not ok:
						break
					z1 += 1
				for zz in range(z, z1 + 1):
					for xx in range(x, x1 + 1):
						visited[Vector2i(xx, zz)] = true
				var sx := float(x1 - x + 1)
				var sz := float(z1 - z + 1)
				var cs := CollisionShape3D.new()
				if sx == 1.0 and sz == 1.0:
					cs.shape = shape
				else:
					var box := BoxShape3D.new()
					box.size = Vector3(sx, h, sz)
					cs.shape = box
				cs.position = Vector3(
					x + sx * 0.5,
					y + h * 0.5,
					z + sz * 0.5
				)
				body.add_child(cs)

	add_child(body)
	_patches[key] = {"body": body, "t": now}


func _on_block_changed(p: Vector3i) -> void:
	var key := Vector3i(
		floori(float(p.x) / PATCH), floori(float(p.y) / PATCH), floori(float(p.z) / PATCH)
	)
	if _patches.has(key):
		(_patches[key].body as StaticBody3D).queue_free()
		_patches.erase(key)
		_build_patch(key, Time.get_ticks_msec())
