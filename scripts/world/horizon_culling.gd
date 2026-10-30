class_name HorizonCulling
extends Node
## Chunks of ground that lie behind nearer ground, or whose ground lies outside the picture, are not drawn. The frustum alone cannot tell: with the camera low over the ground it
## takes in half the map in front of it, hill after hill, though most of it is hidden. This works out, from where the camera is, how
## high the ground rises in every direction (the horizon: for each way and each distance the steepest angle at which the ground in
## front of that distance is seen), and a chunk whose highest points all lie under that line is hidden.
##
## Made in a worker thread a few times a second (when the camera has moved a little), over the heights of the ground in squares of
## CELL x CELL blocks (the lowest column of each square: a ray that passes under the height of the square is sure to hit ground).
## The picture is cut by a test of its own, tighter than the engine's: the engine takes the box of the whole mesh of a chunk (which reaches
## down into the cliffs under the ground), so with the camera looking down at the plain, chunks whose ground lies above the top edge of the
## picture still count as in it. Here a chunk is the part of its mesh between the lowest and the highest ground of its columns, as LiteTerrain
## does with the height range of its nodes (`_y_lo`, `_y_hi`).
## Only the position of the camera matters for what hides behind a hill (the picture also depends on where it looks). A result made for a place the camera has left by more than a few blocks
## is not used. Ground that overlaps other ground (a floating island over another) is not told apart: the camera is taken to be above all of it.

const CELL := 4                   ## blocks per square of the height map
const STEP := 4.0                 ## distance between the samples along a direction
const STEPS := 100                ## 400 blocks
const DIRECTIONS := 128
const MARGIN := 0.02              ## slope (about a degree) that a chunk has to be under the horizon by: for the little the camera moves meanwhile
const POLL := 0.2
const MOVED := 1.0                ## blocks the camera has to move for a new picture
const STALE := 4.0                ## blocks the camera may have moved while it was made
const FRUSTUM_MARGIN := 20.0      ## blocks outside the picture that still count as in it (the camera turns while the answer is made)
const TURNED := 0.99              ## the camera has turned (dot of its backwards direction with the old one) for a new picture

var enabled := true
var _world: VoxelWorld
var _camera: Camera3D
var _cw := 0                      # width and depth of the height map in squares
var _cd := 0
var _heights := PackedFloat32Array()   # the lowest top (y + 1) of the columns of each square; 0 where there is no ground
var _have_heights := false
var _dirty := {}                  # squares to take again: index -> true
var _poll := 0.0
var _all_shown := true
var _hidden_count := 0
var _outside_count := 0
var _cell_lo := PackedFloat32Array()   # per square of the height map: the lowest ground in it and one column round it (cliffs reach down to it)
var _cell_hi := PackedFloat32Array()   # and the highest ground in it
var _last_back := Vector3.BACK
var _job_back := Vector3.BACK
var _job_outside := PackedByteArray()
var _last_cam := Vector3(INF, INF, INF)
var _busy := false
var _job_done := false
var _job_cam := Vector3.ZERO
var _job_nodes: Array = []
var _job_hidden := PackedByteArray()


func setup(world: VoxelWorld, camera: Camera3D) -> void:
	_world = world
	_camera = camera
	var size := world.size_blocks()
	_cw = size.x / CELL
	_cd = size.z / CELL
	world.generation_finished.connect(_build_heights, CONNECT_ONE_SHOT)
	world.block_changed.connect(_on_block_changed)


func _build_heights() -> void:
	WorkerThreadPool.add_task(_heights_job)


func _heights_job() -> void:
	var size := _world.size_blocks()
	var tops := PackedInt32Array()
	tops.resize(size.x * size.z)
	_world.fill_column_tops(tops)
	var out := PackedFloat32Array()
	out.resize(_cw * _cd)
	for cz in _cd:
		for cx in _cw:
			var low := 100000
			for dz in CELL:
				for dx in CELL:
					low = mini(low, tops[(cx * CELL + dx) + (cz * CELL + dz) * size.x])
			out[cx + cz * _cw] = float(low)
	var lo_a := PackedFloat32Array()
	var hi_a := PackedFloat32Array()
	lo_a.resize(_cw * _cd)
	hi_a.resize(_cw * _cd)
	for cz in _cd:
		for cx in _cw:
			var r := cell_range(tops, size.x, size.z, cx, cz)
			lo_a[cx + cz * _cw] = r.x
			hi_a[cx + cz * _cw] = r.y
	_cell_lo = lo_a
	_cell_hi = hi_a
	_heights = out
	_have_heights = true


