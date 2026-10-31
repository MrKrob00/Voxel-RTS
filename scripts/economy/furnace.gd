class_name Furnace
extends Station
## The furnace: 3 blocks long (2 of platform and the tray in front), 2 wide and 3 high. The player orders iron ingots (up to SLOTS: an ordered ingot takes
## a slot of the tray in front of it from the order until a unit has carried the made ingot away); units bring the ore and the amber it
## needs (RECIPE for every ingot) and the furnace smelts by itself, one ingot at a time, SMELT_TIME seconds each. The ingots lie in
## the tray: the slots of the made ones are solid, the ordered ones are blue ghosts (a tap on one takes an order back).
##
## The model (art/blockgen.py, baked by scripts/tools/bake_furnace.gd) has its own frame: 3 along x with the tray at the +x end, 2 along z;
## it is turned to `facing` (the way the front looks: 0 +x, 1 +z, 2 -x, 3 -z).

const SLOTS := 8
const SMELT_TIME := 8.0
const RECIPE := {Resources.Kind.IRON: 10, Resources.Kind.AMBER: 2}
const LENGTH := 3
const DEPTH := 2
const HEIGHT := 3
const BRICK_RED := Color("e08a4a")
const BRICK_DARK := Color("a85a2c")
const STONE_GREY := Color("b4b7bb")
const GHOST := Color(0.35, 0.65, 1.0, 0.5)

var facing := 0
var queued := 0                   ## ingots ordered and not made yet (the one in the fire too)
var made := 0                    ## ingots made and lying in the tray
var have := {Resources.Kind.IRON: 0, Resources.Kind.AMBER: 0}   ## what is inside, for the orders that are not in the fire yet
var smelting := false
var progress := 0.0               ## seconds of the ingot in the fire
var _body: Node3D
var _ghosts: Array[MeshInstance3D] = []
var _ingots: Array[MeshInstance3D] = []
var _label: Label3D


static func footprint(furnace_facing: int) -> Vector2i:
	return Vector2i(LENGTH, DEPTH) if furnace_facing % 2 == 0 else Vector2i(DEPTH, LENGTH)


func size() -> Vector2i:
	return footprint(facing)


## A furnace is as tall as it is: all its cells block, up to the chimney.
func covers(c: Vector3i) -> bool:
	return c.y >= origin.y and c.y < origin.y + HEIGHT and c.x >= origin.x and c.x < origin.x + size().x and c.z >= origin.z and c.z < origin.z + size().y


## Why a furnace cannot stand with its corner at `at` looking `furnace_facing` ("" if it can).
static func can_place_at(world: VoxelWorld, bricks: BrickWorld, at: Vector3i, furnace_facing: int, stockpiles: Array, stations: Array) -> String:
	var sz := footprint(furnace_facing)
	for dz in sz.y:
		for dx in sz.x:
			var c := at + Vector3i(dx, 0, dz)
			if not world.in_bounds(c) or not world.in_bounds(c + Vector3i(0, HEIGHT, 0)):
				return "outside the map"
			if not Blocks.is_whole(world.get_block(c + Vector3i(0, -1, 0))):
				return "needs flat whole ground"
			for k in HEIGHT:
				var up := c + Vector3i(0, k, 0)
				if world.get_block(up) != Blocks.AIR:
					return "something is in the way"
				if bricks != null and bricks.occupied(up):
					return "a brick is in the way"
			for s in stockpiles:
				if s.covers(c):
					return "overlaps a stockpile"
			for o in stations:
				if o.covers(c):
					return "overlaps another station"
	return ""


# --- the orders -----------------------------------------------------------------------------------------------

func free_slots() -> int:
	return SLOTS - queued - made


## The player orders one more ingot. False when all the slots are taken.
func order() -> bool:
	if free_slots() <= 0:
		return false
	queued += 1
	_refresh()
	return true


## The player takes an order back (the one in the fire stays). False when there is none to take.
func cancel_order() -> bool:
	if queued - (1 if smelting else 0) <= 0:
		return false
	queued -= 1
	_refresh()
	return true


## How many of `kind` are still to be brought for the orders that are not in the fire yet.
func missing(kind: int) -> int:
	var pending := queued - (1 if smelting else 0)
	return maxi(pending * RECIPE.get(kind, 0) - have.get(kind, 0), 0)


## A unit puts what it brought in; returns how many were taken.
func add_input(kind: int, n: int) -> int:
	var taken := mini(n, missing(kind))
	if taken > 0:
		have[kind] += taken
	return taken


