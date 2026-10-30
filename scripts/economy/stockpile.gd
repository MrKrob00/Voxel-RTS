class_name Stockpile
extends Node3D
## A 2x2 place where units put what they carry. It is ONE structure: what it looks like depends on what is in it (its `form`):
##   PLATFORM  a plank platform with the goods lying on it: logs, planks, rope, iron ingots (and when it is empty)
##   CRATE     stone, amber, iron ore or grass: the platform with a copy of it standing up on each of the four sides, a solid crate of 2 x 2 x 2
##             blocks with the loose stuff in it, filling the whole floor and rising from the bottom to the top as the amount grows. When it is filled with stone to the brim, the crate becomes ...
##   STACK     ... a stack of stone bricks (2x1x1, 4 of them: the 2x2x2 volume), without the floor; as bricks are taken it shrinks,
##             and the empty stockpile is a platform again.
## A stockpile holds one kind at a time (it takes a new kind once it is empty). How much fits depends on the kind: bags are half
## blocks (a crate holds 80 of stone, 4 of them are a brick when it is packed), a platform holds 4 logs, 12 planks, 16 ingots or 8 ropes (a rope takes a quarter
## of the area and a fifth of the height).
##
## `origin` is the lowest-x/z cell of the platform at the height of the cell ABOVE the ground (where feet stand on it).

enum Form { PLATFORM, CRATE, STACK }

const SIZE := 2
const PLATFORM_HEIGHT := 0.18
const WALL_HEIGHT := 2.0
## A plank is a 2 x 1 x 1 block cut into three slabs: 2 long, a third of a block thick, 1 wide. A log makes three of them.
const PLANK_SIZE := Vector3(2.0, 1.0 / 3.0, 1.0)
## How many of a kind it holds when full; what is not in the list it does not take.
const CAPACITY := {
	Resources.Kind.LOG: 4, Resources.Kind.PLANK: 12, Resources.Kind.ROPE: 8, Resources.Kind.INGOT: 16,
	Resources.Kind.IRON: 80, Resources.Kind.AMBER: 80, Resources.Kind.STONE: 80, Resources.Kind.PLANT: 80,
	Resources.Kind.BRICK: 8,   # 4 bricks of 2x1x1 = 8 halves, two layers of two (made of a full crate of stone)
}
## What a stockpile costs, paid from the planks in the stockpiles (a guess: the original's price is not known here).
const COST := {Resources.Kind.PLANK: 3}
## The loose kinds that fill a crate.
const FILL_KINDS := [Resources.Kind.STONE, Resources.Kind.PLANT, Resources.Kind.AMBER, Resources.Kind.IRON]
const FILL_GAP := 0.1          ## between the walls and what is inside
const FILL_CHUNKS := 40        ## pieces of rubble on the surface of what is inside
const SHARDS := 72             ## the iron ore: flat angular chips of metal heaped on the surface (one box each, lighter and darker ones)

var origin := Vector3i.ZERO
var holding := Resources.Kind.NONE       ## what it holds right now (NONE when empty)
var auto_bricks := true                  ## a crate filled to the brim with stone turns into four bricks by itself (the round menu of the stockpile switches it)
var count := 0                           ## how many of them
var _piles: Node3D
var _floor: Node3D
var _walls: Node3D
var _fill: Node3D                        ## what a crate holds: a body that fills it up to the amount, and rubble on top (made once, kept)
var _fill_body: MeshInstance3D
var _fill_rubble: MultiMeshInstance3D
var _fill_shards: MultiMeshInstance3D          ## the iron ore
var _fill_kind := Resources.Kind.NONE
var _label: Label3D


## Can a stockpile stand here? Four whole ground blocks at the same height, nothing on top of them (no brick, no other
## stockpile, two free cells of headroom), none of them a slope or half-dug block, and not over water.
static func can_place(world: VoxelWorld, bricks: BrickWorld, origin_cell: Vector3i, others: Array = []) -> String:
	for dz in SIZE:
		for dx in SIZE:
			var c := origin_cell + Vector3i(dx, 0, dz)
			if not world.in_bounds(c) or not world.in_bounds(c + Vector3i(0, 2, 0)):
				return "outside the map"
			if not Blocks.is_whole(world.get_block(c + Vector3i(0, -1, 0))):
				return "needs flat whole ground under all four cells"
			for k in 2:
				var up := c + Vector3i(0, k, 0)
				if world.get_block(up) != Blocks.AIR:
					return "something is in the way"
				if bricks != null and bricks.occupied(up):
					return "a brick is in the way"
			for o in others:
				if o.covers(c):
					return "overlaps another stockpile"
	return ""


