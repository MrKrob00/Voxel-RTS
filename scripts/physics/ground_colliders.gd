class_name GroundColliders
extends Node3D
## The terrain has no permanent physics colliders (it is voxel data, picked with a ray, walked with pathfinding). Things that DO
## need to hit the ground, such as falling bricks and felled logs, call `touch(position)` every physics frame, and the ground around
## them is made solid. The way it is made is the way LiteTerrain does it:
##   - ONE static body holds all of it; the ground is cut in tiles of TILE x TILE columns, the key of a tile is its place on the grid;
##   - every thing that asks adds the tiles round it to ONE set for the frame (`_want`), so things that lie close together share
##     their tiles: a pile of logs is one window, not a window per log, and a tile that stands is not made again;
##   - a tile stays GRACE seconds after the last time it was asked for, not just a frame, or things on the edge of a window
##     would make and break the same tile again and again;
##   - a tile is a handful of boxes, not a box per block: the ground is a height map (the blocks of a column that can be hit are one box
##     from the height of its lowest neighbour up to its own height), and neighbouring columns of the same height and the same depth are
##     joined into one box.
## When a block inside a live tile changes the tile is made again (once per frame, however many blocks changed).

const TILE := 16              ## columns along a side of a tile
const REACH := 3.0            ## blocks round a thing that must be solid
const GRACE := 4.0            ## seconds a tile lives after it was last asked for
const MIN_THICKNESS := 1.0    ## blocks: the boxes are at least this thick, so that nothing slips through the top of a column

var world: VoxelWorld
var _body: StaticBody3D
var _tiles := {}              ## Vector2i -> {"shapes": Array[CollisionShape3D], "seen": msec}
var _want := {}               ## Vector2i -> true: tiles asked for since the last physics frame
var _dirty := {}              ## Vector2i -> true: tiles whose blocks changed
var _boxes := {}              ## Vector3 size -> BoxShape3D (the same size is the same shape)


func setup(w: VoxelWorld) -> void:
	world = w
	_body = StaticBody3D.new()
	_body.name = "Ground"
	_body.collision_layer = 1
	_body.collision_mask = 0
	add_child(_body)
	world.block_changed.connect(_on_block_changed)


func patch_count() -> int:
	return _tiles.size()


## Makes sure there is ground to land on around `pos`.
func touch(pos: Vector3) -> void:
	var x0 := floori((pos.x - REACH) / TILE)
	var x1 := floori((pos.x + REACH) / TILE)
	var z0 := floori((pos.z - REACH) / TILE)
	var z1 := floori((pos.z + REACH) / TILE)
	for tz in range(z0, z1 + 1):
		for tx in range(x0, x1 + 1):
			_want[Vector2i(tx, tz)] = true
	# Ground for the very first frame of a thing: the tile it stands over is there before it can fall into the gap.
	var key := Vector2i(floori(pos.x / TILE), floori(pos.z / TILE))
	if not _tiles.has(key):
		_make_tile(key, Time.get_ticks_msec())


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for key: Vector2i in _want:
		if _tiles.has(key):
			_tiles[key].seen = now
		else:
			_make_tile(key, now)
	_want = {}
	for key: Vector2i in _dirty:
		if _tiles.has(key):
			_free_tile(key)
			_make_tile(key, now)
	_dirty = {}
	for key: Vector2i in _tiles.keys():
		if now - int(_tiles[key].seen) > GRACE * 1000.0:
			_free_tile(key)


func _free_tile(key: Vector2i) -> void:
	for cs: CollisionShape3D in _tiles[key].shapes:
		cs.queue_free()
	_tiles.erase(key)