## (lowest ground in the square and one column round it, highest ground in it) in blocks, from the tops of the columns.
static func cell_range(tops: PackedInt32Array, width: int, depth: int, cx: int, cz: int) -> Vector2:
	var lo := 100000
	var hi := 0
	for z in range(cz * CELL - 1, cz * CELL + CELL + 1):
		for x in range(cx * CELL - 1, cx * CELL + CELL + 1):
			var t := tops[clampi(x, 0, width - 1) + clampi(z, 0, depth - 1) * width]
			lo = mini(lo, t)
			if x >= cx * CELL and x < cx * CELL + CELL and z >= cz * CELL and z < cz * CELL + CELL:
				hi = maxi(hi, t)
	return Vector2(float(lo), float(hi))


func _on_block_changed(p: Vector3i) -> void:
	if _have_heights:
		_dirty[(p.x / CELL) + (p.z / CELL) * _cw] = true


func _process(delta: float) -> void:
	if _job_done:
		_job_done = false
		_busy = false
		_apply()
	_poll -= delta
	if _poll > 0.0 or _busy or not _have_heights or _camera == null:
		return
	_poll = POLL
	if not enabled:
		_show_all()
		return
	_retake_dirty()
	var cam := _camera.global_position
	# Over open sky, or under the ground of another island, the ground cannot be taken as lying below the camera: nothing is hidden.
	var cx := clampi(int(cam.x / CELL), 0, _cw - 1)
	var cz := clampi(int(cam.z / CELL), 0, _cd - 1)
	var under := _heights[cx + cz * _cw]
	if under <= 0.0 or cam.y < under:
		if not _all_shown:
			_show_all()
		_last_cam = Vector3(INF, INF, INF)
		return
	_all_shown = false
	var back := _camera.global_transform.basis.z
	if cam.distance_to(_last_cam) < MOVED and _dirty.is_empty() and back.dot(_last_back) > TURNED:
		return
	_last_cam = cam
	_last_back = back
	_start(cam)


func _retake_dirty() -> void:
	if _dirty.is_empty():
		return
	for idx: int in _dirty.keys():
		var cx := idx % _cw
		var cz := idx / _cw
		var low := 100000
		for dz in CELL:
			for dx in CELL:
				low = mini(low, _world.surface_y(cx * CELL + dx, cz * CELL + dz) + 1)
		_heights[idx] = float(low)
	for idx: int in _dirty.keys():
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				_retake_range((idx % _cw) + dx, (idx / _cw) + dz)
	_dirty = {}
	_last_cam = Vector3(INF, INF, INF)   # the picture is made again


func _retake_range(cx: int, cz: int) -> void:
	if cx < 0 or cz < 0 or cx >= _cw or cz >= _cd:
		return
	var size := _world.size_blocks()
	var lo := 100000.0
	var hi := 0.0
	for z in range(cz * CELL - 1, cz * CELL + CELL + 1):
		for x in range(cx * CELL - 1, cx * CELL + CELL + 1):
			var xx := clampi(x, 0, size.x - 1)
			var zz := clampi(z, 0, size.z - 1)
			var t := ceilf(float(_world.column_levels[xx + zz * size.x]) / Blocks.UNIT) if _world.column_levels_ready else float(_world.surface_y(xx, zz) + 1)
			lo = minf(lo, t)
			if x >= cx * CELL and x < cx * CELL + CELL and z >= cz * CELL and z < cz * CELL + CELL:
				hi = maxf(hi, t)
	_cell_lo[cx + cz * _cw] = lo
	_cell_hi[cx + cz * _cw] = hi