## How many of a kind it holds when full (0: it does not take that kind).
func capacity_for(kind: int) -> int:
	return CAPACITY.get(kind, 0)


## The capacity of what it holds now; when empty, the biggest it could take.
func capacity() -> int:
	if holding != Resources.Kind.NONE:
		return capacity_for(holding)
	var best := 0
	for k in CAPACITY:
		best = maxi(best, CAPACITY[k])
	return best


## What it looks like now: by what is in it.
func form() -> int:
	match holding:
		Resources.Kind.STONE, Resources.Kind.PLANT, Resources.Kind.AMBER, Resources.Kind.IRON:
			return Form.CRATE
		Resources.Kind.BRICK:
			return Form.STACK
	return Form.PLATFORM


func covers(c: Vector3i) -> bool:
	return c.y == origin.y and c.x >= origin.x and c.x < origin.x + SIZE and c.z >= origin.z and c.z < origin.z + SIZE


## A crate and a stack are two blocks high: nobody walks through their cells (a platform can be walked over).
func blocks(c: Vector3i) -> bool:
	return form() != Form.PLATFORM and (c.y == origin.y or c.y == origin.y + 1) and c.x >= origin.x and c.x < origin.x + SIZE and c.z >= origin.z and c.z < origin.z + SIZE


func center_point() -> Vector3:
	return Vector3(origin.x + SIZE * 0.5, origin.y, origin.z + SIZE * 0.5)


func free_space() -> int:
	return capacity() - count


func amount(kind: int) -> int:
	return count if kind == holding else 0


## Would it take one more of this kind now (a kind it takes, nothing else inside, room left)?
func accepts(kind: int) -> bool:
	return capacity_for(kind) > 0 and (holding == Resources.Kind.NONE or holding == kind) and count < capacity_for(kind)


## How many more of `kind` it could take now, 0 if it holds something else or does not take that.
func room_for(kind: int) -> int:
	if capacity_for(kind) == 0 or (holding != Resources.Kind.NONE and holding != kind):
		return 0
	return capacity_for(kind) - (count if holding == kind else 0)


## Puts some in; returns how many fit.
func add(kind: int, n: int) -> int:
	var taken := mini(n, room_for(kind))
	if taken > 0:
		holding = kind
		count += taken
		_refresh()
	return taken


## Takes some out; returns how many there were.
func take(kind: int, n: int) -> int:
	var got := mini(n, amount(kind))
	if got > 0:
		count -= got
		if count == 0:
			holding = Resources.Kind.NONE
		_refresh()
	return got


## True when a crate has been filled with stone to the brim: time to turn it into bricks.
func packed_stone() -> bool:
	return auto_bricks and holding == Resources.Kind.STONE and count >= capacity_for(Resources.Kind.STONE)


## Where a unit may stand to use it: any standable cell touching the platform (from the 12 around it).
func access_cells(nav: Navigation) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for dz in range(-1, SIZE + 1):
		for dx in range(-1, SIZE + 1):
			if dx >= 0 and dx < SIZE and dz >= 0 and dz < SIZE:
				continue
			var c := Vector3i(origin.x + dx, origin.y, origin.z + dz)
			if nav.standable(c):
				cells.append(c)
	return cells


