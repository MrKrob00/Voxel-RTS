class_name BrickWorld
extends Node3D
## Player-built bricks sitting on the voxel grid: the long brick (2x1x1, long side along X or Z) and the cube (1x1x1).
##
## Stability rule: a brick stands while at least one cell under it is terrain or another standing brick.
## Stacked straight up, every brick has a single support, so knocking out the bottom one drops everything above.
## Laid with offset joints (a running bond), every brick rests on two below and the wall survives losing one.
## Bricks that lose all support leave the grid and fall as RigidBody3D debris, which in turn can only be hit
## by the terrain through short-lived static collision patches built under them (the terrain has no permanent colliders).

signal brick_placed(brick: Brick)
signal brick_removed(brick: Brick)
signal collapsed(count: int)

enum Kind { STONE, WOOD }

const SIZE := Vector3(2, 1, 1)
const PATCH := 8
const PATCH_KEEP_SECONDS := 3.0

class Brick extends RefCounted:
	var id: int
	var origin: Vector3i
	var axis: int      ## long brick only. 0: spans origin and origin + X, 1: spans origin and origin + Z
	var length: int    ## 2 = long brick, 1 = cube
	var kind: int
	var node: MeshInstance3D

	func cells() -> Array[Vector3i]:
		return BrickWorld.cells_for(origin, axis, length)

	func center() -> Vector3:
		return BrickWorld.center_for(origin, axis, length)


var world: VoxelWorld
var max_debris := 120
var debris_seconds := 25.0

var _cells := {}        # Vector3i -> Brick
var _bricks := {}       # int -> Brick
var _next_id := 1
var _meshes := {}       # length -> BoxMesh
var _materials := {}
var _shapes := {}       # length -> BoxShape3D
var _debris: Array = [] # [RigidBody3D, spawn_time_msec]
var _patches := {}      # Vector3i -> [StaticBody3D, last_touched_msec]
var _patch_shape: BoxShape3D
var _patch_shape_half: BoxShape3D


func _ready() -> void:
	for length in [1, 2]:
		var mesh := BoxMesh.new()
		mesh.size = Vector3(length, 1, 1) * 0.97
		_meshes[length] = mesh
		var shape := BoxShape3D.new()
		shape.size = Vector3(length, 1, 1)
		_shapes[length] = shape
	_patch_shape = BoxShape3D.new()
	_patch_shape.size = Vector3.ONE
	_patch_shape_half = BoxShape3D.new()
	_patch_shape_half.size = Vector3(1, 0.5, 1)
	for k in [Kind.STONE, Kind.WOOD]:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color("9a9da2") if k == Kind.STONE else Color("a8763f")
		m.roughness = 0.9
		_materials[k] = m


func setup(w: VoxelWorld) -> void:
	world = w
	world.block_changed.connect(_on_block_changed)


# --- queries --------------------------------------------------------------------------------------

func occupied(cell: Vector3i) -> bool:
	return _cells.has(cell)


func brick_at(cell: Vector3i) -> Brick:
	return _cells.get(cell)


func brick_count() -> int:
	return _bricks.size()


func debris_count() -> int:
	return _debris.size()


static func cells_for(origin: Vector3i, axis: int, length: int = 2) -> Array[Vector3i]:
	if length == 1:
		return [origin]
	return [origin, origin + (Vector3i(1, 0, 0) if axis == 0 else Vector3i(0, 0, 1))]


static func center_for(origin: Vector3i, axis: int, length: int = 2) -> Vector3:
	if length == 1:
		return Vector3(origin) + Vector3(0.5, 0.5, 0.5)
	return Vector3(origin) + (Vector3(1, 0.5, 0.5) if axis == 0 else Vector3(0.5, 0.5, 1))


func _cell_free(cell: Vector3i) -> bool:
	return world.in_bounds(cell) and not Blocks.is_solid(world.get_block(cell)) and not _cells.has(cell)


