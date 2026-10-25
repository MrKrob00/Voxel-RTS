class_name Economy
extends Node3D
## Everything the player owns: the stockpiles and what is in them. Units ask it where to put things.

signal changed

var world: VoxelWorld
var bricks: BrickWorld
var stockpiles: Array[Stockpile] = []
var _reserved := {}          ## Stockpile -> bags on their way there


func setup(w: VoxelWorld, b: BrickWorld) -> void:
	world = w
	bricks = b
	world.block_changed.connect(_on_block_changed)


## Puts a stockpile down. Returns null and the reason in `last_error` when it cannot stand there.
var last_error := ""

func place_stockpile(origin: Vector3i) -> Stockpile:
	last_error = Stockpile.can_place(world, bricks, origin, stockpiles)
	if last_error != "":
		return null
	var s := Stockpile.new()
	add_child(s)
	s.build(origin)
	stockpiles.append(s)
	# Grass goes under a building.
	world.stamp_cover_rect(Rect2(origin.x, origin.z, Stockpile.SIZE, Stockpile.SIZE), 0.9)
	changed.emit()
	return s


func remove_stockpile(s: Stockpile) -> void:
	stockpiles.erase(s)
	s.queue_free()
	changed.emit()


## A stockpile with room for one more bag, nearest to `from` (by straight line); null when all are full.
func find_space(from: Vector3i) -> Stockpile:
	var best: Stockpile = null
	var best_d := INF
	for s in stockpiles:
		if s.free_space() - _reserved.get(s, 0) <= 0:
			continue
		var d := Vector2(s.origin.x - from.x, s.origin.z - from.z).length()
		if d < best_d:
			best_d = d
			best = s
	return best


func reserve(s: Stockpile) -> void:
	_reserved[s] = _reserved.get(s, 0) + 1


func unreserve(s: Stockpile) -> void:
	_reserved[s] = maxi(0, _reserved.get(s, 0) - 1)


func deposit(s: Stockpile, kind: int, n: int) -> int:
	unreserve(s)
	var put := s.add(kind, n)
	changed.emit()
	return put


func total(kind: int) -> int:
	var n := 0
	for s in stockpiles:
		n += s.amount(kind)
	return n


func totals() -> Dictionary:
	var out := {}
	for s in stockpiles:
		for k in s.stock:
			out[k] = out.get(k, 0) + s.stock[k]
	return out


## A stockpile whose ground was dug away or built over is gone, its stock with it (a quick rule for now).
func _on_block_changed(p: Vector3i) -> void:
	for s in stockpiles.duplicate():
		if p.y == s.origin.y - 1 or p.y == s.origin.y or p.y == s.origin.y + 1:
			if p.x >= s.origin.x and p.x < s.origin.x + Stockpile.SIZE and p.z >= s.origin.z and p.z < s.origin.z + Stockpile.SIZE:
				if Stockpile.can_place(world, bricks, s.origin, []) != "":
					remove_stockpile(s)
