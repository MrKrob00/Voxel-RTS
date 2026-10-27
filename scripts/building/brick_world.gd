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

class Brick extends RefCounted:
	var id: int
	var origin: Vector3i
	var axis: int      ## 0: length along X, 1: along Z (facing % 2); kept for walls/tests
	var length: int    ## 2 = long brick, 1 = cube
	var kind: int
	var shape := ""    ## the id of a BlockCatalog shape ("" for the plain brick and cube)
	var facing := 0    ## 0..3: from origin (left/pivot cell) toward the far cell (+x,+z,-x,-z)
	var node: MeshInstance3D

	func cells() -> Array[Vector3i]:
		return BrickWorld.cells_for(origin, facing, length)

	func center() -> Vector3:
		return BrickWorld.center_for(origin, facing, length)


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
var colliders: GroundColliders   ## shared with whatever else needs to land on the ground (felled logs)


func _ready() -> void:
	for length in [1, 2]:
		var mesh := BoxMesh.new()
		mesh.size = Vector3(length, 1, 1) * 0.97
		_meshes[length] = mesh
		var shape := BoxShape3D.new()
		shape.size = Vector3(length, 1, 1)
		_shapes[length] = shape
	for k in [Kind.STONE, Kind.WOOD]:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color("9a9da2") if k == Kind.STONE else Color("a8763f")
		m.roughness = 0.9
		_materials[k] = m


func setup(w: VoxelWorld, shared_colliders: GroundColliders = null) -> void:
	world = w
	colliders = shared_colliders
	if colliders == null:
		colliders = GroundColliders.new()
		colliders.name = "GroundColliders"
		add_child(colliders)
		colliders.setup(w)
	world.block_changed.connect(_on_block_changed)


# --- queries --------------------------------------------------------------------------------------

func occupied(cell: Vector3i) -> bool:
	return _cells.has(cell)


func brick_at(cell: Vector3i) -> Brick:
	return _cells.get(cell)


func brick_count() -> int:
	return _bricks.size()


## Shapes whose low cell is a straight flight of steps, and how many steps a cell holds. The stair block (a flight and a cube) and the
## single flight rise towards `facing`; the flight is the cell on the low side. A unit walks IN such a cell, up the steps.
const FLIGHTS := {"stairs": 3, "stairs_small": 3}
const RISE: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]


## The flight of steps in a cell, as {"rise": Vector2i (the way it climbs), "steps": int}, or {} when the cell holds no flight.
func steps_at(cell: Vector3i) -> Dictionary:
	var b: Brick = _cells.get(cell)
	if b == null or not FLIGHTS.has(b.shape):
		return {}
	var rise := RISE[b.facing & 3]
	if b.length == 2:
		var cs := b.cells()
		var a: int = cs[0].x * rise.x + cs[0].z * rise.y
		var o: int = cs[1].x * rise.x + cs[1].z * rise.y
		if cell != (cs[0] if a < o else cs[1]):
			return {}   # the cube end of the block
	return {"rise": rise, "steps": FLIGHTS[b.shape]}


## The set of the cells the bricks fill (the dictionary itself, not a copy: Navigation asks it directly).
func cell_set() -> Dictionary:
	return _cells


## A copy of what Navigation asks about the bricks, for a thread to read while the main thread goes on changing them.
func snapshot() -> BrickSnapshot:
	var snap := BrickSnapshot.new()
	for c in _cells:
		snap.cells[c] = true
		var flight := steps_at(c)
		if not flight.is_empty():
			snap.flights[c] = flight
	return snap


## Changes whenever a brick is placed or taken out (a new snapshot is needed when it does).
func signature() -> int:
	return _next_id * 100003 + _cells.size()


func debris_count() -> int:
	return _debris.size()


## Unit step from the pivot (origin / left cell) to the far cell of a 2×1×1. Facing 0..3.
static func step_of(facing: int) -> Vector3i:
	return [Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(-1, 0, 0), Vector3i(0, 0, -1)][facing & 3]