func build(cell: Vector3i) -> void:
	origin = cell
	name = "Stockpile_%d_%d" % [cell.x, cell.z]
	position = Vector3(cell.x, cell.y, cell.z)
	_floor = Node3D.new()
	add_child(_floor)
	_plank_panel(_floor, Transform3D.IDENTITY)
	# The walls: the floor copied onto the four sides, standing up (x = 0 and 2, z = 0 and 2); shown while it holds stone or grass.
	_walls = Node3D.new()
	add_child(_walls)
	# Each panel's length goes up, its boards face into the crate and its beams stay outside.
	_plank_panel(_walls, Transform3D(Basis(Vector3.UP, Vector3.RIGHT, Vector3.FORWARD), Vector3(0.0, 0.0, SIZE)))
	_plank_panel(_walls, Transform3D(Basis(Vector3.UP, Vector3.LEFT, Vector3.BACK), Vector3(SIZE, 0.0, 0.0)))
	_plank_panel(_walls, Transform3D(Basis(Vector3.UP, Vector3.BACK, Vector3.RIGHT), Vector3(0.0, 0.0, 0.0)))
	_plank_panel(_walls, Transform3D(Basis(Vector3.UP, Vector3.FORWARD, Vector3.LEFT), Vector3(SIZE, 0.0, SIZE)))
	_piles = Node3D.new()
	add_child(_piles)
	_fill = Node3D.new()
	add_child(_fill)
	_fill_body = MeshInstance3D.new()
	_fill_body.mesh = BoxMesh.new()
	_fill.add_child(_fill_body)
	var rubble := MultiMesh.new()
	rubble.transform_format = MultiMesh.TRANSFORM_3D
	rubble.mesh = _chunk_mesh()
	rubble.instance_count = FILL_CHUNKS
	_fill_rubble = MultiMeshInstance3D.new()
	_fill_rubble.multimesh = rubble
	_fill.add_child(_fill_rubble)
	var shards := MultiMesh.new()
	shards.transform_format = MultiMesh.TRANSFORM_3D
	shards.use_colors = true
	var chip := BoxMesh.new()
	chip.size = Vector3(0.2, 0.08, 0.15)
	shards.mesh = chip
	shards.instance_count = SHARDS
	_fill_shards = MultiMeshInstance3D.new()
	_fill_shards.multimesh = shards
	_fill_shards.material_override = Props.material(true)
	_fill.add_child(_fill_shards)
	_label = Label3D.new()
	_label.font_size = 22
	_label.pixel_size = 0.0045
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.outline_size = 8
	_label.position = Vector3(SIZE * 0.5, WALL_HEIGHT + 0.6, SIZE * 0.5)
	add_child(_label)
	_refresh()


## One 2 x 2 panel of planks: five boards side by side with two beams across, flat, lying with its middle at the cell corner
## (0, 0) and spreading over +x and +z (the floor). Rotated by `t` about the origin for the walls, the beams being the outside.
func _plank_panel(parent: Node3D, t: Transform3D) -> void:
	var panel := Node3D.new()
	panel.transform = t
	parent.add_child(panel)
	var wood := _mat(Color("b98a4e"))
	var dark := _mat(Color("7b5630"))
	for i in 5:
		_box(panel, Vector3(SIZE - 0.08, PLATFORM_HEIGHT * 0.6, SIZE / 5.0 - 0.05), Vector3(SIZE * 0.5, PLATFORM_HEIGHT * 0.7, (i + 0.5) * SIZE / 5.0), wood if i % 2 == 0 else dark)
	for bx in [0.3, SIZE - 0.3]:
		_box(panel, Vector3(0.18, PLATFORM_HEIGHT * 0.5, SIZE - 0.04), Vector3(bx, PLATFORM_HEIGHT * 0.25, SIZE * 0.5), dark)


