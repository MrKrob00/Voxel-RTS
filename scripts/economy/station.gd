class_name Station
extends Node3D
## A crafting place. Two kinds, as in the original game:
##   STUMP          a stump with an axe stuck in it: costs one log to set up; a unit brings a log from a stockpile and makes 3 planks of it
##   ROPE_MACHINE   a rope-walk: costs 2 planks (a guess, see DEFS); a unit brings 2 bags of grass and makes 1 rope
## Nobody has to be told: idle units come by themselves when the stockpiles have what the station needs and room for what it makes
## (see CraftTask).
##
## `origin` is the lowest-x/z cell of the footprint at the height of the cell above the ground.

enum Kind { STUMP, ROPE_MACHINE }

const DEFS := {
	Kind.STUMP: {
		"name": "Stump with an axe", "verb": "Produce Planks", "about": "Continually transform logs into planks", "auto": true, "size": Vector2i(1, 1), "cost": {Resources.Kind.LOG: 1},
		"input": {"kind": Resources.Kind.LOG, "amount": 1}, "output": {"kind": Resources.Kind.PLANK, "amount": 3}, "time": 3.0,
	},
	Kind.ROPE_MACHINE: {
		"name": "Rope machine", "verb": "Produce Rope", "about": "Continually transform plants into rope", "auto": false, "size": Vector2i(2, 1), "cost": {Resources.Kind.PLANK: 2},
		"input": {"kind": Resources.Kind.PLANT, "amount": 2}, "output": {"kind": Resources.Kind.ROPE, "amount": 1}, "time": 4.0,
	},
}

var kind := Kind.STUMP
var origin := Vector3i.ZERO
var task: CraftTask
## Whether the station works by itself. A stump does from the start; the rope machine is switched on and off from its round menu.
var enabled := true

const SHOW_OUTPUT_FOR := 3.0      # seconds the made goods lie on the station before the unit takes them away

var _input_vis: Node3D            # what is being worked on: a log on the stump, sacks on the rope machine
var _output_vis: Node3D           # what has been made, lying on the station until the unit has picked it up
var _input_until := 0.0
var _output_until := 0.0


func def() -> Dictionary:
	return DEFS[kind]


func size() -> Vector2i:
	return def().size


func covers(c: Vector3i) -> bool:
	return c.y == origin.y and c.x >= origin.x and c.x < origin.x + size().x and c.z >= origin.z and c.z < origin.z + size().y


## Nobody walks through a station.
func blocks(c: Vector3i) -> bool:
	return covers(c)


func center() -> Vector3:
	return Vector3(origin.x + size().x * 0.5, origin.y, origin.z + size().y * 0.5)


## Why a station of this kind cannot stand with its corner cell at `at` ("" if it can).
static func can_place(world: VoxelWorld, bricks: BrickWorld, station_kind: int, at: Vector3i, stockpiles: Array, stations: Array) -> String:
	var sz: Vector2i = DEFS[station_kind].size
	for dz in sz.y:
		for dx in sz.x:
			var c := at + Vector3i(dx, 0, dz)
			if not world.in_bounds(c) or not world.in_bounds(c + Vector3i(0, 2, 0)):
				return "outside the map"
			if not Blocks.is_whole(world.get_block(c + Vector3i(0, -1, 0))):
				return "needs flat whole ground"
			for k in 2:
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


## Where a unit may stand to work at it: any standable cell around the footprint.
func access_cells(nav: Navigation) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for dz in range(-1, size().y + 1):
		for dx in range(-1, size().x + 1):
			if dx >= 0 and dx < size().x and dz >= 0 and dz < size().y:
				continue
			var c := Vector3i(origin.x + dx, origin.y, origin.z + dz)
			if nav.standable(c):
				out.append(c)
	return out


