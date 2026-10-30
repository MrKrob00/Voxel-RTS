class_name DayCycle
extends Node
## The time of day, and the light that goes with it. The ground, the water and the props are drawn by shaders/toon_world*.gdshader,
## which light them by hand from four colours (the sun's direction and colour, the sky and the ground ambient) kept in ONE small
## texture (res://shaders/day_light.tres): no Godot light is involved there, and a day costs one 4-texel upload per change. Every
## material, the baked ones too, points to that one file. The units, logs and bricks are ordinary materials; the one DirectionalLight3D
## and the environment follow the same sun so that they match.

const LIGHT_FILE := "res://shaders/day_light.tres"
const LIGHT_DEFAULT: Array[Color] = [Color(0.4, -0.8, 0.4), Color(1, 1, 1), Color(0.5, 0.55, 0.65), Color(0.3, 0.3, 0.3)]   ## texels: sun direction, sun, sky, ground
const AZIMUTH := deg_to_rad(-35.0)
const NOON_ELEVATION := deg_to_rad(62.0)
const SUN_NOON := Color(1.0, 0.96, 0.88)
const SUN_LOW := Color(1.0, 0.58, 0.32)
const MOON := Color(0.34, 0.42, 0.7)
const SKY_AMB_DAY := Color(0.42, 0.47, 0.58)
const SKY_AMB_NIGHT := Color(0.19, 0.23, 0.4)
const GROUND_AMB_DAY := Color(0.26, 0.25, 0.22)
const GROUND_AMB_NIGHT := Color(0.09, 0.1, 0.17)
const SKY_DAY := Color("8fc8f0")
const SKY_DUSK := Color("e9946a")
const SKY_NIGHT := Color("0b1330")

## 0 is midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset.
@export var time_of_day := 0.4
## Real seconds a whole day lasts; 0 stops the clock.
@export var day_seconds := 300.0

## The light and the sky it moves (set in the scene: the DirectionalLight3D and the WorldEnvironment).
@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment
var environment: Environment
var _last_push := -1.0
var _last_text := ""

signal clock_changed(text: String)


static var _light_image: Image
static var _light_texture: ImageTexture


## The texture the shaders read the light of the day from (the same one for everything).
static func light_texture() -> ImageTexture:
	if _light_texture == null:
		_light_image = Image.create(4, 1, false, Image.FORMAT_RGBAF)
		for i in 4:
			_light_image.set_pixel(i, 0, LIGHT_DEFAULT[i])
		if ResourceLoader.exists(LIGHT_FILE):
			_light_texture = load(LIGHT_FILE) as ImageTexture
			_light_texture.update(_light_image)
		else:
			_light_texture = ImageTexture.create_from_image(_light_image)
	return _light_texture


## The material of the ground, the props and the water.
static func world_material(double_sided := false, water := false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	# the shader FILE itself, not a copy of its code: a baked map keeps pointing to the file, so a change of the shader reaches it
	m.shader = load("res://shaders/toon_water.gdshader" if water else ("res://shaders/toon_world_2s.gdshader" if double_sided else "res://shaders/toon_world.gdshader"))
	m.set_shader_parameter("day_light", light_texture())
	if water:
		m.set_shader_parameter("alpha", 0.62)
		m.set_shader_parameter("sparkle", 1.0)
		m.set_shader_parameter("pixel_size", 0.25)
		m.set_shader_parameter("pixel_noise", 0.02)
		m.render_priority = 1
	return m


## The material of the ground: the shader with its terrain part on.
static func terrain_material(size_blocks: Vector3i) -> ShaderMaterial:
	var m := world_material()
	m.set_shader_parameter("terrain", true)
	return m


func _ready() -> void:
	light_texture()
	if world_environment != null:
		environment = world_environment.environment
	_apply()


func _process(delta: float) -> void:
	if day_seconds > 0.0:
		time_of_day = fposmod(time_of_day + delta / day_seconds, 1.0)
	if absf(time_of_day - _last_push) > 0.0005:
		_apply()
	var text := hour_text()
	if text != _last_text:
		_last_text = text
		clock_changed.emit(text)


func hour_text() -> String:
	var minutes := int(time_of_day * 24.0 * 60.0)
	return "%02d:%02d" % [minutes / 60, minutes % 60]


## The unit vector towards whatever lights the ground now (the sun by day, the moon by night).
var light_to_sun := Vector3(0.4, 0.8, 0.4).normalized()


func _apply() -> void:
	_last_push = time_of_day
	var angle := -cos(time_of_day * TAU)            # -1 at midnight, +1 at noon
	var elevation := angle * NOON_ELEVATION
	var day := smoothstep(-0.08, 0.3, sin(elevation))   # how much of it is day
	var low := 1.0 - smoothstep(0.1, 0.55, sin(elevation))   # near the horizon: warm
	var to_sun := Vector3(cos(elevation) * sin(AZIMUTH), sin(elevation), cos(elevation) * cos(AZIMUTH))
	var moon_dir := Vector3(-0.3, 0.8, -0.5).normalized()
	var light_from := to_sun if elevation > 0.0 else moon_dir
	var sun_col := SUN_NOON.lerp(SUN_LOW, low).lerp(MOON, 1.0 - day)
	var strength := lerpf(0.35, 1.0, day)
	var sky_amb := SKY_AMB_NIGHT.lerp(SKY_AMB_DAY, day).lerp(SKY_AMB_DAY.lerp(SKY_DUSK, 0.35), low * day)
	var ground_amb := GROUND_AMB_NIGHT.lerp(GROUND_AMB_DAY, day)
	light_to_sun = light_from.normalized()
	light_texture()
	_push(0, -light_from.normalized())
	_push(1, Vector3(sun_col.r, sun_col.g, sun_col.b) * strength)
	_push(2, Vector3(sky_amb.r, sky_amb.g, sky_amb.b))
	_push(3, Vector3(ground_amb.r, ground_amb.g, ground_amb.b))
	_light_texture.update(_light_image)
	if sun != null:
		sun.basis = Basis.looking_at(-light_from.normalized(), Vector3.UP)
		sun.light_color = sun_col
		sun.light_energy = 0.7 * strength
	if environment != null:
		environment.background_color = SKY_NIGHT.lerp(SKY_DAY, day).lerp(SKY_DUSK, low * day * 0.7)
		environment.ambient_light_color = sky_amb.lerp(ground_amb, 0.3)
		environment.ambient_light_energy = 0.9


func _push(texel: int, v: Vector3) -> void:
	_light_image.set_pixel(texel, 0, Color(v.x, v.y, v.z, 1.0))