## A unit takes the made ingots away; returns how many.
func take_ingots(n: int) -> int:
	var got := mini(n, made)
	if got > 0:
		made -= got
		_refresh()
	return got


func _process(delta: float) -> void:
	if not smelting and queued > 0 and have[Resources.Kind.IRON] >= RECIPE[Resources.Kind.IRON] and have[Resources.Kind.AMBER] >= RECIPE[Resources.Kind.AMBER]:
		for k in RECIPE:
			have[k] -= RECIPE[k]
		smelting = true
		progress = 0.0
		_refresh()
	if smelting:
		_animate(delta)
		progress += delta
		if progress >= SMELT_TIME:
			smelting = false
			queued -= 1
			made += 1
			_refresh()


## The smoke climbs out of the chimney and thins out (each puff grows, then shrinks away), the sparks fly up with it; the fire flickers.
func _animate(delta: float) -> void:
	_clock += delta
	for i in PUFFS:
		var t := fposmod(_clock * 0.35 + float(i) / PUFFS, 1.0)
		var r := 0.26 + 0.4 * t
		_puffs[i].position = CHIMNEY_TOP - Vector3(1.5, 0.0, 1.0) + Vector3(0.15 * t * sin(i * 2.1), 0.2 + 1.5 * t, 0.12 * t * cos(i * 1.7))
		_puffs[i].scale = Vector3.ONE * r * (1.0 - smoothstep(0.6, 1.0, t))
	for i in SPARKS:
		var t := fposmod(_clock * 0.8 + float(i) / SPARKS, 1.0)
		_sparks[i].position = CHIMNEY_TOP - Vector3(1.5, 0.0, 1.0) + Vector3(0.12 * sin(i * 3.3 + t * 5.0), 0.05 + 0.9 * t, 0.12 * cos(i * 2.3 + t * 4.0))
		_sparks[i].scale = Vector3.ONE * (1.0 - t)
	_fire_material.albedo_color = Color(1.0, 0.45 + 0.12 * sin(_clock * 9.0), 0.1)


# --- how it looks -----------------------------------------------------------------------------------------------

static var _model: Mesh
static var _glow_model: Mesh
static var _ingot: Mesh
static var _clay_material: ShaderMaterial
static var _pane_material: StandardMaterial3D
static var _fire_material: StandardMaterial3D
static var _smoke_material: StandardMaterial3D
static var _spark_material: StandardMaterial3D
static var _ghost_material: StandardMaterial3D

const PUFFS := 5
const SPARKS := 4
const CHIMNEY_TOP := Vector3(1.01, 2.8, 1.04)   ## (the model's frame)

var _puffs: Array[MeshInstance3D] = []
var _sparks: Array[MeshInstance3D] = []
var _fire: MeshInstance3D
var _clock := 0.0


func build(station_kind: int, cell: Vector3i) -> void:
	kind = station_kind
	origin = cell
	enabled = true
	name = "Furnace_%d_%d" % [cell.x, cell.z]
	position = Vector3(cell.x, cell.y, cell.z)
	_make_shared()
	# the model is made with its front (the tray) towards +x, 3 along x and 2 along z; turned to `facing`
	_body = Node3D.new()
	_body.position = Vector3(size().x * 0.5, 0.0, size().y * 0.5)
	_body.rotation.y = deg_to_rad([0.0, -90.0, 180.0, 90.0][facing & 3])
	add_child(_body)
	var shift := Vector3(1.5, 0.0, 1.0)
	var clay := MeshInstance3D.new()
	clay.mesh = _model
	clay.set_surface_override_material(0, _clay_material)
	clay.set_surface_override_material(1, _pane_material)
	clay.position = -shift
	_body.add_child(clay)
	_fire = MeshInstance3D.new()
	_fire.mesh = _glow_model
	_fire.material_override = _fire_material
	_fire.position = -shift
	_fire.visible = false
	_body.add_child(_fire)
	# the ingots of the tray: solid for the made ones, blue ghosts for the ordered ones
	var ingot_material := _mat(Resources.COLORS[Resources.Kind.INGOT])
	ingot_material.metallic = 0.6
	ingot_material.roughness = 0.4
	for i in SLOTS:
		for list in [_ghosts, _ingots]:
			var mi := MeshInstance3D.new()
			mi.mesh = _ingot
			mi.material_override = _ghost_material if list == _ghosts else ingot_material
			mi.transform = slot_transform(i)
			mi.position -= shift
			mi.visible = false
			_body.add_child(mi)
			list.append(mi)
	# the smoke and the sparks over the chimney (they run only while it smelts)
	var puff_mesh := SphereMesh.new()
	puff_mesh.radius = 0.5
	puff_mesh.height = 1.0
	puff_mesh.radial_segments = 8
	puff_mesh.rings = 4
	for i in PUFFS:
		var mi := MeshInstance3D.new()
		mi.mesh = puff_mesh
		mi.material_override = _smoke_material
		mi.visible = false
		_body.add_child(mi)
		_puffs.append(mi)
	var spark_mesh := BoxMesh.new()
	spark_mesh.size = Vector3(0.09, 0.09, 0.09)
	for i in SPARKS:
		var mi := MeshInstance3D.new()
		mi.mesh = spark_mesh
		mi.material_override = _spark_material
		mi.visible = false
		_body.add_child(mi)
		_sparks.append(mi)
	_label = Label3D.new()
	_label.font_size = 22
	_label.pixel_size = 0.0045
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.outline_size = 8
	_label.position = Vector3(size().x * 0.5, HEIGHT + 0.6, size().y * 0.5)
	add_child(_label)
	_refresh()


