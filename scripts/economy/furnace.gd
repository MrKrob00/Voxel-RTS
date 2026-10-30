class_name Furnace
extends Station
## The furnace: 3 blocks long, 2 wide and 3 high, built of 4 bricks. The player orders iron ingots (up to SLOTS: an ordered ingot takes
## a slot of the tray in front of it from the order until a unit has carried the made ingot away); units bring the ore and the amber it
## needs (RECIPE for every ingot) and the furnace smelts by itself, one ingot at a time, SMELT_TIME seconds each. The ingots lie in
## the tray: the slots of the made ones are solid, the ordered ones are blue ghosts (a tap on one takes an order back).
##
## The model is made once in its own frame (length along x, the front with the tray on the z = 0 side, the body behind it) and turned
## to `facing` (the way the front looks: 0 +x, 1 +z, 2 -x, 3 -z).

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
var _glow: MeshInstance3D
var _label: Label3D


static func footprint(furnace_facing: int) -> Vector2i:
	return Vector2i(DEPTH, LENGTH) if furnace_facing % 2 == 0 else Vector2i(LENGTH, DEPTH)


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
		progress += delta
		if progress >= SMELT_TIME:
			smelting = false
			queued -= 1
			made += 1
			_refresh()


# --- how it looks -----------------------------------------------------------------------------------------------

func build(station_kind: int, cell: Vector3i) -> void:
	kind = station_kind
	origin = cell
	enabled = true
	name = "Furnace_%d_%d" % [cell.x, cell.z]
	position = Vector3(cell.x, cell.y, cell.z)
	_body = Node3D.new()
	_body.position = Vector3(size().x * 0.5, 0.0, size().y * 0.5)
	_body.rotation.y = deg_to_rad([-90.0, 180.0, 90.0, 0.0][facing & 3])
	add_child(_body)
	var clay := _mat(BRICK_RED)
	var clay_dark := _mat(BRICK_DARK)
	var stone := _mat(STONE_GREY)
	# the body: stepped in four, the chimney on top
	_cube(Vector3(2.7, 0.9, 0.95), Vector3(1.5, 0.45, 1.5), clay)
	_cube(Vector3(2.2, 0.9, 0.85), Vector3(1.5, 1.35, 1.5), clay)
	_cube(Vector3(1.6, 0.6, 0.7), Vector3(1.5, 2.1, 1.5), clay)
	_cube(Vector3(0.62, 0.7, 0.62), Vector3(1.5, 2.65, 1.5), clay)
	_cube(Vector3(0.84, 0.14, 0.84), Vector3(1.5, 2.93, 1.5), clay_dark)
	# the two mouths of the fire, and what glows in them while it burns
	for mx in [0.8, 2.2]:
		_cube(Vector3(0.55, 0.5, 0.08), Vector3(mx, 0.4, 1.0), _mat(Color("2a1a10")))
		_cube(Vector3(0.62, 0.1, 0.1), Vector3(mx, 0.69, 1.0), clay_dark)
	_glow = MeshInstance3D.new()
	var glow_mesh := BoxMesh.new()
	glow_mesh.size = Vector3(0.45, 0.35, 0.06)
	_glow.mesh = glow_mesh
	var glow_material := StandardMaterial3D.new()
	glow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_material.albedo_color = Color(1.0, 0.55, 0.15)
	_glow.material_override = glow_material
	_glow.position = Vector3(0.8, 0.38, 0.97) - Vector3(1.5, 0.0, 1.0)
	_glow.visible = false
	_body.add_child(_glow)
	# the tray in front: a stone trough with dividers (its floor, the rim, three dividers)
	_cube(Vector3(2.96, 0.16, 0.96), Vector3(1.5, 0.08, 0.5), stone)
	_cube(Vector3(2.96, 0.3, 0.08), Vector3(1.5, 0.15, 0.04), stone)
	_cube(Vector3(2.96, 0.3, 0.08), Vector3(1.5, 0.15, 0.96), stone)
	_cube(Vector3(0.08, 0.3, 0.96), Vector3(0.04, 0.15, 0.5), stone)
	_cube(Vector3(0.08, 0.3, 0.96), Vector3(2.96, 0.15, 0.5), stone)
	for dx in [0.75, 1.5, 2.25]:
		_cube(Vector3(0.05, 0.28, 0.9), Vector3(dx, 0.14, 0.5), stone)
	# the eight slots: four ingots on end below, four lying across on top of them
	var ghost_material := StandardMaterial3D.new()
	ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_material.albedo_color = GHOST
	var ingot_material := _mat(Resources.COLORS[Resources.Kind.INGOT])
	ingot_material.metallic = 0.6
	ingot_material.roughness = 0.4
	for i in SLOTS:
		var at := slot_box(i)
		for list in [_ghosts, _ingots]:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = at.size
			mi.mesh = bm
			mi.material_override = ghost_material if list == _ghosts else ingot_material
			mi.position = at.get_center() - Vector3(1.5, 0.0, 1.0)
			mi.visible = false
			_body.add_child(mi)
			list.append(mi)
	_label = Label3D.new()
	_label.font_size = 22
	_label.pixel_size = 0.0045
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.outline_size = 8
	_label.position = Vector3(size().x * 0.5, HEIGHT + 0.6, size().y * 0.5)
	add_child(_label)
	_refresh()


## The box of slot `i` in the furnace's own frame: 0..3 ingots standing, 4..7 lying across them.
static func slot_box(i: int) -> AABB:
	var x := 0.375 + 0.75 * (i % 4)
	if i < 4:
		return AABB(Vector3(x - 0.27, 0.16, 0.5 - 0.2), Vector3(0.54, 0.62, 0.4))
	return AABB(Vector3(x - 0.33, 0.78, 0.5 - 0.42), Vector3(0.66, 0.26, 0.84))


func _cube(sz: Vector3, pos: Vector3, m: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = m
	mi.position = pos - Vector3(1.5, 0.0, 1.0)
	_body.add_child(mi)


func _refresh() -> void:
	if _body == null:
		return
	for i in SLOTS:
		_ingots[i].visible = i < made
		_ghosts[i].visible = i >= made and i < made + queued
	_glow.visible = smelting
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
