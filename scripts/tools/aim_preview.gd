class_name AimPreview
extends Node3D
## What a dragging finger is about to order, drawn over the world and seen THROUGH the blocks (no depth test): the columns and
## layers of a quarry, or the circle of a harvest. It exists only while the finger is down.

const MAX_CELLS := 9000
const DIG_COLOR := Color(1.0, 0.62, 0.12, 0.38)
const RING_COLOR := Color(1.0, 0.82, 0.2, 0.35)

var _cells: MultiMeshInstance3D
var _disc: MeshInstance3D


func _init() -> void:
	visible = false
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.vertex_color_use_as_albedo = true
	mat.render_priority = 10
	_cells = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.96
	mm.mesh = box
	mm.instance_count = MAX_CELLS
	mm.visible_instance_count = 0
	_cells.multimesh = mm
	_cells.material_override = mat
	add_child(_cells)
	_disc = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.height = 0.2
	cyl.radial_segments = 48
	_disc.mesh = cyl
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dmat.no_depth_test = true
	dmat.albedo_color = RING_COLOR
	dmat.render_priority = 10
	_disc.material_override = dmat
	_disc.visible = false
	add_child(_disc)


func clear() -> void:
	visible = false
	_disc.visible = false
	_cells.multimesh.visible_instance_count = 0


## The columns x0..x1, z0..z1 down `depth` layers from each column's top. Returns how many blocks it drew.
func show_dig(world: VoxelWorld, x0: int, z0: int, x1: int, z1: int, depth: int) -> int:
	visible = true
	_disc.visible = false
	var mm := _cells.multimesh
	var n := 0
	for z in range(mini(z0, z1), maxi(z0, z1) + 1):
		for x in range(mini(x0, x1), maxi(x0, x1) + 1):
			var top := world.surface_y(x, z)
			if top < 0:
				continue
			for k in depth:
				if n >= MAX_CELLS:
					break
				mm.set_instance_transform(n, Transform3D(Basis.IDENTITY, Vector3(x + 0.5, top - k + 0.5, z + 0.5)))
				mm.set_instance_color(n, DIG_COLOR.lightened(0.0).darkened(0.12 * k))
				n += 1
	mm.visible_instance_count = n
	return n


func show_ring(world: VoxelWorld, center: Vector2, radius: float) -> void:
	visible = true
	_cells.multimesh.visible_instance_count = 0
	_disc.visible = true
	var y := float(world.surface_y(int(center.x), int(center.y))) + 1.1
	_disc.position = Vector3(center.x, y, center.y)
	(_disc.mesh as CylinderMesh).top_radius = radius
	(_disc.mesh as CylinderMesh).bottom_radius = radius
