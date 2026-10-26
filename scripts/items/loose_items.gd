class_name LooseItems
extends Node3D
## Things lying on the ground that are not part of the voxel world: felled logs (physics bodies).
## Ground colliders under them are kept by GroundColliders' auto-tracking of RigidBody3D; this
## node only spawns, culls, and wakes bodies whose floor was dug away.

var world: VoxelWorld
var colliders: GroundColliders
var logs: Array[LooseLog] = []
var goods: Array[LooseGoods] = []


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


## `n` of `kind` are thrown down around `pos`: logs as logs, the rest as small bodies of their colour.
func drop(kind: int, n: int, pos: Vector3) -> void:
	for i in n:
		var at := pos + Vector3(randf_range(-0.4, 0.4), 0.6 + i * 0.35, randf_range(-0.4, 0.4))
		var push := Vector3(randf_range(-0.8, 0.8), 0.4, randf_range(-0.8, 0.8))
		if kind == Resources.Kind.LOG:
			spawn_log(at + Vector3(0.0, 0.8, 0.0), push)
			continue
		var g := LooseGoods.new().setup(kind)
		add_child(g)
		g.position = at
		g.rotation = Vector3(0.0, randf() * TAU, 0.0)
		g.linear_velocity = push
		goods.append(g)
		colliders.touch(at)


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
	for g in goods.duplicate():
		if not is_instance_valid(g):
			goods.erase(g)
		elif g.global_position.y < -20.0:
			goods.erase(g)
			g.queue_free()


func _on_block_changed(p: Vector3i) -> void:
	var at := Vector3(p.x + 0.5, p.y + 0.5, p.z + 0.5)
	for l in logs:
		if is_instance_valid(l) and l.global_position.distance_to(at) < 2.5:
			l.sleeping = false
			colliders.touch(l.global_position)
	for g in goods:
		if is_instance_valid(g) and g.global_position.distance_to(at) < 2.5:
			g.sleeping = false
			colliders.touch(g.global_position)
