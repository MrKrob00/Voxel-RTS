class_name Stockpile
extends Node3D
## A 2x2 place where units put what they carry. Two styles, as in the original game:
##   PLATFORM  a plank platform with the goods lying on it: logs, planks, rope, ores
##   FRAME     the same platform with a copy of it standing up on each of the four sides: a solid crate of 2 x 2 x 2 blocks for
##             loose stuff, stone and grass. When a frame is filled with stone to the brim the crate goes and what is left is a
##             stack of 2x1x1 stone bricks (BrickWorld), 4 of them: the 2x2x2 volume of the stockpile.
## A stockpile holds one kind at a time (it takes a new kind once it is empty). How much fits depends on the kind: bags are half
## blocks (a frame holds 16 of stone, a brick is four), a platform holds 4 logs, 24 planks or 20 ropes (a rope takes a quarter
## of the area and a fifth of the height).
##
## `origin` is the lowest-x/z cell of the platform at the height of the cell ABOVE the ground (where feet stand on it).

enum Style { PLATFORM, FRAME, STACK }

const SIZE := 2
const PLATFORM_HEIGHT := 0.18
const WALL_HEIGHT := 2.0
const BAGS_PER_BRICK := 4
const ACCEPTS := {
	Style.PLATFORM: [Resources.Kind.LOG, Resources.Kind.PLANK, Resources.Kind.ROPE, Resources.Kind.IRON, Resources.Kind.COAL, Resources.Kind.AMBER],
	Style.FRAME: [Resources.Kind.STONE, Resources.Kind.PLANT],
	Style.STACK: [Resources.Kind.BRICK],   # the bricks a full frame turned into; builders take them from the top
}
const CAPACITY := {
	Style.PLATFORM: {Resources.Kind.LOG: 4, Resources.Kind.PLANK: 24, Resources.Kind.ROPE: 20, Resources.Kind.IRON: 24, Resources.Kind.COAL: 24, Resources.Kind.AMBER: 24},
	Style.FRAME: {Resources.Kind.STONE: 16, Resources.Kind.PLANT: 16},
	Style.STACK: {Resources.Kind.BRICK: 8},   # 4 bricks of 2x1x1 = 8 halves, two layers of two
}
## What a stockpile costs, paid from the planks in the stockpiles (a guess: the original's price is not known here). The very first one is free.
const COST := {Resources.Kind.PLANK: 3}
const STYLE_NAMES := {Style.PLATFORM: "plank platform", Style.FRAME: "frame", Style.STACK: "stack of bricks"}

var style := Style.PLATFORM
var origin := Vector3i.ZERO
var holding := Resources.Kind.NONE       ## what it holds right now (NONE when empty)
var count := 0                           ## how many of them
var _piles: Node3D
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


## How many of a kind it holds when full (0: this style does not take it).
func capacity_for(kind: int) -> int:
	return CAPACITY[style].get(kind, 0)


## The capacity of what it holds now; when empty, the biggest it could take.
func capacity() -> int:
	if holding != Resources.Kind.NONE:
		return capacity_for(holding)
	var best := 0
	for k in CAPACITY[style]:
		best = maxi(best, CAPACITY[style][k])
	return best


func covers(c: Vector3i) -> bool:
	return c.y == origin.y and c.x >= origin.x and c.x < origin.x + SIZE and c.z >= origin.z and c.z < origin.z + SIZE


## The frame is a solid crate two blocks high: nobody walks through its cells.
func blocks(c: Vector3i) -> bool:
	return (style == Style.FRAME or style == Style.STACK) and (c.y == origin.y or c.y == origin.y + 1) and c.x >= origin.x and c.x < origin.x + SIZE and c.z >= origin.z and c.z < origin.z + SIZE


func free_space() -> int:
	return capacity() - count


func amount(kind: int) -> int:
	return count if kind == holding else 0


## Would it take one more of this kind now (right style, nothing else inside, room left)?
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


## True when a frame has been filled with stone to the brim: time to turn it into bricks.
func packed_stone() -> bool:
	return style == Style.FRAME and holding == Resources.Kind.STONE and count >= capacity_for(Resources.Kind.STONE)


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


func build(cell: Vector3i, new_style: int) -> void:
	style = new_style
	origin = cell
	name = "Stockpile_%d_%d" % [cell.x, cell.z]
	position = Vector3(cell.x, cell.y, cell.z)
	if style != Style.STACK:
		_plank_panel(Transform3D.IDENTITY)   # the floor (a stack of bricks stands on the bare ground)
	if style == Style.FRAME:
		_wooden_frame()
	_piles = Node3D.new()
	add_child(_piles)
	_label = Label3D.new()
	_label.font_size = 22
	_label.pixel_size = 0.0045
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.outline_size = 8
	_label.position = Vector3(SIZE * 0.5, (WALL_HEIGHT + 0.6) if style != Style.PLATFORM else 1.5, SIZE * 0.5)
	add_child(_label)
	_refresh()


## One 2 x 2 panel of planks: five boards side by side with two beams across, flat, lying with its middle at the cell corner
## (0, 0) and spreading over +x and +z (the floor). Rotated by `t` about the origin for the walls, the beams being the outside.
func _plank_panel(t: Transform3D) -> void:
	var panel := Node3D.new()
	panel.transform = t
	add_child(panel)
	var wood := _mat(Color("b98a4e"))
	var dark := _mat(Color("7b5630"))
	for i in 5:
		_box(panel, Vector3(SIZE - 0.08, PLATFORM_HEIGHT * 0.6, SIZE / 5.0 - 0.05), Vector3(SIZE * 0.5, PLATFORM_HEIGHT * 0.7, (i + 0.5) * SIZE / 5.0), wood if i % 2 == 0 else dark)
	for bx in [0.3, SIZE - 0.3]:
		_box(panel, Vector3(0.18, PLATFORM_HEIGHT * 0.5, SIZE - 0.04), Vector3(bx, PLATFORM_HEIGHT * 0.25, SIZE * 0.5), dark)