func build(station_kind: int, cell: Vector3i) -> void:
	kind = station_kind
	origin = cell
	enabled = DEFS[station_kind].get("auto", true)
	name = "Station_%d_%d" % [cell.x, cell.z]
	position = Vector3(cell.x, cell.y, cell.z)
	var wood := _mat(Color("b98a4e"))
	var dark := _mat(Color("7b5630"))
	var steel := _mat(Color("b7bcc4"))
	if kind == Kind.STUMP:
		var stump := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.4
		cyl.bottom_radius = 0.46
		cyl.height = 0.55
		stump.mesh = cyl
		stump.material_override = dark
		stump.position = Vector3(0.5, 0.275, 0.5)
		add_child(stump)
		var top := MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = 0.38
		disc.bottom_radius = 0.38
		disc.height = 0.03
		top.mesh = disc
		top.material_override = _mat(Color("d9b27a"))
		top.position = Vector3(0.5, 0.56, 0.5)
		add_child(top)
		# The axe: a handle leaning out of the top and a steel head sunk into the wood.
		_box(Vector3(0.09, 0.7, 0.09), Vector3(0.55, 0.9, 0.5), wood, Vector3(0.0, 0.0, deg_to_rad(18.0)))
		_box(Vector3(0.34, 0.2, 0.06), Vector3(0.42, 0.66, 0.5), steel, Vector3(0.0, 0.0, deg_to_rad(18.0)))
	else:
		# A low bench, two uprights with a crossbar, a spoked wheel and a coil of rope on it.
		_box(Vector3(1.9, 0.18, 0.7), Vector3(1.0, 0.45, 0.5), dark)
		for lx in [0.2, 1.8]:
			for lz in [0.25, 0.75]:
				_box(Vector3(0.1, 0.4, 0.1), Vector3(lx, 0.2, lz), dark)
		for ux in [0.5, 1.5]:
			_box(Vector3(0.1, 0.8, 0.1), Vector3(ux, 0.95, 0.5), wood)
		_box(Vector3(1.1, 0.08, 0.08), Vector3(1.0, 1.3, 0.5), wood)
		var wheel := MeshInstance3D.new()
		var w := CylinderMesh.new()
		w.top_radius = 0.34
		w.bottom_radius = 0.34
		w.height = 0.07
		wheel.mesh = w
		wheel.material_override = wood
		wheel.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
		wheel.position = Vector3(1.0, 0.95, 0.5)
		add_child(wheel)
		var coil := MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.12
		ring.outer_radius = 0.3
		coil.mesh = ring
		coil.material_override = _mat(Color("d9c28a"))
		coil.position = Vector3(1.55, 0.62, 0.5)
		add_child(coil)
	_make_goods()
	set_process(false)
	var label := Label3D.new()
	label.text = def().name
	label.font_size = 22
	label.pixel_size = 0.0045
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.outline_size = 8
	label.position = Vector3(size().x * 0.5, 1.9, size().y * 0.5)
	add_child(label)


## The goods drawn on the station: the unit is seen putting the log on the stump and the planks lying there afterwards.
func _make_goods() -> void:
	var top := 0.62 if kind == Kind.STUMP else 1.0
	var x := size().x * 0.5
	var z := size().y * 0.5
	_input_vis = Node3D.new()
	_input_vis.position = Vector3(x, top, z)
	_input_vis.visible = false
	add_child(_input_vis)
	_output_vis = Node3D.new()
	_output_vis.position = Vector3(x, top, z)
	_output_vis.visible = false
	add_child(_output_vis)
	if kind == Kind.STUMP:
		var log_mesh := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.16
		cyl.bottom_radius = 0.16
		cyl.height = 0.8
		log_mesh.mesh = cyl
		log_mesh.material_override = _mat(Color("8a5a2b"))
		log_mesh.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
		log_mesh.position.y = 0.16
		_input_vis.add_child(log_mesh)
		for i in 3:   # the three planks made of it, stacked
			var plank := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.8, 0.07, 0.3)
			plank.mesh = bm
			plank.material_override = _mat(Color("c99a5b"))
			plank.position = Vector3(0.0, 0.04 + i * 0.08, 0.0)
			plank.rotation.y = deg_to_rad(i * 14.0 - 14.0)
			_output_vis.add_child(plank)
	else:
		for i in 2:   # two sacks of grass in, one rope out
			var sack := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 0.2
			sm.height = 0.36
			sack.mesh = sm
			sack.material_override = _mat(Color("6b9a3a"))
			sack.position = Vector3(-0.25 + i * 0.5, 0.2, 0.0)
			_input_vis.add_child(sack)
		var coil := MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.1
		ring.outer_radius = 0.26
		coil.mesh = ring
		coil.material_override = _mat(Color("d9c28a"))
		coil.position.y = 0.1
		_output_vis.add_child(coil)


## Called every frame while a unit works here: the material lies on the station for as long as that goes on.
func show_working() -> void:
	_input_until = Time.get_ticks_msec() / 1000.0 + 0.25
	_output_vis.visible = false
	_input_vis.visible = true
	set_process(true)


## The work is done: what was made lies here for a few seconds.
func show_made() -> void:
	_input_vis.visible = false
	_output_until = Time.get_ticks_msec() / 1000.0 + SHOW_OUTPUT_FOR
	_output_vis.visible = true
	set_process(true)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _input_vis.visible and now > _input_until:
		_input_vis.visible = false
	if _output_vis.visible and now > _output_until:
		_output_vis.visible = false
	if not _input_vis.visible and not _output_vis.visible:
		set_process(false)


func _box(sz: Vector3, pos: Vector3, m: StandardMaterial3D, rot := Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = m
	mi.position = pos
	mi.rotation = rot
	add_child(mi)


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.95
	return m
