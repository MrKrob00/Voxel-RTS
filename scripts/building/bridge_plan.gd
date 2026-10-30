class_name BridgePlan
extends Blueprint
## A rope bridge over a gap: two blocks wide, a plank for every block of its length (up to MAX_LENGTH), a post with a rope on each side at
## both ends, hanging in an arc of ARC at its ends. It is a plan like a stockpile's (a unit brings planks to it) with one difference: the
## pieces of the bridge are laid one after another by the one unit that builds it, from the end that is nearer to that unit. The unit
## comes with planks in its hands (as many as it can carry, no more than are still to be paid), spends BASE_PLANKS and one on the first
## piece and one on every piece after it; with the hands empty it goes for more. The posts and the ropes stand with the first piece.
##
## Cells: `a` and `b` are the cells the units stand in at the ends (lane 0; the second lane is next to it, on `side`). The pieces fill the
## cells between them; a piece stands at the height of the straight line between the ends (rounded to a cell), the feet follow the line
## less the sag of the arc, and the planks of the piece are in the cell under the feet (a floor for Navigation, see BrickWorld.add_deck).

const MAX_LENGTH := 12
const BASE_PLANKS := 2           ## the planks of the bridge itself (its posts and ropes), spent with the first piece, on top of one for every piece
const ARC := deg_to_rad(10.0)
const WOOD := Color("a8763f")
const WOOD_DARK := Color("7a5229")
const ROPE := Color("c9b27a")

var a := Vector3i.ZERO
var b := Vector3i.ZERO
var axis := 0                    ## 0: the bridge runs along x, 1: along z
var dir := 1                     ## +1 or -1: the way from a to b along the axis
var side := 1                    ## the second lane is the first one moved by `side` across the bridge
var count := 0                   ## pieces (the cells between the ends)
var placed := 0                  ## pieces laid
var from_end := -1               ## 0: laid from a, 1: from b, -1: not begun
var ys := PackedInt32Array()     ## the cell the feet stand in, for each piece
var _claims := {}                ## Vector3i -> true: every cell the bridge takes (so that nothing else is planned there)
var _bricks: BrickWorld
var _ghost: MeshInstance3D       ## the pieces not laid yet (and the posts and ropes until the first piece): translucent
var _built: MeshInstance3D       ## what stands
var _ghost_material: StandardMaterial3D
var finished := false


## Can a bridge be built from `a` to `b` (standing cells, `b` on the line of an axis through `a`), with the second lane on `side`?
## {"ok": bool, "why": String, "count": pieces, "ys": the feet cell of every piece}.
static func check(world: VoxelWorld, nav: Navigation, others: Array, a_cell: Vector3i, b_cell: Vector3i, lane_side: int) -> Dictionary:
	var d := b_cell - a_cell
	if (d.x != 0) == (d.z != 0):
		return {"ok": false, "why": "a bridge goes along a line"}
	var length := absi(d.x) + absi(d.z)
	var n := length - 1
	if n < 1:
		return {"ok": false, "why": "too short: there is no gap"}
	var out := {"ok": false, "why": "", "count": n, "ys": layers(a_cell.y, b_cell.y, n)}
	if n > MAX_LENGTH:
		out.why = "longer than %d blocks" % MAX_LENGTH
		return out
	if absi(b_cell.y - a_cell.y) > n + 1:
		out.why = "too steep"
		return out
	var along := Vector3i(signi(d.x), 0, signi(d.z))
	var across := Vector3i(along.z, 0, along.x) * lane_side
	# the standing cells at the ends: the first lane exactly, the second one at a step up or down
	if not nav.standable(a_cell) or not nav.standable(b_cell):
		out.why = "it has to stand on ground at both ends"
		return out
	for e in [a_cell, b_cell]:
		var lane2: Vector3i = nav.standable_in_column(e.x + across.x, e.z + across.z, e.y, 1, 1)
		if lane2.x < 0:
			out.why = "the second lane has no ground at the end"
			return out
	var ys_arr: PackedInt32Array = out.ys
	for i in n:
		for lane in 2:
			var col := a_cell + along * (i + 1) + across * lane
			for dy in [-1, 0, 1]:
				var c := Vector3i(col.x, ys_arr[i] + dy, col.z)
				if not world.in_bounds(c) or nav.blocked(c):
					out.why = "something is in the way (the bridge needs a gap: one block under it, two over it)"
					return out
				for o in others:
					if o.covers(c):
						out.why = "overlaps another plan"
						return out
	out.ok = true
	return out


