class_name PropField
extends Node3D
## Scatters trees, boulders, orange crystals and grass over the generated world and draws each kind with one MultiMesh.
## The scatter is a pure function of the seed (same world, same trees) and runs on a worker thread.

const STEP := 2   ## one candidate spot per STEP x STEP blocks

var world: VoxelWorld
## The trees and the tufts of grass as individual things: workers fell and cut them. Index i of `trees` is instance i of the
## pine MultiMesh; a felled tree keeps its slot (alive 0) and its instance is shrunk to nothing.
var trees: Array[Transform3D] = []
var tufts: Array[Transform3D] = []
var tree_alive := PackedByteArray()
var tuft_alive := PackedByteArray()
var _multimeshes := {}
var _built := false
var _task_id := -1
var _result := {}
var _mutex := Mutex.new()
var _done := false


## The scatter only needs the generator, so it starts at once and runs beside chunk generation. Meshing of the world waits
## for it (hold_meshing): the bare earth under the props is part of the ground colour, so the first picture is the final one.
func setup(w: VoxelWorld) -> void:
	world = w
	world.hold_meshing()
	if world.generator == null:
		world.ready.connect(_launch, CONNECT_ONE_SHOT)   # the world is not in the tree yet: its generator comes with _ready
	else:
		_launch()


func _launch() -> void:
	_task_id = WorkerThreadPool.add_task(_scatter)


func _process(_delta: float) -> void:
	if not _done:
		return
	_mutex.lock()
	var res := _result
	_mutex.unlock()
	_done = false
	for s in _stamps:
		world.stamp_cover_disc(s.pos, s.inner, s.outer, s.strength)
	_build(res)
	trees.assign(res.get("pine", []))
	tufts.assign(res.get("tuft", []))
	tree_alive.resize(trees.size())
	tree_alive.fill(1)
	tuft_alive.resize(tufts.size())
	tuft_alive.fill(1)
	_built = true
	world.release_meshing()
	set_process(false)


## Resource zones, in the spirit of the reference game: a grove here, a pile of boulders there, an orange vein along a cliff
## foot, carpets of bushes with open lanes between them. Each zone is {type, center, radius}; the start island always gets
## one of each within reach of the spawn crystal.
var zones: Array[Dictionary] = []

var _gen: WorldGen
var _preset: MapPreset
var _rng := RandomNumberGenerator.new()
var _out := {"pine": [], "boulder": [], "crystal": [], "tuft": []}
var _stamps: Array[Dictionary] = []   ## where the grass is gone: {pos, inner, outer, strength}, applied on the main thread
## Bare earth around each kind of prop: [inner radius, outer radius, strength], scaled with the prop. Ferns grow in the grass.
const BARE_AROUND := {"pine": [0.9, 2.3, 0.95], "boulder": [0.9, 2.1, 0.9], "crystal": [1.0, 2.2, 0.9]}
var _spawn := Vector2.ZERO


