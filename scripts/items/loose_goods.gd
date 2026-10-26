class_name LooseGoods
extends RigidBody3D
## One thing of a kind (a plank, a bag of grass, a rope, a lump of stone...) thrown into the world because nobody had a place for it:
## a small physics body that settles on the ground. Logs are LooseLog.

const SIZE := 0.34

var kind := Resources.Kind.PLANK


func _init() -> void:
	mass = 1.0
	collision_layer = 2
	collision_mask = 1    # lands on the ground patches (GroundColliders), not on other goods
	can_sleep = true
	linear_damp = 0.5
	angular_damp = 1.5


func setup(k: int) -> LooseGoods:
	kind = k
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(SIZE * 1.6, SIZE * 0.5, SIZE) if k == Resources.Kind.PLANK else Vector3(SIZE, SIZE * 0.8, SIZE)
	mesh.mesh = box
	var m := StandardMaterial3D.new()
	m.albedo_color = Resources.COLORS.get(k, Color(0.6, 0.6, 0.6))
	m.roughness = 0.95
	mesh.material_override = m
	add_child(mesh)
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = box.size
	shape.shape = bs
	add_child(shape)
	return self
