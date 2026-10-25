class_name GroundColliders
extends Node3D
## The terrain has no permanent physics colliders (it is voxel data, picked with a ray, walked with pathfinding). Things that DO
## need to hit the ground, such as falling bricks and felled logs, call `touch(position)` every physics frame: short-lived
## static collision patches are built around that point, and thrown away again a few seconds after the last touch.
## When a voxel inside a live patch changes, the patch is rebuilt, so a dug-out floor lets things fall.

const PATCH := 8
const KEEP_SECONDS := 3.0

var world: VoxelWorld
var _patches := {}         ## Vector3i -> [StaticBody3D, last touched msec]
var _shapes := {}          ## height in quarter-blocks -> BoxShape3D


func _init() -> void:
	for quarters in range(1, Blocks.UNIT + 1):
		var box := BoxShape3D.new()
		box.size = Vector3(1, float(quarters) / Blocks.UNIT, 1)
		_shapes[quarters] = box


func setup(w: VoxelWorld) -> void:
	world = w
	world.block_changed.connect(_on_block_changed)


func patch_count() -> int:
	return _patches.size()


## Makes sure there is ground to land on around `pos`.
func touch(pos: Vector3) -> void:
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


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for key in _patches.keys():
		if now - int(_patches[key][1]) > KEEP_SECONDS * 1000.0:
			(_patches[key][0] as StaticBody3D).queue_free()
			_patches.erase(key)


func _build_patch(key: Vector3i, now: int) -> void:
	var origin := key * PATCH
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	for y in PATCH:
		for z in PATCH:
			for x in PATCH:
				var p := origin + Vector3i(x, y, z)
				var raw := world.get_block(p)
				if not Blocks.is_solid(raw):
					continue
				var quarters := Blocks.max_height(Blocks.shape(raw)) if Blocks.is_partial(raw) else Blocks.UNIT
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
				cs.shape = _shapes[maxi(quarters, 1)]
				cs.position = Vector3(x + 0.5, y + float(maxi(quarters, 1)) / Blocks.UNIT * 0.5, z + 0.5)
				body.add_child(cs)
	body.position = Vector3(origin)
	add_child(body)
	_patches[key] = [body, now]


func _on_block_changed(p: Vector3i) -> void:
	var key := Vector3i(floori(float(p.x) / PATCH), floori(float(p.y) / PATCH), floori(float(p.z) / PATCH))
	if _patches.has(key):
		(_patches[key][0] as StaticBody3D).queue_free()
		_patches.erase(key)
		_build_patch(key, Time.get_ticks_msec())