## The frame of the original's storage: an open wooden rack. Two A-frames (an upright post on each side, a thick top bar, two lower
## bars, a slanted leg splayed outwards) joined by long bars along the top and the middle; what is stored shows between the posts.
func _wooden_frame() -> void:
	var wood := _mat(Color("b98a4e"))
	var dark := _mat(Color("7b5630"))
	var h := WALL_HEIGHT
	var t := 0.16
	for x in [0.1, SIZE - 0.1]:
		for z in [0.1, SIZE - 0.1]:
			_beam(self, Vector3(x, PLATFORM_HEIGHT, z), Vector3(x, h, z), t, wood)                    # the posts
		_beam(self, Vector3(x, h, 0.0), Vector3(x, h, SIZE), t * 1.3, dark)                          # the thick top bar
		_beam(self, Vector3(x, h * 0.5, 0.0), Vector3(x, h * 0.5, SIZE), t, dark)                    # the middle bar
		_beam(self, Vector3(x, h * 0.2, 0.0), Vector3(x, h * 0.2, SIZE), t, dark)                    # the low bar
		var out := -1.0 if x < 1.0 else 1.0
		for z in [0.1, SIZE - 0.1]:
			_beam(self, Vector3(x, h * 0.85, z), Vector3(x + out * 0.45, PLATFORM_HEIGHT, z), t, wood)  # the splayed legs
	for z in [0.1, SIZE - 0.1]:
		_beam(self, Vector3(0.1, h, z), Vector3(SIZE - 0.1, h, z), t * 1.3, dark)                    # the long bars on top
		_beam(self, Vector3(0.1, h * 0.5, z), Vector3(SIZE - 0.1, h * 0.5, z), t, dark)


## A square beam between two points.
func _beam(parent: Node3D, from: Vector3, to: Vector3, thickness: float, m: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	var d := to - from
	bm.size = Vector3(thickness, thickness, d.length())
	mi.mesh = bm
	mi.material_override = m
	parent.add_child(mi)
	var up := Vector3.UP if absf(d.normalized().y) < 0.99 else Vector3.RIGHT
	mi.transform = Transform3D(Basis.looking_at(d.normalized(), up), (from + to) * 0.5)


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

const CHUNKS_PER_UNIT := 8
const _GOLDEN_U := 0.6180339887
const _GOLDEN_V := 0.7548776662


static func _fract(x: float) -> float:
	return x - floorf(x)


func _refresh() -> void:
	for c in _piles.get_children():
		c.queue_free()
	if count > 0:
		match holding:
			Resources.Kind.LOG:
				_show_logs()
			Resources.Kind.PLANK:
				_show_planks()
			Resources.Kind.ROPE:
				_show_ropes()
			Resources.Kind.BRICK:
				_show_bricks()
			_:
				_show_heap()
	_label.text = "%s %d/%d" % [Resources.label(holding), count, capacity_for(holding)] if count > 0 else "empty (%s)" % STYLE_NAMES[style]


## Loose stuff (stone, ore, grass): a heap of rubble that grows with every bag, like the gravel in the original. Chunk k lies on
## the surface of the heap as it was when k chunks were in it, so a bag adds to the top and the heap does not jump about.
func _show_heap() -> void:
	var full := capacity_for(holding)
	var shown := count * CHUNKS_PER_UNIT
	var total := full * CHUNKS_PER_UNIT
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _chunk_mesh()
	mm.instance_count = shown
	var inner := 0.28 if style == Style.FRAME else 0.18
	var half := SIZE * 0.5 - inner
	var top := (WALL_HEIGHT - PLATFORM_HEIGHT - 0.15) if style == Style.FRAME else 0.8
	for k in shown:
		var u := _fract((k + 1) * _GOLDEN_U) * 2.0 - 1.0
		var v := _fract((k + 1) * _GOLDEN_V) * 2.0 - 1.0
		var fill := float(k + 1) / float(total)
		var size := 0.2 + 0.16 * _fract(sin(k * 12.9898) * 43758.5453)
		var shape := 1.0 - 0.3 * clampf((u * u + v * v) * 0.5, 0.0, 1.0)   # a mound: highest in the middle
		var pos := Vector3(SIZE * 0.5 + u * half, PLATFORM_HEIGHT + fill * top * shape - size * 0.35, SIZE * 0.5 + v * half)
		var basis := Basis(Vector3.UP, _fract(sin(k * 78.233) * 43758.5453) * TAU).scaled(Vector3(size, size * 0.85, size))
		mm.set_instance_transform(k, Transform3D(basis, pos))
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.material_override = _chunk_material(holding)
	_piles.add_child(inst)


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


## Planks lie in four stacks, one slab per plank.
func _show_planks() -> void:
	var m := _mat(Resources.COLORS[Resources.Kind.PLANK])
	for i in count:
		var stack := i % 4
		var level := i / 4
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.82, 0.07, 0.82)
		mi.mesh = bm
		mi.material_override = m
		mi.position = Vector3(0.5 + (stack % 2) * 1.0, PLATFORM_HEIGHT + 0.04 + level * 0.075, 0.5 + (stack / 2) * 1.0)
		mi.rotation.y = (level % 3 - 1) * 0.06
		_piles.add_child(mi)


## A stack of stone bricks, two layers of two (the frame's 2 x 2 x 2): one brick per two halves, a lone half as a cube on top.
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