## What every furnace shares: the meshes and the materials.
static func _make_shared() -> void:
	if _model != null:
		return
	_model = load("res://assets/structures/furnace.res") as Mesh
	_glow_model = load("res://assets/structures/furnace_glow.res") as Mesh
	_ingot = load("res://assets/structures/ingot.obj") as Mesh
	_clay_material = ShaderMaterial.new()
	_clay_material.shader = load("res://shaders/furnace.gdshader")
	_clay_material.set_shader_parameter("day_light", DayCycle.light_texture())
	_pane_material = StandardMaterial3D.new()
	_pane_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_pane_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_pane_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_pane_material.albedo_color = Color(0.08, 0.04, 0.02, 0.25)
	_fire_material = StandardMaterial3D.new()
	_fire_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fire_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fire_material.albedo_color = Color(1.0, 0.5, 0.1)
	_smoke_material = StandardMaterial3D.new()
	_smoke_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_smoke_material.albedo_color = Color(0.78, 0.79, 0.82)
	_spark_material = StandardMaterial3D.new()
	_spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_spark_material.albedo_color = Color(1.0, 0.6, 0.15)
	_ghost_material = StandardMaterial3D.new()
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.albedo_color = GHOST


## Where slot `i` is in the model's frame (x 0..3 with the tray at the +x end, z 0..2): 0..3 lie across the slab side by side, 4..7 lie
## along it on top of them, two by two.
static func slot_transform(i: int) -> Transform3D:
	if i < 4:
		return Transform3D(Basis.IDENTITY, Vector3(2.48, 0.43 + 0.16, 0.27 + i * 0.49))
	var j := i - 4
	return Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(2.25 + (j % 2) * 0.46, 0.43 + 0.32 + 0.16, 0.5 + (j / 2) * 1.0))


## The box of slot `i` in the model's frame (an ingot is 0.8 x 0.32 x 0.46).
static func slot_box(i: int) -> AABB:
	var half := Vector3(0.4, 0.16, 0.23) if i < 4 else Vector3(0.23, 0.16, 0.4)
	return AABB(slot_transform(i).origin - half, half * 2.0)


func _refresh() -> void:
	if _body == null:
		return
	for i in SLOTS:
		_ingots[i].visible = i < made
		_ghosts[i].visible = i >= made and i < made + queued
	_fire.visible = smelting
	for mi in _puffs:
		mi.visible = smelting
	for mi in _sparks:
		mi.visible = smelting
	_label.text = "Furnace  %d/%d" % [queued + made, SLOTS] if queued + made > 0 else "Furnace"


## The ordered slot (a blue ghost) the ray goes through, or -1.
func ghost_at(from: Vector3, dir: Vector3) -> int:
	if _body == null:
		return -1
	var inv := _body.global_transform.affine_inverse()
	var o := inv * from
	var d := (inv.basis * dir).normalized()
	var best := -1
	var best_t := INF
	for i in range(made, made + queued):
		var box := slot_box(i)
		box.position -= Vector3(1.5, 0.0, 1.0)
		var at: Variant = box.intersects_ray(o, d)
		if at != null and o.distance_to(at) < best_t:
			best_t = o.distance_to(at)
			best = i
	return best