func _box(parent: Node3D, size: Vector3, pos: Vector3, m: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = m
	mi.position = pos
	parent.add_child(mi)


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.95
	return m


# --- what lies on it -----------------------------------------------------------------------------------

const _GOLDEN_U := 0.6180339887
const _GOLDEN_V := 0.7548776662


static func _fract(x: float) -> float:
	return x - floorf(x)


func _refresh() -> void:
	_floor.visible = form() != Form.STACK     # a stack of bricks stands on the bare ground
	_walls.visible = form() == Form.CRATE
	_fill.visible = count > 0 and FILL_KINDS.has(holding)
	for c in _piles.get_children():
		c.queue_free()
	if count > 0:
		match holding:
			Resources.Kind.STONE, Resources.Kind.PLANT, Resources.Kind.AMBER, Resources.Kind.IRON:
				_show_fill()
			Resources.Kind.LOG:
				_show_logs()
			Resources.Kind.PLANK:
				_show_planks()
			Resources.Kind.ROPE:
				_show_ropes()
			Resources.Kind.BRICK:
				_show_bricks()
			Resources.Kind.INGOT:
				_show_ingots()
	_label.text = "%s %d/%d" % [Resources.label(holding), count, capacity_for(holding)] if count > 0 else "empty"


## Stone, coal, iron and grass in a crate: what is in it fills the whole floor and rises from the bottom as the amount grows, to the top of the
## crate when it is full. A body of the colour of the kind, with rubble lying on its surface (the same pieces, only lifted).
func _show_fill() -> void:
	var full := capacity_for(holding)
	var room := WALL_HEIGHT - PLATFORM_HEIGHT - 0.12
	var h := maxf(float(count) / full * room, 0.06)
	var inner := SIZE - 2.0 * FILL_GAP
	var col: Color = Resources.COLORS.get(holding, Color.GRAY)
	if _fill_kind != holding:
		_fill_kind = holding
		_fill_body.material_override = _mat(col.darkened(0.3))
		_fill_rubble.material_override = _chunk_material(holding)
	_fill_body.scale = Vector3(inner, h, inner)
	_fill_body.position = Vector3(SIZE * 0.5, PLATFORM_HEIGHT + h * 0.5, SIZE * 0.5)
	var half := inner * 0.5 - 0.12
	var iron := holding == Resources.Kind.IRON
	_fill_rubble.visible = not iron
	_fill_shards.visible = iron
	if iron:
		# Iron ore as in the original: a mound of bright and dark angular chips, highest in the middle.
		_fill_body.material_override = _mat(Color("2b2f35"))
		for k in SHARDS:
			var u := _fract((k + 1) * _GOLDEN_U) * 2.0 - 1.0
			var v := _fract((k + 1) * _GOLDEN_V) * 2.0 - 1.0
			var mound := 0.2 * (1.0 - clampf((u * u + v * v) * 0.5, 0.0, 1.0))
			var spin := Basis.from_euler(Vector3(_fract(sin(k * 12.9898) * 43758.5453), _fract(sin(k * 78.233) * 43758.5453), _fract(sin(k * 39.346) * 43758.5453)) * TAU)
			var scale := 0.8 + 0.8 * _fract(sin(k * 93.989) * 43758.5453)
			_fill_shards.multimesh.set_instance_transform(k, Transform3D(spin.scaled(Vector3(scale, scale, scale)), Vector3(SIZE * 0.5 + u * half, PLATFORM_HEIGHT + h + mound - 0.02, SIZE * 0.5 + v * half)))
			var shade := 0.28 + 0.72 * _fract(sin(k * 53.171) * 43758.5453)
			_fill_shards.multimesh.set_instance_color(k, Color(shade * 0.92, shade * 0.97, shade))
		return
	for k in FILL_CHUNKS:
		var u := _fract((k + 1) * _GOLDEN_U) * 2.0 - 1.0
		var v := _fract((k + 1) * _GOLDEN_V) * 2.0 - 1.0
		var size := 0.26 + 0.14 * _fract(sin(k * 12.9898) * 43758.5453)
		var basis := Basis(Vector3.UP, _fract(sin(k * 78.233) * 43758.5453) * TAU).scaled(Vector3(size, size * 0.7, size))
		_fill_rubble.multimesh.set_instance_transform(k, Transform3D(basis, Vector3(SIZE * 0.5 + u * half, PLATFORM_HEIGHT + h - size * 0.25, SIZE * 0.5 + v * half)))


## Up to four logs: two lying side by side, the next two on top of them.
func _show_logs() -> void:
	var m := _mat(Resources.COLORS[Resources.Kind.LOG])
	for i in count:
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = LooseLog.RADIUS
		cyl.bottom_radius = LooseLog.RADIUS
		cyl.height = LooseLog.LENGTH
		mi.mesh = cyl
		mi.material_override = m
		var up := i / 2          # the first two lie along x, the next two across them
		mi.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0)) if up == 0 else Vector3(deg_to_rad(90.0), 0.0, 0.0)
		var side := 0.5 + (i % 2) * 1.0
		mi.position = Vector3(SIZE * 0.5, PLATFORM_HEIGHT + LooseLog.RADIUS, side) if up == 0 else Vector3(side, PLATFORM_HEIGHT + LooseLog.RADIUS * 2.7, SIZE * 0.5)
		_piles.add_child(mi)


