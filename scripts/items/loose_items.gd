class_name LooseItems
extends Node3D
## Things lying on the ground that are not part of the voxel world: felled logs (physics bodies). Keeps ground colliders under the
## ones that are moving, lets the rest sleep, and wakes the ones whose floor was dug away.

var world: VoxelWorld
var colliders: GroundColliders
var logs: Array[LooseLog] = []


func setup(w: VoxelWorld, c: GroundColliders) -> void:
	world = w
	colliders = c
	world.block_changed.connect(_on_block_changed)


## A log drops from `pos` with a little push; returns it.
func spawn_log(pos: Vector3, push := Vector3.ZERO) -> LooseLog:
	var l := LooseLog.new()
	add_child(l)
	l.position = pos
	l.rotation = Vector3(0.0, randf() * TAU, deg_to_rad(90.0))   # lying along the ground
	l.linear_velocity = push
	l.angular_velocity = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
	logs.append(l)
	colliders.touch(pos)
	return l


func remove_log(l: LooseLog) -> void:
	logs.erase(l)
	if is_instance_valid(l):
		l.queue_free()


func _physics_process(_delta: float) -> void:
	for l in logs.duplicate():
		if not is_instance_valid(l):
			logs.erase(l)
		elif l.global_position.y < -20.0:
			remove_log(l)   # fell off the world
		elif not l.sleeping:
			colliders.touch(l.global_position)


func _on_block_changed(p: Vector3i) -> void:
	var at := Vector3(p.x + 0.5, p.y + 0.5, p.z + 0.5)
	for l in logs:
		if is_instance_valid(l) and l.global_position.distance_to(at) < 2.5:
			l.sleeping = false
			colliders.touch(l.global_position)
