class_name ReliefShadow
extends Node
## The shade that high ground throws on lower ground. A texture of the map, one texel per column of blocks (0 lit .. 1 in the shade),
## made from the heights of the columns and the height of the sun, in a worker thread; every ground material shows it (see the shader).
## It is made again when the sun has moved a degree and a moment after the ground was changed. Trees and buildings throw none.

const STEP_DEGREES := 1.0     ## the sun must have moved this much to make the shade again
const EDIT_PAUSE := 0.8       ## seconds after the last change of the ground
const SOFT := 0.9             ## how deep (blocks) under the shadow's edge the ground has to be to lie in the full shade

var _world: VoxelWorld
var _day: DayCycle
var _heights := PackedInt32Array()   # y + 1 of the highest solid block of every column (0: none), x + z * width
var _w := 0
var _d := 0
var _last_dir := Vector3.ZERO
var _busy := false
var _job_done := false
var _result := PackedByteArray()
var _poll := 0.0
var _edited_at := -1.0
var _have_heights := false


func setup(world: VoxelWorld, day: DayCycle) -> void:
	_world = world
	_day = day
	_w = world.size_blocks().x
	_d = world.size_blocks().z
	world.generation_finished.connect(func() -> void: _start(true), CONNECT_ONE_SHOT)
	world.block_changed.connect(_on_block_changed)


func _on_block_changed(p: Vector3i) -> void:
	if not _have_heights or p.x < 0 or p.z < 0 or p.x >= _w or p.z >= _d:
		return
	_heights[p.x + p.z * _w] = _column_top(p.x, p.z)
	_edited_at = Time.get_ticks_msec() / 1000.0


func _column_top(x: int, z: int) -> int:
	return _world.surface_y(x, z) + 1


func _process(delta: float) -> void:
	if _job_done:
		_job_done = false
		_busy = false
		var img := Image.create_from_data(_w, _d, false, Image.FORMAT_R8, _result)
		_world.relief_texture.update(img)
	_poll -= delta
	if _poll > 0.0 or _busy or not _have_heights:
		return
	_poll = 0.4
	var dir := _day.light_to_sun
	var now := Time.get_ticks_msec() / 1000.0
	var edited := _edited_at > 0.0 and now - _edited_at > EDIT_PAUSE
	if edited or dir.angle_to(_last_dir) > deg_to_rad(STEP_DEGREES):
		_edited_at = -1.0
		_start(false)


func _start(first: bool) -> void:
	_busy = true
	_last_dir = _day.light_to_sun
	WorkerThreadPool.add_task(_job.bind(_last_dir, first))


func _job(to_sun: Vector3, first: bool) -> void:
	if first:
		_heights.resize(_w * _d)
		_world.fill_column_tops(_heights)
		_have_heights = true
	_result = shade_map(_heights, _w, _d, to_sun)
	_job_done = true


## The shade (0..255) of every column for light that comes from `to_sun` (a unit vector towards the sun). A column is in the shade when
## the highest ray that grazes the ground nearer to the sun passes over it; the height of that ray is carried along from column to
## column, away from the sun (one pass over the map).
static func shade_map(heights: PackedInt32Array, w: int, d: int, to_sun: Vector3) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(w * d)
	var hl := Vector2(to_sun.x, to_sun.z).length()
	if to_sun.y <= 0.02 or hl < 0.001:
		return out   # the sun at the horizon or straight above: no shade to draw
	var t := Vector2(to_sun.x, to_sun.z) / hl
	var slope := to_sun.y / hl                      # blocks of height per block of distance
	var along_z := absf(t.y) >= absf(t.x)           # the rows of the pass are the columns of z (else of x)
	var rows := d if along_z else w
	var cols := w if along_z else d
	var sign_main := 1 if (t.y if along_z else t.x) > 0.0 else -1   # the way to the sun along the rows
	var main_abs := absf(t.y if along_z else t.x)
	var shift := (t.x if along_z else t.y) / main_abs   # how far the way to the sun leans sideways per row
	var dist := 1.0 / main_abs                      # the distance covered from row to row
	var drop := slope * dist
	var prev := PackedFloat32Array()
	prev.resize(cols)
	prev.fill(-1.0e9)
	var cur := PackedFloat32Array()
	cur.resize(cols)
	for step in rows:
		var row := (rows - 1 - step) if sign_main > 0 else step   # the rows nearest to the sun first
		for c in cols:
			var idx := (c + row * w) if along_z else (row + c * w)
			var h := float(heights[idx])
			var fx := float(c) + shift
			var i0 := floori(fx)
			var f := fx - i0
			var a: float = prev[clampi(i0, 0, cols - 1)]
			var b: float = prev[clampi(i0 + 1, 0, cols - 1)]
			var lower := lerpf(a, b, f) - drop
			if h > 0.0 and lower > h:
				out[idx] = int(clampf((lower - h) / SOFT, 0.0, 1.0) * 255.0)
			cur[c] = maxf(h, lower)
		var swap := prev
		prev = cur
		cur = swap
	return out