## Planks lie in layers of two side by side, the next layer across the one below: 12 of them fill the 2 x 2 x 2 (a log makes three).
func _show_planks() -> void:
	var m := _mat(Resources.COLORS[Resources.Kind.PLANK])
	for i in count:
		var layer := i / 2
		var side := 0.5 + (i % 2) * 1.0
		var along_x := layer % 2 == 0
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(PLANK_SIZE.x - 0.06, PLANK_SIZE.y - 0.02, PLANK_SIZE.z - 0.04) if along_x else Vector3(PLANK_SIZE.z - 0.04, PLANK_SIZE.y - 0.02, PLANK_SIZE.x - 0.06)
		mi.mesh = bm
		mi.material_override = m
		mi.position = Vector3(1.0, PLATFORM_HEIGHT + (layer + 0.5) * PLANK_SIZE.y, side) if along_x else Vector3(side, PLATFORM_HEIGHT + (layer + 0.5) * PLANK_SIZE.y, 1.0)
		_piles.add_child(mi)


## Iron ingots (0.92 x 0.3 x 0.46) lie in layers of eight, every layer across the one below: 16 of them are two layers.
func _show_ingots() -> void:
	var m := _mat(Resources.COLORS[Resources.Kind.INGOT])
	for i in count:
		var layer := i / 8
		var k := i % 8
		var along_x := layer % 2 == 0
		var a := 0.5 + (k % 2) * 1.0
		var b := 0.25 + (k / 2) * 0.5
		_box(_piles, Vector3(0.92, 0.3, 0.46) if along_x else Vector3(0.46, 0.3, 0.92), Vector3(a, PLATFORM_HEIGHT + 0.15 + layer * 0.31, b) if along_x else Vector3(b, PLATFORM_HEIGHT + 0.15 + layer * 0.31, a), m)


## A stack of stone bricks, two layers of two (the crate's 2 x 2 x 2): one brick per two halves, a lone half as a cube on top.
func _show_bricks() -> void:
	var m := _mat(Resources.COLORS[Resources.Kind.BRICK])
	var whole := count / 2
	for i in whole:
		_box(_piles, Vector3(1.94, 0.96, 0.96), Vector3(1.0, 0.5 + (i / 2) * 1.0, 0.5 + (i % 2) * 1.0), m)
	if count % 2 == 1:
		_box(_piles, Vector3(0.96, 0.96, 0.96), Vector3(0.5, 0.5 + (whole / 2) * 1.0, 0.5 + (whole % 2) * 1.0), m)


## Ropes are coils: a quarter of the area each and a fifth of the height, so 4 per layer and 5 layers make 20.
func _show_ropes() -> void:
	var m := _mat(Resources.COLORS[Resources.Kind.ROPE])
	for i in count:
		var mi := MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.2
		ring.outer_radius = 0.42
		mi.mesh = ring
		mi.material_override = m
		mi.scale = Vector3(1.0, 0.55, 1.0)
		mi.position = Vector3(0.5 + (i % 2) * 1.0, PLATFORM_HEIGHT + 0.1 + (i / 4) * 0.17, 0.5 + ((i / 2) % 2) * 1.0)
		_piles.add_child(mi)


static var _chunk: ArrayMesh


static func _chunk_mesh() -> ArrayMesh:
	if _chunk == null:
		_chunk = Props.boulder(5)
	return _chunk


## Stone keeps the grey of the rock model; every other kind tints it.
static func _chunk_material(kind: int) -> Material:
	var m := Props.material(false)
	if kind != Resources.Kind.STONE:
		var c: Color = Resources.COLORS.get(kind, Color.WHITE)
		m.set_shader_parameter("tint", Vector3(minf(c.r * 1.9, 1.0), minf(c.g * 1.9, 1.0), minf(c.b * 1.9, 1.0)))
	return m