## Cells of a brick: origin is the pivot (left part); the second cell is origin + step_of(facing).
## `facing` is 0..3 (+x,+z,-x,-z). Passing 0 or 1 still matches the old axis-only walls.
static func cells_for(origin: Vector3i, facing: int, length: int = 2) -> Array[Vector3i]:
	if length == 1:
		return [origin]
	return [origin, origin + step_of(facing)]


static func center_for(origin: Vector3i, facing: int, length: int = 2) -> Vector3:
	if length == 1:
		return Vector3(origin) + Vector3(0.5, 0.5, 0.5)
	# Midpoint of the two cell centres (pivot stays fixed under the cursor when rotating).
	return Vector3(origin) + Vector3(step_of(facing)) * 0.5 + Vector3(0.5, 0.5, 0.5)


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
func can_place(origin: Vector3i, facing: int, length: int = 2) -> bool:
	var cells := cells_for(origin, facing, length)
	for c in cells:
		if not _cell_free(c):
			return false
	var below := _below(cells)
	return not below.blocked and (below.grounded or not below.supporters.is_empty())


# --- building ---------------------------------------------------------------------------------------

func place(origin: Vector3i, axis: int, kind: int = Kind.STONE, length: int = 2, shape := "", facing := -1) -> Brick:
	# `axis` is facing when the caller only has 0..3; optional `facing` overrides (catalog blocks).
	var face: int = facing if facing >= 0 else axis
	if not can_place(origin, face, length):
		return null
	var b := Brick.new()
	b.id = _next_id
	_next_id += 1
	b.origin = origin
	b.facing = face & 3
	b.axis = b.facing & 1
	b.length = length
	b.kind = kind
	b.shape = shape
	for c in b.cells():
		_cells[c] = b
	_bricks[b.id] = b
	b.node = MeshInstance3D.new()
	b.node.mesh = _meshes[length] if shape == "" else BlockCatalog.mesh(shape)
	b.node.material_override = _materials[kind]
	b.node.transform = _transform_for(b)
	add_child(b.node)
	_trample(b)
	brick_placed.emit(b)
	return b


## A building kills the grass under it and a little around it; the turf fades out softly and does not come back.
func _trample(b: Brick) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in b.cells():
		lo = Vector2(minf(lo.x, c.x), minf(lo.y, c.z))
		hi = Vector2(maxf(hi.x, c.x + 1.0), maxf(hi.y, c.z + 1.0))
	world.stamp_cover_rect(Rect2(lo, hi - lo), 1.2, 1.0)


func _transform_for(b: Brick) -> Transform3D:
	# Mesh lies along +X; yaw by facing so the pivot cell stays the "left" part of the model.
	var yaw := -float(b.facing & 3) * PI * 0.5
	return Transform3D(Basis(Vector3.UP, yaw), b.center())


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
	colliders.touch(body.global_position)
	body.angular_velocity = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.6
	body.linear_velocity = Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5))
	_debris.append([body, Time.get_ticks_msec()])


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	# Debris upkeep: GroundColliders auto-tracks RigidBody3D; here only cull old / fallen / surplus.
	var keep: Array = []
	for entry in _debris:
		var body: RigidBody3D = entry[0]
		if not is_instance_valid(body):
			continue
		var age := (now - int(entry[1])) / 1000.0
		if age > debris_seconds or body.global_position.y < -20.0:
			body.queue_free()
			continue
		keep.append(entry)
	while keep.size() > max_debris:
		var old: Array = keep.pop_front()
		(old[0] as RigidBody3D).queue_free()
	_debris = keep


func _on_block_changed(p: Vector3i) -> void:
	# A brick standing on the voxel that changed may have lost its support (the ground was dug away).
	if _cells.has(p + Vector3i(0, 1, 0)):
		var freed: Array[Vector3i] = [p]
		_settle(freed)