func _scatter() -> void:
	_gen = world.generator
	_preset = world.preset
	_rng.seed = world.world_seed * 7919 + 13
	var sp := world.spawn_point()
	_spawn = Vector2(sp.x + 0.5, sp.z + 0.5)
	var planned: Array[Dictionary] = []

	# Guaranteed start resources, a short walk from the spawn crystal.
	var a0 := _rng.randf() * TAU
	_plan_near(planned, "forest", _spawn, a0, 15.0, 24.0, _rng.randf_range(9.0, 12.0))
	_plan_near(planned, "stone", _spawn, a0 + 2.2, 13.0, 22.0, 4.0)
	_plan_near(planned, "plants", _spawn, a0 + 4.1, 9.0, 15.0, _rng.randf_range(6.0, 9.0))
	_plan_near(planned, "forest", _spawn, a0 + 3.1, 24.0, 34.0, _rng.randf_range(9.0, 13.0))

	# The rest of every island.
	for isl in _gen.islands:
		var count := int(isl.radius / 3.8)
		var tries := 0
		while count > 0 and tries < 200:
			tries += 1
			var ang := _rng.randf() * TAU
			var dist := sqrt(_rng.randf()) * isl.radius * 0.85
			var c: Vector2 = isl.center + Vector2.from_angle(ang) * dist
			var roll := _rng.randf()
			var type := "forest" if roll < 0.55 else ("stone" if roll < 0.70 else "plants")
			var radius := _rng.randf_range(9.0, 15.0) if type == "forest" else (4.0 if type == "stone" else _rng.randf_range(5.0, 9.0))
			if _zone_ok(planned, c, radius):
				planned.append({"type": type, "center": c, "radius": radius})
				count -= 1

	# Orange veins along cliff feet.
	for isl in _gen.islands:
		var want := 3 if isl == _gen.islands[0] else 1
		var feet := _cliff_feet(isl)
		var tries := 0
		while want > 0 and not feet.is_empty() and tries < 60:
			tries += 1
			var foot: Dictionary = feet[_rng.randi() % feet.size()]
			if _zone_ok(planned, foot.pos, 4.0):
				planned.append({"type": "crystal", "center": foot.pos, "radius": 4.0, "dir": foot.tangent})
				want -= 1

	for z in planned:
		match z.type:
			"forest":
				_fill_forest(z)
				_fern_ring(z.center, z.radius * 0.75, z.radius + 3.0, 0.45)
			"stone": _fill_stone(z)
			"plants": _fill_plants(z)
			"crystal": _fill_vein(z)
	# Ferns around the spawn point.
	_fern_ring(_spawn, 7.0, 11.0, 0.12)
	# A thin scatter of single bushes so open ground is not bare.
	for i in 900:
		var isl: WorldGen.Island = _gen.islands[_rng.randi() % _gen.islands.size()]
		var p: Vector2 = isl.center + Vector2.from_angle(_rng.randf() * TAU) * sqrt(_rng.randf()) * isl.radius
		_try_prop("tuft", p, 1, 1.0, 1.6)
	zones = planned
	_mutex.lock()
	_result = _out
	_mutex.unlock()
	_done = true


## Puts every felled tree and cut tuft back (tests share one world and give each suite a fresh one).
func reset() -> void:
	for i in trees.size():
		if tree_alive[i] == 0:
			tree_alive[i] = 1
			_multimeshes["pine"].set_instance_transform(i, trees[i])
			_hide("stump", i, trees[i])
	for i in tufts.size():
		if tuft_alive[i] == 0:
			tuft_alive[i] = 1
			_multimeshes["tuft"].set_instance_transform(i, tufts[i])


func is_built() -> bool:
	return _built


## Indices of the living trees whose foot is inside `rect` (x and z in blocks).
func trees_in_rect(rect: Rect2) -> Array[int]:
	return _in_rect(trees, tree_alive, rect)


func tufts_in_rect(rect: Rect2) -> Array[int]:
	return _in_rect(tufts, tuft_alive, rect)


static func _in_rect(list: Array[Transform3D], alive: PackedByteArray, rect: Rect2) -> Array[int]:
	var out: Array[int] = []
	for i in list.size():
		if alive[i] == 1 and rect.has_point(Vector2(list[i].origin.x, list[i].origin.z)):
			out.append(i)
	return out


## A tree is felled: gone from the picture (the logs it gives are the harvester's business).
func fell_tree(i: int) -> void:
	if i >= 0 and i < trees.size() and tree_alive[i] == 1:
		tree_alive[i] = 0
		_hide("pine", i, trees[i])
		var mm: MultiMesh = _multimeshes.get("stump")
		if mm != null:
			mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, i * 1.3).scaled(Vector3.ONE * 1.0), trees[i].origin))   # the stump stays


func cut_tuft(i: int) -> void:
	if i >= 0 and i < tufts.size() and tuft_alive[i] == 1:
		tuft_alive[i] = 0
		_hide("tuft", i, tufts[i])


func _hide(kind: String, i: int, xf: Transform3D) -> void:
	var mm: MultiMesh = _multimeshes.get(kind)
	if mm != null:
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), xf.origin))


