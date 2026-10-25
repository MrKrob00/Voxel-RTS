class_name BlockCatalog
extends RefCounted
## Every block the player can build, as in the original's "Blocks" panel: its section, how many cells it covers along its length
## (1 or 2), what it is made of. The shapes are meshes made by art/blockgen.py (assets/blocks/<id>.obj, a block lies along x), and
## the pictures of the palette are photographs of those meshes (assets/blocks/icons/<id>.png, made by tools/bake_block_icons.gd).
##
## What a stone block costs does not depend on its shape: one block of stone (a brick in the stack) each, whether it is a cube or a
## brick (see WallPlan.Slot.halves). Wood blocks cost one plank each (not built yet).

const STONE := "stone"
const WOOD := "wood"
const SECTIONS := ["Stone Blocks", "Plugs", "Round Bricks", "Crenelations", "Wood Blocks"]

static var _defs: Array[Dictionary] = []
static var _meshes := {}


static func _d(id: String, section: String, label: String, length: int, material: String, key := "") -> void:
	_defs.append({"id": id, "section": section, "label": label, "length": length, "material": material, "key": key})


static func all() -> Array[Dictionary]:
	if _defs.is_empty():
		_build()
	return _defs


static func get_def(id: String) -> Dictionary:
	for d in all():
		if d.id == id:
			return d
	return {}


static func index_of(id: String) -> int:
	var defs := all()
	for i in defs.size():
		if defs[i].id == id:
			return i
	return -1


static func _build() -> void:
	var s := "Stone Blocks"
	var m := STONE
	_d("brick", s, "Brick", 2, m, "B")
	_d("cube", s, "Cube", 1, m, "H")
	_d("stairs", s, "Stairs", 2, m, "R")                 # a cell of steps and a cell of block
	_d("stairs_small", s, "Steps", 1, m)
	_d("corner_out_l", s, "Outer corner stairs L", 2, m)    # an outer corner stair cell and a cube
	_d("corner_out_r", s, "Outer corner stairs R", 2, m)
	_d("corner_in_l", s, "Inner corner stairs L", 2, m)     # an inner corner stair cell and a cube
	_d("corner_in_r", s, "Inner corner stairs R", 2, m)
	_d("corner_in_cell", s, "Inner corner step", 1, m)
	_d("corner_out_cell", s, "Outer corner step", 1, m)
	_d("tower_a", s, "Tower 1", 1, m, "I")
	_d("tower_b", s, "Tower 2", 1, m)
	_d("tower_squat", s, "Tower 3", 1, m)
	_d("column", s, "Column", 1, m)
	_d("tower_flared", s, "Tower 4", 1, m)
	s = "Plugs"
	_d("plug_1", s, "Plug 1", 1, m, "U")
	_d("plug_2", s, "Plug 2", 1, m)
	_d("plug_3", s, "Plug 3", 1, m)
	_d("plug_4", s, "Plug 4", 1, m)
	_d("plug_5", s, "Plug 5", 1, m)
	s = "Round Bricks"
	_d("round_a", s, "Round + cube", 2, m, "O")
	_d("round_b", s, "Cube + round", 2, m)
	_d("round_c", s, "Round + round", 2, m)
	_d("round_corner", s, "Round corner", 1, m)
	s = "Crenelations"
	_d("cren_slab", s, "Overhang", 2, m, "Y")
	_d("cren_bracket", s, "Bracket", 1, m, "L")
	_d("cren_corner", s, "Corner bracket", 1, m)
	_d("cren_slope", s, "Roof", 1, m, "M")
	_d("cren_slope_corner", s, "Roof corner", 1, m)
	_d("cren_slope_long", s, "Roof long", 2, m)
	_d("cren_hip", s, "Hip", 1, m)
	_d("cren_corbel_long", s, "Corbel", 2, m, "J")
	_d("cren_corbel", s, "Corbel 2", 2, m)
	_d("cren_corbel_small", s, "Corbel 1", 1, m)
	s = "Wood Blocks"
	m = WOOD
	_d("log", s, "Log", 2, m)
	_d("beam", s, "Beam", 2, m, "N")
	_d("post", s, "Post", 1, m, "V")
	_d("brace", s, "Brace", 1, m)
	_d("board", s, "Board", 2, m, "K")
	_d("plank", s, "Plank", 2, m, "Z")
	_d("plank_small", s, "Small plank", 1, m)


## The mesh of a block, lying along x (turn it about y for the other ways).
static func mesh(id: String) -> Mesh:
	if not _meshes.has(id):
		_meshes[id] = load("res://assets/blocks/%s.obj" % id) as Mesh
	return _meshes[id]


## The photograph of a block for the palette.
static func icon(id: String) -> Texture2D:
	return load("res://assets/blocks/icons/%s.png" % id) as Texture2D