## What a set of cells rests on (only cells directly below count):
##   grounded   - a whole terrain block is below one of the cells (bricks stand on flat ground only);
##   blocked    - a slope piece or half-dug block is below one of them: that is not a flat voxel to build on;
##   supporters - the standing bricks below.
func _below(cells: Array[Vector3i], self_brick: Brick = null) -> Dictionary:
	var grounded := false
	var blocked := false
	var supporters: Array[Brick] = []
	for c in cells:
		var b := c + Vector3i(0, -1, 0)
		var raw := world.get_block(b)
		if Blocks.is_whole(raw):
			grounded = true
		elif Blocks.is_solid(raw):
			blocked = true
		else:
			var other: Brick = _cells.get(b)
			if other != null and other != self_brick and not supporters.has(other):
				supporters.append(other)
	return {"grounded": grounded, "blocked": blocked, "supporters": supporters}


## Free, inside the world, resting on whole terrain blocks or standing bricks, and not over a slope (no building in
## mid-air or on bevels).
func can_place(origin: Vector3i, axis: int, length: int = 2) -> bool:
	var cells := cells_for(origin, axis, length)
	for c in cells:
		if not _cell_free(c):
			return false
	var below := _below(cells)
	return not below.blocked and (below.grounded or not below.supporters.is_empty())


# --- building ---------------------------------------------------------------------------------------

func place(origin: Vector3i, axis: int, kind: int = Kind.STONE, length: int = 2) -> Brick:
	if not can_place(origin, axis, length):
		return null
	var b := Brick.new()
	b.id = _next_id
	_next_id += 1
	b.origin = origin
	b.axis = axis
	b.length = length
	b.kind = kind
	for c in b.cells():
		_cells[c] = b
	_bricks[b.id] = b
	b.node = MeshInstance3D.new()
	b.node.mesh = _meshes[length]
	b.node.material_override = _materials[kind]
	b.node.transform = _transform_for(b)
	add_child(b.node)
	brick_placed.emit(b)
	return b


func _transform_for(b: Brick) -> Transform3D:
	var turned := b.length == 2 and b.axis == 1
	return Transform3D(Basis(Vector3.UP, PI * 0.5 if turned else 0.0), b.center())


## Takes a brick out of the wall (a worker dismantling it). Returns how many other bricks fell as a result.
func remove(b: Brick) -> int:
	if not _bricks.has(b.id):
		return 0
	var freed: Array[Vector3i] = b.cells()
	_detach(b)
	b.node.queue_free()
	brick_removed.emit(b)
	return _settle(freed)


func _detach(b: Brick) -> void:
	for c in b.cells():
		_cells.erase(c)
	_bricks.erase(b.id)


## After cells were freed: finds bricks that lost all support (directly or through a chain) and drops them.
func _settle(freed: Array[Vector3i]) -> int:
	# Everything that could be affected: bricks above the freed cells, and above those, and so on.
	var cand := {}
	var queue: Array[Brick] = []
	for c in freed:
		var above: Brick = _cells.get(c + Vector3i(0, 1, 0))
		if above != null and not cand.has(above.id):
			cand[above.id] = above
			queue.append(above)
	while not queue.is_empty():
		var cur: Brick = queue.pop_back()
		for c in cur.cells():
			var above: Brick = _cells.get(c + Vector3i(0, 1, 0))
			if above != null and above != cur and not cand.has(above.id):
				cand[above.id] = above
				queue.append(above)
	# A candidate stands if it is grounded, or rests on a non-candidate (those are standing), or on a standing candidate.
	var standing := {}
	var changed := true
	while changed:
		changed = false
		for id in cand:
			if standing.has(id):
				continue
			var b: Brick = cand[id]
			var info := _below(b.cells(), b)
			var ok: bool = info.grounded
			if not ok:
				for s: Brick in info.supporters:
					if not cand.has(s.id) or standing.has(s.id):
						ok = true
						break
			if ok:
				standing[id] = true
				changed = true
	var falling: Array[Brick] = []
	for id in cand:
		if not standing.has(id):
			falling.append(cand[id])
	for b in falling:
		_detach(b)
	for b in falling:
		_spawn_debris(b)
	if not falling.is_empty():
		collapsed.emit(falling.size())
	return falling.size()