func _make_tile(key: Vector2i, now: int) -> void:
	var shapes: Array[CollisionShape3D] = []
	for rect in tile_boxes(world, key):
		var size := Vector3(rect.x1 - rect.x0, float(rect.top - rect.bottom) / Blocks.UNIT, rect.z1 - rect.z0)
		var box: BoxShape3D = _boxes.get(size)
		if box == null:
			box = BoxShape3D.new()
			box.size = size
			_boxes[size] = box
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = Vector3((rect.x0 + rect.x1) * 0.5, (float(rect.top + rect.bottom) / Blocks.UNIT) * 0.5, (rect.z0 + rect.z1) * 0.5)
		_body.add_child(cs)
		shapes.append(cs)
	_tiles[key] = {"shapes": shapes, "seen": now}


## The boxes of a tile: [{x0, z0, x1, z1, bottom, top}] (blocks across, quarter-blocks up). Pure function of the ground, for the tests.
static func tile_boxes(w: VoxelWorld, key: Vector2i) -> Array:
	var size := w.size_blocks()
	var x0 := key.x * TILE
	var z0 := key.y * TILE
	# the heights of the tile and one column round it
	var n := TILE + 2
	var h := PackedInt32Array()
	h.resize(n * n)
	for j in n:
		for i in n:
			h[i + j * n] = _level(w, x0 + i - 1, z0 + j - 1, size)
	# each column: its top, and its bottom (the lowest neighbour, but at least MIN_THICKNESS under the top)
	var top := PackedInt32Array()
	var bottom := PackedInt32Array()
	top.resize(TILE * TILE)
	bottom.resize(TILE * TILE)
	for j in TILE:
		for i in TILE:
			var c := h[(i + 1) + (j + 1) * n]
			var low := mini(mini(h[i + (j + 1) * n], h[(i + 2) + (j + 1) * n]), mini(h[(i + 1) + j * n], h[(i + 1) + (j + 2) * n]))
			top[i + j * TILE] = c
			bottom[i + j * TILE] = 0 if c <= 0 else maxi(mini(low, c - int(MIN_THICKNESS * Blocks.UNIT)), 0)
	# join columns of the same top and bottom into rectangles
	var out: Array = []
	var used := PackedByteArray()
	used.resize(TILE * TILE)
	for j in TILE:
		for i in TILE:
			var at := i + j * TILE
			if used[at] != 0 or top[at] <= 0:
				continue
			var t := top[at]
			var b := bottom[at]
			var wd := 1
			while i + wd < TILE and used[at + wd] == 0 and top[at + wd] == t and bottom[at + wd] == b:
				wd += 1
			var ht := 1
			var grow := true
			while j + ht < TILE and grow:
				for k in wd:
					var q := at + ht * TILE + k
					if used[q] != 0 or top[q] != t or bottom[q] != b:
						grow = false
						break
				if grow:
					ht += 1
			for dj in ht:
				for di in wd:
					used[at + dj * TILE + di] = 1
			out.append({"x0": x0 + i, "z0": z0 + j, "x1": x0 + i + wd, "z1": z0 + j + ht, "bottom": b, "top": t})
	return out


static func _level(w: VoxelWorld, x: int, z: int, size: Vector3i) -> int:
	if x < 0 or z < 0 or x >= size.x or z >= size.z:
		return 0
	if w.column_levels_ready:
		return w.column_levels[x + z * size.x]
	return w.ground_level(x, z)


func _on_block_changed(p: Vector3i) -> void:
	# the tile of the column, and the next one when the column is on the edge (the neighbours look at it)
	var tx := floori(float(p.x) / TILE)
	var tz := floori(float(p.z) / TILE)
	var lx := p.x - tx * TILE
	var lz := p.z - tz * TILE
	_dirty[Vector2i(tx, tz)] = true
	if lx == 0:
		_dirty[Vector2i(tx - 1, tz)] = true
	elif lx == TILE - 1:
		_dirty[Vector2i(tx + 1, tz)] = true
	if lz == 0:
		_dirty[Vector2i(tx, tz - 1)] = true
	elif lz == TILE - 1:
		_dirty[Vector2i(tx, tz + 1)] = true
