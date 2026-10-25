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
var packed_bricks := 0       ## stone bricks stacked up from frames that were filled to the brim

func place_stockpile(origin: Vector3i, style := Stockpile.Style.PLATFORM) -> Stockpile:
	last_error = Stockpile.can_place(world, bricks, origin, stockpiles)
	if last_error != "":
		return null
	var s := Stockpile.new()
	add_child(s)
	s.build(origin, style)
	stockpiles.append(s)
	# Grass goes under a building.
	world.stamp_cover_rect(Rect2(origin.x, origin.z, Stockpile.SIZE, Stockpile.SIZE), 0.9)
	changed.emit()
	return s


func remove_stockpile(s: Stockpile) -> void:
	stockpiles.erase(s)
	_reserved.erase(s)
	s.queue_free()
	changed.emit()


## A stockpile that would take one more bag of `kind`, nearest to `from` (by straight line); null when there is none.
## Bags already on their way count: two workers do not both get the last place.
func find_space(from: Vector3i, kind: int) -> Stockpile:
	var best: Stockpile = null
	var best_d := INF
	for s in stockpiles:
		if not Stockpile.ACCEPTS[s.style].has(kind):
			continue
		var r: Dictionary = _reserved.get(s, {})
		var other_kind: bool = not r.is_empty() and r.kind != kind
		if other_kind and s.holding == Resources.Kind.NONE:
			continue   # someone is bringing another kind to this empty one
		if not (s.holding == Resources.Kind.NONE or s.holding == kind):
			continue
		if s.free_space() - r.get("count", 0) <= 0:
			continue
		var d := Vector2(s.origin.x - from.x, s.origin.z - from.z).length()
		if d < best_d:
			best_d = d
			best = s
	return best


func reserve(s: Stockpile, kind: int) -> void:
	var r: Dictionary = _reserved.get(s, {"kind": kind, "count": 0})
	r.count += 1
	_reserved[s] = r


func unreserve(s: Stockpile) -> void:
	var r: Dictionary = _reserved.get(s, {})
	if r.is_empty():
		return
	r.count -= 1
	if r.count <= 0:
		_reserved.erase(s)


## Puts a bag down. A frame filled with stone to the brim is replaced by a stack of stone bricks. Returns how many were taken.
func deposit(s: Stockpile, kind: int, n: int) -> int:
	unreserve(s)
	var put := s.add(kind, n)
	if s.packed_stone():
		_pack_into_bricks(s)
	changed.emit()
	return put


## The frame goes, 4 bricks of 2x1x1 stand where it was: two layers of two bricks, side by side.
func _pack_into_bricks(s: Stockpile) -> void:
	var at := s.origin
	remove_stockpile(s)
	for layer in 2:
		for row in 2:
			if bricks.place(Vector3i(at.x, at.y + layer, at.z + row), 0, BrickWorld.Kind.STONE, 2) != null:
				packed_bricks += 1


func total(kind: int) -> int:
	var n := 0
	for s in stockpiles:
		n += s.amount(kind)
	return n


func totals() -> Dictionary:
	var out := {}
	for s in stockpiles:
		if s.count > 0:
			out[s.holding] = out.get(s.holding, 0) + s.count
	return out


## A stockpile whose ground was dug away or built over is gone, its stock with it (a quick rule for now).
func _on_block_changed(p: Vector3i) -> void:
	for s in stockpiles.duplicate():
		if p.y == s.origin.y - 1 or p.y == s.origin.y or p.y == s.origin.y + 1:
			if p.x >= s.origin.x and p.x < s.origin.x + Stockpile.SIZE and p.z >= s.origin.z and p.z < s.origin.z + Stockpile.SIZE:
				if Stockpile.can_place(world, bricks, s.origin, []) != "":
					remove_stockpile(s)
