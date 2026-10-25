class_name Stockpile
extends Node3D
## A 2x2 place where units put what they carry. Two styles, as in the original game:
##   PLATFORM  a plank platform with open heaps on it: wood, ores
##   FRAME     four low walls round the pile: stone and plants. When a frame is filled with stone completely, the frame goes and
##             what is left is a stack of 2x1x1 stone bricks (BrickWorld), 4 of them: the 2x2x2 volume of the stockpile.
## A stockpile holds one kind at a time (it takes a new kind once it is empty). Bags are half blocks: one block of stone is
## two bags, a 2x1x1 brick is four.
##
## `origin` is the lowest-x/z cell of the platform at the height of the cell ABOVE the ground (where feet stand on it).

enum Style { PLATFORM, FRAME }

const SIZE := 2
const PLATFORM_HEIGHT := 0.18
const BAGS_PER_BRICK := 4
const CAPACITY := {Style.PLATFORM: 24, Style.FRAME: 16}   ## bags; a frame is 2 x 2 x 2 blocks = 4 bricks = 16 bags
const ACCEPTS := {
	Style.PLATFORM: [Resources.Kind.WOOD, Resources.Kind.IRON, Resources.Kind.COAL, Resources.Kind.AMBER],
	Style.FRAME: [Resources.Kind.STONE, Resources.Kind.PLANT],
}
const STYLE_NAMES := {Style.PLATFORM: "plank platform", Style.FRAME: "frame"}

var style := Style.PLATFORM
var origin := Vector3i.ZERO
var holding := Resources.Kind.NONE       ## what it holds right now (NONE when empty)
var count := 0                           ## bags
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


func capacity() -> int:
	return CAPACITY[style]


func covers(c: Vector3i) -> bool:
	return c.y == origin.y and c.x >= origin.x and c.x < origin.x + SIZE and c.z >= origin.z and c.z < origin.z + SIZE


func free_space() -> int:
	return capacity() - count


func amount(kind: int) -> int:
	return count if kind == holding else 0


## Would it take a bag of this kind now (right style, nothing else inside, room left)?
func accepts(kind: int) -> bool:
	return ACCEPTS[style].has(kind) and (holding == Resources.Kind.NONE or holding == kind) and free_space() > 0


## Puts bags in; returns how many fit (0 if it holds something else).
func add(kind: int, n: int) -> int:
	if not ACCEPTS[style].has(kind) or (holding != Resources.Kind.NONE and holding != kind):
		return 0
	var taken := mini(n, free_space())
	if taken > 0:
		holding = kind
		count += taken
		_refresh()
	return taken


## Takes bags out; returns how many there were.
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
	return style == Style.FRAME and holding == Resources.Kind.STONE and count >= capacity()


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
	var wood := _mat(Color("b98a4e"))
	var dark := _mat(Color("7b5630"))
	# Planks: five boards across, with two cross beams underneath.
	for i in 5:
		_box(Vector3(SIZE - 0.08, PLATFORM_HEIGHT * 0.6, SIZE / 5.0 - 0.05), Vector3(SIZE * 0.5, PLATFORM_HEIGHT * 0.7, (i + 0.5) * SIZE / 5.0), wood if i % 2 == 0 else dark)
	for bx in [0.3, SIZE - 0.3]:
		_box(Vector3(0.18, PLATFORM_HEIGHT * 0.5, SIZE - 0.04), Vector3(bx, PLATFORM_HEIGHT * 0.25, SIZE * 0.5), dark)
	if style == Style.FRAME:
		# Four walls of two rails each and a post at every corner.
		for rail in 2:
			var y := PLATFORM_HEIGHT + 0.25 + rail * 0.38
			_box(Vector3(SIZE, 0.16, 0.12), Vector3(SIZE * 0.5, y, 0.06), wood)
			_box(Vector3(SIZE, 0.16, 0.12), Vector3(SIZE * 0.5, y, SIZE - 0.06), wood)
			_box(Vector3(0.12, 0.16, SIZE - 0.24), Vector3(0.06, y, SIZE * 0.5), wood)
			_box(Vector3(0.12, 0.16, SIZE - 0.24), Vector3(SIZE - 0.06, y, SIZE * 0.5), wood)
		for cx in [0.07, SIZE - 0.07]:
			for cz in [0.07, SIZE - 0.07]:
				_box(Vector3(0.14, 0.95, 0.14), Vector3(cx, PLATFORM_HEIGHT + 0.45, cz), dark)
	_piles = Node3D.new()
	add_child(_piles)
	_label = Label3D.new()
	_label.font_size = 22
	_label.pixel_size = 0.0045
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.outline_size = 8
	_label.position = Vector3(SIZE * 0.5, 1.6, SIZE * 0.5)
	add_child(_label)
	_refresh()