## The feet cell of the piece i (1..n) when the ends stand at ya and yb.
static func layers(ya: int, yb: int, n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(1, n + 1):
		out.append(int(floorf(ya + float(yb - ya) * i / (n + 1) + 0.5)))
	return out


## Plans the bridge (after `check` said it can be built).
func setup_bridge(bricks: BrickWorld, a_cell: Vector3i, b_cell: Vector3i, lane_side: int, feet: PackedInt32Array, quiet := false) -> void:
	_bricks = bricks
	a = a_cell
	b = b_cell
	side = lane_side
	var d := b - a
	axis = 0 if d.x != 0 else 1
	dir = signi(d.x) if axis == 0 else signi(d.z)
	count = feet.size()
	ys = feet
	origin = a
	size = Vector2i(1, 1)
	kind_type = "bridge"
	title = "Rope bridge"
	cost = {Resources.Kind.PLANK: count + BASE_PLANKS}   # two for the bridge, a plank for every piece
	name = "Bridge_%d_%d" % [a.x, a.z]
	_claims.clear()
	var along := _along()
	var across := _across()
	for e in [a, b]:
		for lane in 2:
			_claims[e + across * lane] = true
	for i in count:
		for lane in 2:
			var col := a + along * (i + 1) + across * lane
			for dy in [-1, 0, 1]:
				_claims[Vector3i(col.x, ys[i] + dy, col.z)] = true
	if quiet:
		return
	_label = Label3D.new()
	_label.font_size = 22
	_label.pixel_size = 0.0045
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.outline_size = 8
	_label.position = plan_box().get_center() + Vector3(0.0, 1.6, 0.0)
	add_child(_label)
	_refresh()
	_rebuild()


## The aim before the plan is made: the same shape, blue if it can be built and red if not, on a node that is kept and moved.
func show_preview(bricks: BrickWorld, a_cell: Vector3i, b_cell: Vector3i, lane_side: int, feet: PackedInt32Array, ok: bool) -> void:
	setup_bridge(bricks, a_cell, b_cell, lane_side, feet, true)
	placed = 0
	_rebuild()
	tint(ok)


func _along() -> Vector3i:
	return Vector3i(dir, 0, 0) if axis == 0 else Vector3i(0, 0, dir)


func _across() -> Vector3i:
	return (Vector3i(0, 0, side) if axis == 0 else Vector3i(side, 0, 0))


func covers(c: Vector3i) -> bool:
	return _claims.has(c)


func plan_box() -> AABB:
	var lo := Vector3(1.0e9, 1.0e9, 1.0e9)
	var hi := Vector3(-1.0e9, -1.0e9, -1.0e9)
	for c: Vector3i in _claims:
		lo = lo.min(Vector3(c))
		hi = hi.max(Vector3(c) + Vector3.ONE)
	return AABB(lo, hi - lo)


func center() -> Vector3:
	return plan_box().get_center()


# --- laying -------------------------------------------------------------------------------------------------

## The piece (0-based, in the order they are laid) is the cell number `i` (1..count) from a.
func _cell_index(piece: int) -> int:
	return piece + 1 if from_end == 0 else count - piece


## A unit is coming from `from`: the bridge is laid from the end that is nearer to it (once, with the first claim).
func note_builder(from: Vector3i) -> void:
	if from_end < 0 and placed == 0:
		from_end = 0 if Vector2(from.x - a.x, from.z - a.z).length() <= Vector2(from.x - b.x, from.z - b.z).length() else 1


## Cells to stand in to lay the next piece: next to it, on the end that is already laid (the end of the bridge for the first piece).
func access_cells(nav: Navigation) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if from_end < 0:
		from_end = 0   # (nobody has asked yet: from a)
	var along := _along() * (1 if from_end == 0 else -1)
	var across := _across()
	for lane in 2:
		var c: Vector3i
		if placed == 0:
			c = (a if from_end == 0 else b) + across * lane
			var s := nav.standable_in_column(c.x, c.z, c.y, 1, 1)
			if s.x >= 0:
				out.append(s)
		else:
			var prev := _cell_index(placed - 1)
			c = a + _along() * prev + across * lane
			c.y = ys[prev - 1]
			if nav.standable(c):
				out.append(c)
	return out


func perform_work(unit: Unit, brd: TaskBoard) -> void:
	if placed < count:
		var price := 1 + (BASE_PLANKS if placed == 0 else 0)   # the first piece pays for the bridge itself too
		if unit == null or unit.carried_kind() != Resources.Kind.PLANK or unit.carried_amount() < price:
			return   # not enough planks in the hands to pay for it: they are fetched, nothing is laid
		lay_next()
		unit.carry(Resources.Kind.PLANK if unit.carried_amount() > price else Resources.Kind.NONE, unit.carried_amount() - price)
		delivered[Resources.Kind.PLANK] = delivered.get(Resources.Kind.PLANK, 0) + price
		_refresh()
	if placed >= count:
		brd.finish_blueprint(self)


## Lays the next piece: its planks become a floor, and the posts and ropes stand with the first one.
func lay_next() -> void:
	var i := _cell_index(placed)
	var y := ys[i - 1]
	for lane in 2:
		_bricks.add_deck(Vector3i(a.x, 0, a.z) + _along() * i + _across() * lane + Vector3i(0, y - 1, 0), self)
	placed += 1
	_rebuild()
	_refresh()


## The bridge is done: no more plan.
func complete() -> void:
	finished = true
	done = true
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
	if _label != null:
		_label.queue_free()
		_label = null
	_rebuild()


## Taken away as a plan: the planks that were laid go with it.
func discard() -> void:
	if _bricks != null:
		_bricks.remove_decks_of(self)


# --- the arc -------------------------------------------------------------------------------------------------

## Height of the feet over the bridge at a point (wx, wz) in the world: the straight line between the ends less the sag.
func deck_height(wx: float, wz: float) -> float:
	var span := float(count + 1)
	var u := clampf(((wx - (a.x + 0.5)) if axis == 0 else (wz - (a.z + 0.5))) * dir / span, 0.0, 1.0)
	return a.y + float(b.y - a.y) * u - sag(u)


## How far the deck hangs below the line at a place u (0..1) along it: a parabola that leaves the ends at ARC.
func sag(u: float) -> float:
	return float(count + 1) * tan(ARC) * 0.25 * 4.0 * u * (1.0 - u)


func _point(u_cells: float, lateral: float, lift: float) -> Vector3:
	# u_cells: blocks from the middle of the a cell along the bridge; lateral: across, from the middle line of the two lanes
	var ac := Vector3(a.x + 0.5, 0.0, a.z + 0.5)
	var along := Vector3(_along())
	var across := Vector3(_across())
	var p := ac + along * u_cells + across * (0.5 + lateral)
	p.y = deck_height(p.x, p.z) + lift
	return p


# --- how it looks ----------------------------------------------------------------------------------------------

func _rebuild() -> void:
	if _ghost == null and not finished:
		_ghost = MeshInstance3D.new()
		add_child(_ghost)
		_ghost.material_override = _ghost_mat(Color(0.35, 0.65, 1.0, 0.45))
	if _built == null:
		_built = MeshInstance3D.new()
		add_child(_built)
		_built.material_override = Props.material(true)
	var laid := {}
	for k in placed:
		laid[_cell_index(k)] = true
	var fixed := SurfaceTool.new()
	fixed.begin(Mesh.PRIMITIVE_TRIANGLES)
	var plan := SurfaceTool.new()
	plan.begin(Mesh.PRIMITIVE_TRIANGLES)
	var posts_stand := placed > 0 or finished
	_posts_and_ropes(fixed if posts_stand else plan)
	for i in range(1, count + 1):
		_plank(fixed if laid.has(i) else plan, i)
	_built.mesh = fixed.commit()
	if _ghost != null:
		_ghost.mesh = plan.commit()


func _ghost_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = c
	_ghost_material = m
	return m


## The aim: blue where it can be built, red where not.
func tint(ok: bool) -> void:
	if _ghost_material != null:
		_ghost_material.albedo_color = Color(0.3, 0.6, 1.0, 0.5) if ok else Color(0.95, 0.25, 0.2, 0.5)


func _plank(st: SurfaceTool, i: int) -> void:
	var u0 := float(i) - 0.5
	var p0 := _point(u0, 0.0, -0.06)
	var p1 := _point(u0 + 1.0, 0.0, -0.06)
	var mid := (p0 + p1) * 0.5
	var along := (p1 - p0).normalized()
	var across := Vector3(_across()).normalized()
	var up := along.cross(across).normalized() * (1.0 if along.cross(across).y > 0.0 else -1.0)
	var basis := Basis(along, up, across)
	_box(st, mid, basis, Vector3(0.46, 0.06, 0.96), WOOD if i % 2 == 0 else WOOD.darkened(0.08))


func _posts_and_ropes(st: SurfaceTool) -> void:
	var length := float(count) + 1.0
	for end in 2:
		for lat in [-0.92, 0.92]:
			var u := 0.18 if end == 0 else length - 0.18
			var base := _point(u, lat, 0.0)
			if end == 0:
				base.y = a.y
			else:
				base.y = b.y
			_prism(st, base, 0.2, 0.95, WOOD_DARK)
			for h in [0.25, 0.42, 0.59]:
				_prism(st, base + Vector3(0.0, h, 0.0), 0.245, 0.09, ROPE)
	# a rope along each side, a little over the planks: from post to post, hanging with the deck
	for lat in [-0.92, 0.92]:
		var prev := _point(0.18, lat, 0.38)
		prev.y = a.y + 0.38
		for k in range(1, count + 2):
			var u := minf(float(k), length - 0.18)
			var p := _point(u, lat, 0.12)
			if k == count + 1:
				p.y = b.y + 0.38
			_rope(st, prev, p)
			prev = p


func _rope(st: SurfaceTool, p: Vector3, q: Vector3) -> void:
	var dir_v := q - p
	var len := dir_v.length()
	if len < 0.001:
		return
	var along := dir_v / len
	var any := Vector3.UP if absf(along.y) < 0.9 else Vector3.RIGHT
	var side_v := along.cross(any).normalized()
	_box(st, (p + q) * 0.5, Basis(along, along.cross(side_v).normalized(), side_v), Vector3(len * 0.5, 0.035, 0.035), ROPE)


func _box(st: SurfaceTool, c: Vector3, basis: Basis, half: Vector3, col: Color) -> void:
	var ax := basis.x * half.x
	var ay := basis.y * half.y
	var az := basis.z * half.z
	var faces := [
		[ax, ay, az], [-ax, ay, -az], [ay, az, ax], [-ay, az, -ax], [az, ax, ay], [-az, ax, -ay],
	]
	for f in faces:
		var n: Vector3 = f[0].normalized()
		var o: Vector3 = c + f[0]
		# (Godot's front faces are clockwise seen from outside: the corners go round the other way than they are listed)
		_quad(st, o - f[1] + f[2], o + f[1] + f[2], o + f[1] - f[2], o - f[1] - f[2], n, col)


func _prism(st: SurfaceTool, base: Vector3, radius: float, height: float, col: Color) -> void:
	var sides := 8
	for k in sides:
		var a0 := TAU * k / sides
		var a1 := TAU * (k + 1) / sides
		var p0 := base + Vector3(cos(a0), 0.0, sin(a0)) * radius
		var p1 := base + Vector3(cos(a1), 0.0, sin(a1)) * radius
		var n := Vector3(cos((a0 + a1) * 0.5), 0.0, sin((a0 + a1) * 0.5))
		_quad(st, p0, p1, p1 + Vector3(0.0, height, 0.0), p0 + Vector3(0.0, height, 0.0), n, col)
		var top := base + Vector3(0.0, height, 0.0)
		for v in [top, top + Vector3(cos(a1), 0.0, sin(a1)) * radius, top + Vector3(cos(a0), 0.0, sin(a0)) * radius]:
			st.set_color(col)
			st.set_normal(Vector3.UP)
			st.add_vertex(v)


func _quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, col: Color) -> void:
	for v in [p0, p1, p2, p0, p2, p3]:
		st.set_color(col)
		st.set_normal(n)
		st.add_vertex(v)