func _surface(x: float, z: float) -> int:
	if _gen.near_bridge(Vector2(x, z), 2.0):
		return -1   # keep bridges clear
	var ix := int(x)
	var iz := int(z)
	var c := _gen.column(ix, iz)
	if c.x < 0:
		return -1
	if _gen.block_at(ix, c.x, iz, c.x, c.y) != _preset.top_block:
		return -1
	return c.x


func _slope(x: float, z: float, top: int) -> int:
	var worst := 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n := _gen.column(int(x) + d.x, int(z) + d.y)
		worst = maxi(worst, absi(n.x - top) if n.x >= 0 else 9)
	return worst


func _zone_ok(planned: Array[Dictionary], c: Vector2, radius: float) -> bool:
	if c.distance_to(_spawn) < radius + 9.0:
		return false
	for z in planned:
		if c.distance_to(z.center) < radius + z.radius + 3.0:
			return false
	var top := _surface(c.x, c.y)
	return top >= 0 and _slope(c.x, c.y, top) <= 1


func _plan_near(planned: Array[Dictionary], type: String, origin: Vector2, angle: float, dmin: float, dmax: float, radius: float) -> void:
	for t in 60:
		var ang := angle + _rng.randf_range(-0.7, 0.7) * (1.0 + t / 20.0)
		var c := origin + Vector2.from_angle(ang) * _rng.randf_range(dmin, dmax)
		if _zone_ok(planned, c, radius):
			planned.append({"type": type, "center": c, "radius": radius})
			return


## Spots where flat ground meets a cliff rising 3+ blocks right next to it, with the cliff direction.
func _cliff_feet(isl: WorldGen.Island) -> Array[Dictionary]:
	var feet: Array[Dictionary] = []
	var r := int(isl.radius)
	var cx := int(isl.center.x)
	var cz := int(isl.center.y)
	for dz in range(-r, r + 1, 3):
		for dx in range(-r, r + 1, 3):
			var x := cx + dx
			var z := cz + dz
			var top := _surface(x, z)
			if top < 0:
				continue
			for d in [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2)]:
				var n := _gen.column(x + d.x, z + d.y)
				if n.x >= top + 3 and _slope(x, z, top) <= 1:
					var tangent := Vector2(-d.y, d.x).normalized()
					feet.append({"pos": Vector2(x + 0.5, z + 0.5), "tangent": tangent})
					break
	return feet


func _try_prop(kind: String, p: Vector2, max_slope: int, smin: float, smax: float) -> bool:
	var top := _surface(p.x, p.y)
	if top < 0 or _slope(p.x, p.y, top) > max_slope:
		return false
	if kind == "pine" or kind == "boulder":
		# A tree crown reaches about two blocks out: no standing at a cliff lip, an island edge or a bridge mouth.
		for d in [Vector2(2, 0), Vector2(-2, 0), Vector2(0, 2), Vector2(0, -2), Vector2(2, 2), Vector2(-2, 2), Vector2(2, -2), Vector2(-2, -2)]:
			var n := _gen.column(int(p.x + d.x), int(p.y + d.y))
			if n.x < 0 or absi(n.x - top) > 2:
				return false
	var xf := _xform(Vector3(p.x, top + 1.0, p.y), _rng, smin, smax)
	_out[kind].append(xf)
	if BARE_AROUND.has(kind):
		var b: Array = BARE_AROUND[kind]
		var s := xf.basis.get_scale().x
		_stamps.append({"pos": p, "inner": b[0] * s, "outer": b[1] * s, "strength": b[2]})
	return true


func _fill_forest(z: Dictionary) -> void:
	var c: Vector2 = z.center
	var r: float = z.radius
	var gx := -r
	while gx <= r:
		var gz := -r
		while gz <= r:
			var p := c + Vector2(gx, gz) + Vector2(_rng.randf_range(-0.7, 0.7), _rng.randf_range(-0.7, 0.7))
			var d := (p - c).length() / r
			if d < 1.0 and _rng.randf() < 0.8 * (1.0 - d * d) + 0.1 and p.distance_to(_spawn) > 8.0:
				_try_prop("pine", p, 1, 0.85, 1.45)
			gz += 1.6
		gx += 1.6


