class_name RTSCamera
extends Node3D
## RTS camera that works on mouse + keyboard and on touch.
##   Desktop: WASD / arrows pan, Q/E rotate, R/F tilt, wheel zoom, middle-drag rotate, edge scroll optional.
##   Touch:   one finger drags the map, two fingers pinch to zoom and twist to rotate.
## Game code never sees raw events, only these gestures (the same ones on every device):
##   primary_action    tap / left click that did not drag           select, or use the current tool
##   secondary_action  long press (no drag) / right click           command: move here, cancel
##   double_action     second tap close to the first                select every unit of that kind
##   box_changed/box_finished  left drag with the mouse, or long press and then drag with a finger: a selection rectangle
## One finger dragging (without the long press) pans the map; two fingers pinch to zoom and twist to rotate.

signal primary_action(screen_pos: Vector2)
signal secondary_action(screen_pos: Vector2)
signal double_action(screen_pos: Vector2)
signal box_changed(rect: Rect2)
signal box_finished(rect: Rect2)
signal box_cancelled

@export var min_distance := 8.0
@export var max_distance := 260.0
@export var pan_speed := 1.1          ## world units per second per unit of distance
@export var rotate_speed := 1.8       ## radians per second (keys)
@export var edge_scroll := false
@export var bounds := Rect2(0, 0, 256, 256)
@export var tap_max_move := 14.0
@export var tap_max_time := 0.35
@export var long_press_time := 0.45
@export var double_tap_time := 0.32
@export var box_min_size := 12.0

var yaw := deg_to_rad(35.0)
var pitch := deg_to_rad(52.0)
var distance := 55.0
var focus := Vector3(128, 48, 128)
## Optional: lets the camera glide along the ground (set by the game to world.surface_y).
var ground_height := Callable()

var camera: Camera3D
## Where the pointer is on screen: the mouse, or the last finger that touched. Game code reads this for hover, never the
## viewport's mouse position (on a touch screen that stays at the corner).
var pointer := Vector2.ZERO

var _touches := {}
var _tap_start := Vector2.ZERO
var _tap_time := 0.0
var _tap_valid := false
var _long_press := false          ## the finger has been down long enough: dragging now draws a selection box
var _box_active := false
var _box_start := Vector2.ZERO
var _mouse_down := false
var _mouse_start := Vector2.ZERO
var _last_tap_time := -10.0
var _last_tap_pos := Vector2(-1000, -1000)
var _clock := 0.0
var _prev_pinch_dist := 0.0
var _prev_pinch_angle := 0.0
var _prev_pinch_mid := Vector2.ZERO


func _ready() -> void:
	camera = Camera3D.new()
	camera.far = 1400.0
	camera.fov = 60.0
	add_child(camera)
	pointer = get_viewport().get_visible_rect().size * 0.5
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
	_clock += delta
	if _tap_valid:
		_tap_time += delta
		if not _long_press and _tap_time >= long_press_time and _touches.size() == 1:
			_long_press = true
			_box_start = _tap_start
			Input.vibrate_handheld(25)   # a short buzz on a phone or tablet: the box is armed
	if ground_height.is_valid():
		var gy: int = ground_height.call(int(focus.x), int(focus.z))
		if gy >= 0:
			focus.y = lerpf(focus.y, gy + 1.0, minf(1.0, delta * 6.0))
	_apply()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		pointer = mb.position
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_WHEEL_UP: _zoom(0.9)
				MOUSE_BUTTON_WHEEL_DOWN: _zoom(1.1)
				MOUSE_BUTTON_LEFT:
					_mouse_down = true
					_mouse_start = mb.position
				MOUSE_BUTTON_RIGHT: secondary_action.emit(mb.position)
		elif mb.button_index == MOUSE_BUTTON_LEFT and _mouse_down:
			_mouse_down = false
			if _box_active:
				_finish_box(mb.position)
			else:
				_tapped(mb.position)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		pointer = mm.position
		if _mouse_down and (_box_active or mm.position.distance_to(_mouse_start) > tap_max_move):
			_box_active = true
			_box_start = _mouse_start
			box_changed.emit(_rect_from(_box_start, mm.position))
		if mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			yaw -= mm.relative.x * 0.006
			pitch = clampf(pitch + mm.relative.y * 0.004, deg_to_rad(20), deg_to_rad(80))
	elif event is InputEventScreenTouch:
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_on_drag(event as InputEventScreenDrag)


func _on_touch(e: InputEventScreenTouch) -> void:
	pointer = e.position
	if e.pressed:
		_touches[e.index] = e.position
		if _touches.size() == 1:
			_tap_start = e.position
			_tap_time = 0.0
			_tap_valid = true
			_long_press = false
		else:
			_tap_valid = false
			_cancel_box()
			_reset_pinch()
	else:
		var was_single := _touches.size() == 1
		_touches.erase(e.index)
		if was_single and _box_active:
			_finish_box(e.position)
		elif was_single and _tap_valid and e.position.distance_to(_tap_start) <= tap_max_move:
			if _long_press:
				secondary_action.emit(e.position)   # a long press without dragging is the command (like a right click)
			elif _tap_time <= tap_max_time:
				_tapped(e.position)
		_tap_valid = false
		_long_press = false
		if _touches.size() == 2:
			_reset_pinch()


## A press and release in one place: a click or a tap. A second one close by and soon after is also a double tap.
func _tapped(pos: Vector2) -> void:
	primary_action.emit(pos)
	if _clock - _last_tap_time <= double_tap_time and pos.distance_to(_last_tap_pos) <= tap_max_move * 3.0:
		double_action.emit(pos)
		_last_tap_time = -10.0
	else:
		_last_tap_time = _clock
		_last_tap_pos = pos


static func _rect_from(a: Vector2, b: Vector2) -> Rect2:
	return Rect2(a, Vector2.ZERO).expand(b)


func _finish_box(end: Vector2) -> void:
	var rect := _rect_from(_box_start, end)
	_box_active = false
	if rect.size.x >= box_min_size or rect.size.y >= box_min_size:
		box_finished.emit(rect)
	else:
		box_cancelled.emit()


func _cancel_box() -> void:
	if _box_active:
		_box_active = false
		box_cancelled.emit()


func _on_drag(e: InputEventScreenDrag) -> void:
	if not _touches.has(e.index):
		return
	pointer = e.position
	_touches[e.index] = e.position
	if _touches.size() == 1:
		if _long_press and _tap_valid:
			# After the long press the finger draws a selection box instead of panning the map.
			if _box_active or e.position.distance_to(_tap_start) > tap_max_move:
				_box_active = true
				box_changed.emit(_rect_from(_box_start, e.position))
			return
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
