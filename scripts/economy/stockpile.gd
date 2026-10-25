class_name Stockpile
extends Node3D
## A 2x2 wooden platform on flat ground where units put what they carry. Holds a fixed number of bags in total, of any mix.
##
## `origin` is the lowest-x/z cell of the platform at the height of the cell ABOVE the ground (where feet stand on it).

const SIZE := 2
const CAPACITY := 24             ## bags, all kinds together
const PLATFORM_HEIGHT := 0.18

var origin := Vector3i.ZERO
var stock := {}                  ## Resources.Kind -> bags
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
				if Blocks.is_solid(world.get_block(up)) or world.get_block(up) != Blocks.AIR:
					return "something is in the way"
				if bricks != null and bricks.occupied(up):
					return "a brick is in the way"
			for o in others:
				if o.covers(c):
					return "overlaps another stockpile"
	return ""


func covers(c: Vector3i) -> bool:
	return c.y == origin.y and c.x >= origin.x and c.x < origin.x + SIZE and c.z >= origin.z and c.z < origin.z + SIZE


func total() -> int:
	var n := 0
	for k in stock:
		n += stock[k]
	return n


func free_space() -> int:
	return CAPACITY - total()


func amount(kind: int) -> int:
	return stock.get(kind, 0)


## Puts bags in; returns how many fit.
func add(kind: int, n: int) -> int:
	var taken := mini(n, free_space())
	if taken > 0:
		stock[kind] = stock.get(kind, 0) + taken
		_refresh()
	return taken


## Takes bags out; returns how many there were.
func take(kind: int, n: int) -> int:
	var got := mini(n, amount(kind))
	if got > 0:
		stock[kind] -= got
		_refresh()
	return got


## Where a unit may stand to use it: any standable cell touching the platform (from the 12 around it), nearest to `from`.
func access_cells(nav: Navigation) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for dz in range(-1, SIZE + 1):
		for dx in range(-1, SIZE + 1):
			var inside := dx >= 0 and dx < SIZE and dz >= 0 and dz < SIZE
			if inside:
				continue
			var c := Vector3i(origin.x + dx, origin.y, origin.z + dz)
			if nav.standable(c):
				cells.append(c)
	return cells


func build(cell: Vector3i) -> void:
	origin = cell
	name = "Stockpile_%d_%d" % [cell.x, cell.z]
	position = Vector3(cell.x, cell.y, cell.z)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("b98a4e")
	wood.roughness = 0.95
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color("7b5630")
	# Planks: five boards across, with two cross beams underneath.
	for i in 5:
		var board := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(SIZE - 0.08, PLATFORM_HEIGHT * 0.6, SIZE / 5.0 - 0.05)
		board.mesh = bm
		board.material_override = wood if i % 2 == 0 else dark
		board.position = Vector3(SIZE * 0.5, PLATFORM_HEIGHT * 0.7, (i + 0.5) * SIZE / 5.0)
		add_child(board)
	for bx in [0.3, SIZE - 0.3]:
		var beam := MeshInstance3D.new()
		var bm2 := BoxMesh.new()
		bm2.size = Vector3(0.18, PLATFORM_HEIGHT * 0.5, SIZE - 0.04)
		beam.mesh = bm2
		beam.material_override = dark
		beam.position = Vector3(bx, PLATFORM_HEIGHT * 0.25, SIZE * 0.5)
		add_child(beam)
	_piles = Node3D.new()
	add_child(_piles)
	_label = Label3D.new()
	_label.font_size = 22
	_label.pixel_size = 0.0045
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.outline_size = 8
	_label.position = Vector3(SIZE * 0.5, 1.5, SIZE * 0.5)
	add_child(_label)
	_refresh()


## Little heaps on the platform, one box per bag (up to the capacity), coloured by what is in them.
func _refresh() -> void:
	for c in _piles.get_children():
		c.queue_free()
	var i := 0
	for kind in stock:
		for n in stock[kind]:
			var box := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.36, 0.26, 0.36)
			box.mesh = bm
			var m := StandardMaterial3D.new()
			m.albedo_color = Resources.COLORS.get(kind, Color.WHITE)
			m.roughness = 0.9
			box.material_override = m
			var col := i % 4
			var row := (i / 4) % 6
			var layer := i / 24
			box.position = Vector3(0.28 + col * 0.48, PLATFORM_HEIGHT + 0.13 + layer * 0.27, 0.2 + row * 0.32)
			box.rotation.y = (i * 0.37) 
			_piles.add_child(box)
			i += 1
	var lines := PackedStringArray()
	for kind in stock:
		if stock[kind] > 0:
			lines.append("%s %d" % [Resources.label(kind), stock[kind]])
	_label.text = "%d/%d  %s" % [total(), CAPACITY, ", ".join(lines)] if total() > 0 else "empty"