## A band of ferns just outside a grove, like the leafy thickets that edge the groves in the reference.
func _fern_ring(c: Vector2, inner: float, outer: float, chance: float) -> void:
	var gx := -outer
	while gx <= outer:
		var gz := -outer
		while gz <= outer:
			var p := c + Vector2(gx, gz) + Vector2(_rng.randf_range(-0.4, 0.4), _rng.randf_range(-0.4, 0.4))
			var d := (p - c).length()
			if d >= inner and d <= outer and _rng.randf() < chance and p.distance_to(_spawn) > 6.0:
				_try_prop("tuft", p, 1, 1.0, 1.7)
			gz += 1.2
		gx += 1.2


func _fill_stone(z: Dictionary) -> void:
	var c: Vector2 = z.center
	var n := _rng.randi_range(4, 7)
	for i in n:
		var p := c + Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(0.0, 3.2)
		_try_prop("boulder", p, 3, 0.9, 1.9)
	for i in _rng.randi_range(3, 5):
		var p := c + Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(1.5, 4.5)
		_try_prop("boulder", p, 3, 0.35, 0.6)


func _fill_plants(z: Dictionary) -> void:
	var c: Vector2 = z.center
	var r: float = z.radius
	var gx := -r
	while gx <= r:
		var gz := -r
		while gz <= r:
			var p := c + Vector2(gx, gz) + Vector2(_rng.randf_range(-0.4, 0.4), _rng.randf_range(-0.4, 0.4))
			var d := (p - c).length() / r
			if d < 1.0 and _rng.randf() < 0.9 * (1.0 - d * d * 0.7) and p.distance_to(_spawn) > 5.0:
				_try_prop("tuft", p, 2, 1.2, 2.0)
			gz += 1.0
		gx += 1.0


func _fill_vein(z: Dictionary) -> void:
	var c: Vector2 = z.center
	var t: Vector2 = z.dir
	var n := _rng.randi_range(5, 8)
	for i in n:
		var p := c + t * (float(i) - n * 0.5) * 1.1 + Vector2(_rng.randf_range(-0.3, 0.3), _rng.randf_range(-0.3, 0.3))
		_try_prop("crystal", p, 3, 0.9, 1.5)
	for i in _rng.randi_range(4, 6):
		_try_prop("tuft", c + Vector2(_rng.randf_range(-5.0, 5.0), _rng.randf_range(-5.0, 5.0)), 2, 1.0, 1.7)


func _xform(pos: Vector3, rng: RandomNumberGenerator, smin: float, smax: float) -> Transform3D:
	var s := rng.randf_range(smin, smax)
	var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.9, 1.15), s))
	return Transform3D(basis, pos)


func _build(res: Dictionary) -> void:
	var specs := {
		"pine": [Props.pine(), Props.material(false)],
		"boulder": [Props.boulder(3), Props.material(false)],
		"crystal": [Props.crystals(), Props.material(false)],
		"tuft": [Props.tuft(), Props.material(true)],
		"stump": [Props.stump(), Props.material(false)],
	}
	# A stump for every tree, hidden until the tree is felled.
	var hidden: Array = []
	for xf: Transform3D in res.get("pine", []):
		hidden.append(Transform3D(Basis().scaled(Vector3.ZERO), xf.origin))
	res["stump"] = hidden
	for kind in specs:
		var list: Array = res.get(kind, [])
		if list.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = specs[kind][0]
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])
		var inst := MultiMeshInstance3D.new()
		inst.name = kind.capitalize()
		inst.multimesh = mm
		inst.material_override = specs[kind][1]
		add_child(inst)
		_multimeshes[kind] = mm


func counts() -> Dictionary:
	var d := {}
	for c in get_children():
		if c is MultiMeshInstance3D:
			d[c.name] = (c as MultiMeshInstance3D).multimesh.instance_count
	return d