func _box(size: Vector3, pos: Vector3, m: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = m
	mi.position = pos
	add_child(mi)


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.95
	return m


const CHUNKS_PER_BAG := 8
const _GOLDEN_U := 0.6180339887
const _GOLDEN_V := 0.7548776662


static func _fract(x: float) -> float:
	return x - floorf(x)


## Height of the heap at a point, `u` and `v` in -1..1 across the footprint, for a pile filled to `fill` (0..1): a mound that is
## highest in the middle and reaches the rim of a frame (a bit below it at the edges) when the stockpile is full.
func _heap_height(u: float, v: float, fill: float) -> float:
	var top := 0.95 if style == Style.FRAME else 0.8
	var shape := 1.0 - 0.42 * clampf((u * u + v * v) * 0.5, 0.0, 1.0)
	return PLATFORM_HEIGHT + fill * top * shape


## What is stored, as a heap of rubble that grows with every bag, like the gravel in the original game. Chunk k lies on the
## surface of the heap as it was when k chunks were in it, so a bag adds to the top and does not make the heap jump about.
func _refresh() -> void:
	for c in _piles.get_children():
		c.queue_free()
	var shown := count * CHUNKS_PER_BAG
	var total := capacity() * CHUNKS_PER_BAG
	if shown > 0:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _chunk_mesh()
		mm.instance_count = shown
		var inner := 0.28 if style == Style.FRAME else 0.18
		var half := SIZE * 0.5 - inner
		for k in shown:
			var u := _fract((k + 1) * _GOLDEN_U) * 2.0 - 1.0
			var v := _fract((k + 1) * _GOLDEN_V) * 2.0 - 1.0
			var fill := float(k + 1) / float(total)
			var size := 0.2 + 0.16 * _fract(sin(k * 12.9898) * 43758.5453)
			var pos := Vector3(SIZE * 0.5 + u * half, _heap_height(u, v, fill) - size * 0.35, SIZE * 0.5 + v * half)
			var basis := Basis(Vector3.UP, _fract(sin(k * 78.233) * 43758.5453) * TAU).scaled(Vector3(size, size * 0.85, size))
			mm.set_instance_transform(k, Transform3D(basis, pos))
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = mm
		inst.material_override = _chunk_material(holding)
		_piles.add_child(inst)
	_label.text = "%s %d/%d" % [Resources.label(holding), count, capacity()] if count > 0 else "empty (%s)" % STYLE_NAMES[style]


static var _chunk: ArrayMesh


static func _chunk_mesh() -> ArrayMesh:
	if _chunk == null:
		_chunk = Props.boulder(5)
	return _chunk


## Stone keeps the grey of the rock model; every other kind tints it.
static func _chunk_material(kind: int) -> StandardMaterial3D:
	var m := Props.material(false)
	if kind != Resources.Kind.STONE:
		var c: Color = Resources.COLORS.get(kind, Color.WHITE)
		m.albedo_color = Color(minf(c.r * 1.9, 1.0), minf(c.g * 1.9, 1.0), minf(c.b * 1.9, 1.0))
	return m
