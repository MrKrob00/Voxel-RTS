class_name LooseLog
extends RigidBody3D
## A felled log lying on the ground: a real physics body, so it tumbles when the tree falls and settles where it lands.

## Four logs fill a platform (2 x 2 blocks): two side by side, two across them.
const LENGTH := 1.9
const RADIUS := 0.42

var claimed_by: Unit    ## the worker on the way to pick it up


func _init() -> void:
	mass = 6.0
	collision_layer = 2
	collision_mask = 1    # lands on the ground patches (GroundColliders), not on other logs
	can_sleep = true
	linear_damp = 0.4
	angular_damp = 1.2
	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = RADIUS
	cyl.bottom_radius = RADIUS
	cyl.height = LENGTH
	mesh.mesh = cyl
	var m := StandardMaterial3D.new()
	m.albedo_color = Resources.COLORS[Resources.Kind.LOG]
	m.roughness = 0.95
	mesh.material_override = m
	add_child(mesh)
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = RADIUS
	cap.height = LENGTH
	shape.shape = cap
	add_child(shape)
