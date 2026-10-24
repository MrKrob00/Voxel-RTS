class_name RTSCamera
extends Node3D
## RTS camera that works on mouse + keyboard and on touch.
##   Desktop: WASD / arrows pan, Q/E rotate, R/F tilt, wheel zoom, middle-drag rotate, edge scroll optional.
##   Touch:   one finger drags the map, two fingers pinch to zoom and twist to rotate.
## A short, small press is reported as a tap/click through the signals so game code stays input-agnostic.

signal primary_action(screen_pos: Vector2)
signal secondary_action(screen_pos: Vector2)

@export var min_distance := 8.0
@export var max_distance := 140.0
@export var pan_speed := 1.1          ## world units per second per unit of distance
@export var rotate_speed := 1.8       ## radians per second (keys)
@export var edge_scroll := false
@export var bounds := Rect2(0, 0, 128, 128)
@export var tap_max_move := 14.0
@export var tap_max_time := 0.35

var yaw := deg_to_rad(35.0)
var pitch := deg_to_rad(52.0)
var distance := 55.0
var focus := Vector3(64, 24, 64)
## Optional: lets the camera glide along the ground (set by the game to world.surface_y).
var ground_height := Callable()

var camera: Camera3D

var _touches := {}
var _tap_start := Vector2.ZERO
var _tap_time := 0.0
var _tap_valid := false
var _prev_pinch_dist := 0.0
var _prev_pinch_angle := 0.0
var _prev_pinch_mid := Vector2.ZERO


func _ready() -> void:
	camera = Camera3D.new()
	camera.far = 600.0
	camera.fov = 60.0
	add_child(camera)
	_apply()


func _process(delta: float) -> void:
	var move := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		move.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		move.y += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		move.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		move.x += 1.0
	if edge_scroll and DisplayServer.window_is_focused():
		var vp := get_viewport()
		var m := vp.get_mouse_position()
		var s := vp.get_visible_rect().size
		if m.x >= 0 and m.y >= 0 and m.x <= s.x and m.y <= s.y:
			if m.x < 4: move.x -= 1.0
			if m.x > s.x - 5: move.x += 1.0
			if m.y < 4: move.y -= 1.0
			if m.y > s.y - 5: move.y += 1.0
	if move != Vector2.ZERO:
		var speed := pan_speed * distance * delta
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= 2.5
		_pan_world(move.normalized() * speed)
	if Input.is_key_pressed(KEY_Q):
		yaw += rotate_speed * delta
	if Input.is_key_pressed(KEY_E):
		yaw -= rotate_speed * delta
	if Input.is_key_pressed(KEY_R):
		pitch = clampf(pitch + delta, deg_to_rad(20), deg_to_rad(80))
	if Input.is_key_pressed(KEY_F):
		pitch = clampf(pitch - delta, deg_to_rad(20), deg_to_rad(80))
	if _tap_valid:
		_tap_time += delta
	if ground_height.is_valid():
		var gy: int = ground_height.call(int(focus.x), int(focus.z))
		if gy >= 0:
			focus.y = lerpf(focus.y, gy + 1.0, minf(1.0, delta * 6.0))
	_apply()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_WHEEL_UP: _zoom(0.9)
				MOUSE_BUTTON_WHEEL_DOWN: _zoom(1.1)
				MOUSE_BUTTON_LEFT: primary_action.emit(mb.position)
				MOUSE_BUTTON_RIGHT: secondary_action.emit(mb.position)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			yaw -= mm.relative.x * 0.006
			pitch = clampf(pitch + mm.relative.y * 0.004, deg_to_rad(20), deg_to_rad(80))
	elif event is InputEventScreenTouch:
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_on_drag(event as InputEventScreenDrag)


func _on_touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		_touches[e.index] = e.position
		if _touches.size() == 1:
			_tap_start = e.position
			_tap_time = 0.0
			_tap_valid = true
		else:
			_tap_valid = false
			_reset_pinch()
	else:
		var was_single := _touches.size() == 1
		_touches.erase(e.index)
		if was_single and _tap_valid and _tap_time <= tap_max_time and e.position.distance_to(_tap_start) <= tap_max_move:
			primary_action.emit(e.position)
		_tap_valid = false
		if _touches.size() == 2:
			_reset_pinch()


func _on_drag(e: InputEventScreenDrag) -> void:
	if not _touches.has(e.index):
		return
	_touches[e.index] = e.position
	if _touches.size() == 1:
		if _tap_valid and e.position.distance_to(_tap_start) > tap_max_move:
			_tap_valid = false
		if not _tap_valid:
			_pan_world(Vector2(-e.relative.x, -e.relative.y) * distance * 0.0016)
	elif _touches.size() == 2:
		var pts: Array = _touches.values()
		var a: Vector2 = pts[0]
		var b: Vector2 = pts[1]
		var d := a.distance_to(b)
		var ang := (b - a).angle()
		var mid := (a + b) * 0.5
		if _prev_pinch_dist > 1.0:
			_zoom(_prev_pinch_dist / maxf(d, 1.0))
			yaw -= angle_difference(_prev_pinch_angle, ang)
			_pan_world((_prev_pinch_mid - mid) * distance * 0.0016)
		_prev_pinch_dist = d
		_prev_pinch_angle = ang
		_prev_pinch_mid = mid


func _reset_pinch() -> void:
	_prev_pinch_dist = 0.0
	if _touches.size() == 2:
		var pts: Array = _touches.values()
		var a: Vector2 = pts[0]
		var b: Vector2 = pts[1]
		_prev_pinch_dist = a.distance_to(b)
		_prev_pinch_angle = (b - a).angle()
		_prev_pinch_mid = (a + b) * 0.5


func _zoom(factor: float) -> void:
	distance = clampf(distance * factor, min_distance, max_distance)


## Pan on the ground plane; `v.x` is screen-right, `v.y` is screen-down (towards the viewer).
func _pan_world(v: Vector2) -> void:
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var back := Vector3(sin(yaw), 0, cos(yaw))
	focus += right * v.x + back * v.y
	focus.x = clampf(focus.x, bounds.position.x, bounds.end.x)
	focus.z = clampf(focus.z, bounds.position.y, bounds.end.y)


func _apply() -> void:
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
	position = focus + offset
	look_at(focus, Vector3.UP)
	# Camera3D is a child at identity; the rig itself does the orbiting.