# --- falling bricks -----------------------------------------------------------------------------------

func _spawn_debris(b: Brick) -> void:
	var body := RigidBody3D.new()
	body.mass = 3.0
	body.collision_layer = 2
	body.collision_mask = 1 | 2
	body.can_sleep = true
	var cs := CollisionShape3D.new()
	cs.shape = _shapes[b.length]
	body.add_child(cs)
	b.node.get_parent().remove_child(b.node)
	b.node.transform = Transform3D.IDENTITY
	body.add_child(b.node)
	body.transform = _transform_for(b)
	add_child(body)
	_touch_patches(body.global_position)
	body.angular_velocity = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.6
	body.linear_velocity = Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5))
	_debris.append([body, Time.get_ticks_msec()])


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	# Debris upkeep: keep terrain patches under live bodies, drop old / fallen / surplus bodies.
	var keep: Array = []
	for entry in _debris:
		var body: RigidBody3D = entry[0]
		if not is_instance_valid(body):
			continue
		var age := (now - int(entry[1])) / 1000.0
		if age > debris_seconds or body.global_position.y < -20.0:
			body.queue_free()
			continue
		_touch_patches(body.global_position)
		keep.append(entry)
	while keep.size() > max_debris:
		var old: Array = keep.pop_front()
		(old[0] as RigidBody3D).queue_free()
	_debris = keep
	for key in _patches.keys():
		if now - int(_patches[key][1]) > PATCH_KEEP_SECONDS * 1000.0:
			(_patches[key][0] as StaticBody3D).queue_free()
			_patches.erase(key)


func _touch_patches(pos: Vector3) -> void:
	var pc := Vector3i(floori(pos.x / PATCH), floori(pos.y / PATCH), floori(pos.z / PATCH))
	var now := Time.get_ticks_msec()
	for dy in range(-1, 2):
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var key := pc + Vector3i(dx, dy, dz)
				if _patches.has(key):
					_patches[key][1] = now
				else:
					_build_patch(key, now)


func _build_patch(key: Vector3i, now: int) -> void:
	var origin := key * PATCH
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var count := 0
	for y in PATCH:
		for z in PATCH:
			for x in PATCH:
				var p := origin + Vector3i(x, y, z)
				var raw := world.get_block(p)
				if not Blocks.is_solid(raw):
					continue
				var half := Blocks.is_partial(raw) and Blocks.max_height(Blocks.shape(raw)) <= 1
				# Only voxels that touch open space can be hit (a slope piece always does).
				var exposed := Blocks.is_partial(raw)
				if not exposed:
					for n in ChunkMesher.FACE_NORMALS:
						if not Blocks.is_opaque(world.get_block(p + n)):
							exposed = true
							break
				if not exposed:
					continue
				var cs := CollisionShape3D.new()
				cs.shape = _patch_shape_half if half else _patch_shape
				cs.position = Vector3(x, y, z) + (Vector3(0.5, 0.25, 0.5) if half else Vector3.ONE * 0.5)
				body.add_child(cs)
				count += 1
	body.position = Vector3(origin)
	add_child(body)
	_patches[key] = [body, now]


func _on_block_changed(p: Vector3i) -> void:
	# A brick standing on the voxel that changed may have lost its support (the ground was dug away).
	if _cells.has(p + Vector3i(0, 1, 0)):
		var freed: Array[Vector3i] = [p]
		_settle(freed)
	var key := Vector3i(floori(float(p.x) / PATCH), floori(float(p.y) / PATCH), floori(float(p.z) / PATCH))
	if _patches.has(key):
		(_patches[key][0] as StaticBody3D).queue_free()
		_patches.erase(key)
		if not _debris.is_empty():
			_build_patch(key, Time.get_ticks_msec())
