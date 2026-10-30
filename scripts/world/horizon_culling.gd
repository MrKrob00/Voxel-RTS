class_name HorizonCulling
extends Node
## Chunks of ground that lie behind nearer ground are not drawn. The frustum alone cannot tell: with the camera low over the ground it
## takes in half the map in front of it, hill after hill, though most of it is hidden. This works out, from where the camera is, how
## high the ground rises in every direction (the horizon: for each way and each distance the steepest angle at which the ground in
## front of that distance is seen), and a chunk whose highest points all lie under that line is hidden.
##
## Made in a worker thread a few times a second (when the camera has moved a little), over the heights of the ground in squares of
## CELL x CELL blocks (the lowest column of each square: a ray that passes under the height of the square is sure to hit ground).
## Only the position of the camera matters, not where it looks. A result made for a place the camera has left by more than a few blocks
## is not used. Ground that overlaps other ground (a floating island over another) is not told apart: the camera is taken to be above all of it.

const CELL := 4                   ## blocks per square of the height map
const STEP := 4.0                 ## distance between the samples along a direction
const STEPS := 100                ## 400 blocks
const DIRECTIONS := 128
const MARGIN := 0.02              ## slope (about a degree) that a chunk has to be under the horizon by: for the little the camera moves meanwhile
const POLL := 0.2
const MOVED := 1.0                ## blocks the camera has to move for a new picture
const STALE := 4.0                ## blocks the camera may have moved while it was made

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
	_heights = out
	_have_heights = true


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
	if cam.distance_to(_last_cam) < MOVED and _dirty.is_empty():
		return
	_last_cam = cam
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
	_dirty = {}
	_last_cam = Vector3(INF, INF, INF)   # the picture is made again


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
		boxes.append(mi.position.y + box.end.y)   # the highest point of the chunk
	_busy = true
	_job_cam = cam
	_job_nodes = nodes
	WorkerThreadPool.add_task(_job.bind(cam, boxes))


func _job(cam: Vector3, boxes: PackedFloat32Array) -> void:
	var horizon := make_horizon(cam, _heights, _cw, _cd)
	var hidden := PackedByteArray()
	var count := boxes.size() / 5
	hidden.resize(count)
	for i in count:
		hidden[i] = 1 if chunk_hidden(cam, horizon, boxes[i * 5], boxes[i * 5 + 1], boxes[i * 5 + 2], boxes[i * 5 + 3], boxes[i * 5 + 4]) else 0
	_job_hidden = hidden
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


func _apply() -> void:
	if _camera == null or _camera.global_position.distance_to(_job_cam) > STALE:
		_last_cam = Vector3(INF, INF, INF)   # too late: made for another place
		return
	for i in _job_nodes.size():
		var mi: MeshInstance3D = _job_nodes[i]
		if is_instance_valid(mi):
			mi.visible = _job_hidden[i] == 0


func _show_all() -> void:
	_all_shown = true
	for child in _world.get_children():
		if child is MeshInstance3D:
			child.visible = true