func _start(cam: Vector3) -> void:
	# the chunks that have a mesh: their node and the box of the mesh in the world
	var nodes: Array = []
	var boxes := PackedFloat32Array()
	for child in _world.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.name.begins_with("Chunk_"):
			continue
		var box := mi.mesh.get_aabb()
		nodes.append(mi)
		boxes.append(mi.position.x + box.position.x)
		boxes.append(mi.position.z + box.position.z)
		boxes.append(mi.position.x + box.end.x)
		boxes.append(mi.position.z + box.end.z)
		boxes.append(mi.position.y + box.end.y)        # the highest point of the chunk (for what hides behind a hill)
		boxes.append(mi.position.y + box.position.y)   # the lowest
	var planes := PackedFloat32Array()
	for pl: Plane in _camera.get_frustum():
		planes.append(pl.normal.x)
		planes.append(pl.normal.y)
		planes.append(pl.normal.z)
		planes.append(pl.d)
	_busy = true
	_job_cam = cam
	_job_back = _camera.global_transform.basis.z
	_job_nodes = nodes
	WorkerThreadPool.add_task(_job.bind(cam, boxes, planes))


func _job(cam: Vector3, boxes: PackedFloat32Array, planes: PackedFloat32Array) -> void:
	var horizon := make_horizon(cam, _heights, _cw, _cd)
	var hidden := PackedByteArray()
	var outside := PackedByteArray()
	var count := boxes.size() / 6
	hidden.resize(count)
	outside.resize(count)
	for i in count:
		var b := i * 6
		hidden[i] = 1 if chunk_hidden(cam, horizon, boxes[b], boxes[b + 1], boxes[b + 2], boxes[b + 3], boxes[b + 4]) else 0
		outside[i] = 1 if chunk_outside(planes, FRUSTUM_MARGIN, boxes[b], boxes[b + 1], boxes[b + 2], boxes[b + 3], boxes[b + 5], boxes[b + 4], _cell_lo, _cell_hi, _cw, _cd) else 0
	_job_hidden = hidden
	_job_outside = outside
	_job_done = true


## For every direction and every distance (STEPS samples of STEP blocks): the steepest slope, seen from `cam`, of the ground between the
## camera and that distance. `heights` is the height map in squares of CELL blocks, `cw` x `cd` of them.
static func make_horizon(cam: Vector3, heights: PackedFloat32Array, cw: int, cd: int) -> PackedFloat32Array:
	var horizon := PackedFloat32Array()
	horizon.resize(DIRECTIONS * STEPS)
	for a in DIRECTIONS:
		var dx := sin(TAU * a / DIRECTIONS)
		var dz := cos(TAU * a / DIRECTIONS)
		var best := -1.0e9
		for j in STEPS:
			var d := (j + 1) * STEP
			var lat := d * 0.025 + 2.0   # the ray of the direction may be a little to either side of the sampled one
			var low := 1.0e9
			for off: float in [-lat, 0.0, lat]:
				var x := cam.x + dx * d - dz * off
				var z := cam.z + dz * d + dx * off
				var cx := int(floorf(x / CELL))
				var cz := int(floorf(z / CELL))
				if cx < 0 or cz < 0 or cx >= cw or cz >= cd:
					low = -1.0e9   # off the map: nothing there to hide behind
					break
				low = minf(low, heights[cx + cz * cw])
			if low > -1.0e8:
				var num := low - cam.y
				var dist := d + 2.0 if num > 0.0 else maxf(d - 2.0, 2.0)
				best = maxf(best, num / dist)
			horizon[a * STEPS + j] = best
	return horizon


## Does the box (x0..x1, z0..z1, y_lo..y_hi) lie outside the picture, i.e. beyond one of the six planes (x, y, z of the normal and d, out)
## by more than `margin`?
static func outside_picture(planes: PackedFloat32Array, margin: float, x0: float, z0: float, x1: float, z1: float, y_lo: float, y_hi: float) -> bool:
	for k in range(0, planes.size(), 4):
		var nx := planes[k]
		var ny := planes[k + 1]
		var nz := planes[k + 2]
		# the corner of the box that lies furthest inside this plane
		var d := nx * (x0 if nx > 0.0 else x1) + ny * (y_lo if ny > 0.0 else y_hi) + nz * (z0 if nz > 0.0 else z1) - planes[k + 3]
		if d > margin:
			return true
	return false


## Is a chunk outside the picture? Its mesh (x0..x1, z0..z1, mesh_lo..mesh_hi) is taken square by square of the height map: in each only the
## part of the mesh between the ground that lies there (and the lowest ground next to it: the cliffs) and the highest is counted, and the
## chunk is out when every square is.
static func chunk_outside(planes: PackedFloat32Array, margin: float, x0: float, z0: float, x1: float, z1: float, mesh_lo: float, mesh_hi: float, cell_lo: PackedFloat32Array, cell_hi: PackedFloat32Array, cw: int, cd: int) -> bool:
	if cell_lo.is_empty():
		return outside_picture(planes, margin, x0, z0, x1, z1, mesh_lo, mesh_hi)
	var i0 := clampi(int(floorf(x0 / CELL)), 0, cw - 1)
	var i1 := clampi(int(ceilf(x1 / CELL)) - 1, 0, cw - 1)
	var j0 := clampi(int(floorf(z0 / CELL)), 0, cd - 1)
	var j1 := clampi(int(ceilf(z1 / CELL)) - 1, 0, cd - 1)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var lo := maxf(mesh_lo, cell_lo[i + j * cw])
			var hi := minf(mesh_hi, cell_hi[i + j * cw] + 1.0)
			if lo > hi:
				lo = mesh_lo   # the ground is not where the mesh is (a mesh of something that stands on it): the whole height
				hi = mesh_hi
			if not outside_picture(planes, margin, float(i * CELL), float(j * CELL), float(i * CELL + CELL), float(j * CELL + CELL), lo, hi):
				return false
	return true


## Is every point of the top of a chunk (x0..x1, z0..z1 at height top) under the line of the ground in front of it?
static func chunk_hidden(cam: Vector3, horizon: PackedFloat32Array, x0: float, z0: float, x1: float, z1: float, top: float) -> bool:
	var near_x := clampf(cam.x, x0, x1)
	var near_z := clampf(cam.z, z0, z1)
	var near := Vector2(near_x - cam.x, near_z - cam.z).length()
	if near < STEP * 2.0:
		return false   # the camera is over (or next to) it
	var k := clampi(int((near - 2.0) / STEP) - 1, 0, STEPS - 1)   # the samples whose squares lie before the chunk
	for iz in 3:
		for ix in 3:
			var px := lerpf(x0, x1, ix * 0.5)
			var pz := lerpf(z0, z1, iz * 0.5)
			var dx := px - cam.x
			var dz := pz - cam.z
			var dist := sqrt(dx * dx + dz * dz)
			var az := atan2(dx, dz)
			if az < 0.0:
				az += TAU
			var f := az / TAU * DIRECTIONS
			var a0 := int(f) % DIRECTIONS
			var a1 := (a0 + 1) % DIRECTIONS
			var limit := minf(horizon[a0 * STEPS + k], horizon[a1 * STEPS + k])
			if (top - cam.y) / dist + MARGIN >= limit:
				return false
	return true


func hidden_count() -> int:
	return _hidden_count


func outside_count() -> int:
	return _outside_count


func _apply() -> void:
	if _camera == null or _camera.global_position.distance_to(_job_cam) > STALE or _camera.global_transform.basis.z.dot(_job_back) < 0.97:
		_last_cam = Vector3(INF, INF, INF)   # too late: made for another place or another way of looking
		return
	_hidden_count = 0
	_outside_count = 0
	for i in _job_nodes.size():
		_hidden_count += _job_hidden[i]
		_outside_count += _job_outside[i]
		var mi: MeshInstance3D = _job_nodes[i]
		if is_instance_valid(mi):
			ChunkHide.set_hidden(mi, "horizon", _job_hidden[i] != 0)
			ChunkHide.set_hidden(mi, "picture", _job_outside[i] != 0)


func _show_all() -> void:
	_all_shown = true
	for child in _world.get_children():
		if child is MeshInstance3D:
			ChunkHide.set_hidden(child, "horizon", false)
			ChunkHide.set_hidden(child, "picture", false)
