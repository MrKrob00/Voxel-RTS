class_name DayCycle
extends Node
## The time of day, and the light that goes with it. The ground, the water and the props are drawn by shaders/toon_world.gdshader,
## which lights them by hand from four global parameters (the sun's direction and colour, the sky and the ground ambient): no Godot
## light is involved there, so a day costs a handful of `global_shader_parameter_set` calls per frame. The units, logs and bricks
## are ordinary materials; the one DirectionalLight3D and the environment follow the same sun so that they match.

const GLOBALS := {
	"sun_direction": Vector3(0.4, -0.8, 0.4),
	"sun_color": Vector3(1, 1, 1),
	"sky_ambient": Vector3(0.5, 0.55, 0.65),
	"ground_ambient": Vector3(0.3, 0.3, 0.3),
}
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


static var _globals_added := false


static func ensure_globals() -> void:
	if _globals_added:
		return
	_globals_added = true
	for k in GLOBALS:
		if ProjectSettings.has_setting("shader_globals/" + k):
			continue   # declared in the project settings (so the editor knows them too)
		RenderingServer.global_shader_parameter_add(k, RenderingServer.GLOBAL_VAR_TYPE_VEC3, GLOBALS[k])


## The material of the ground, the props and the water.
static func world_material(double_sided := false, water := false) -> ShaderMaterial:
	ensure_globals()
	var code := (load("res://shaders/toon_world.gdshader") as Shader).code
	if double_sided:
		code = code.replace("cull_back", "cull_disabled")
	if not water:
		code = code.replace("	ALPHA = alpha * COLOR.a;\n", "")   # writing ALPHA would make it a transparent (slower) material
	var shader := Shader.new()
	shader.code = code
	var m := ShaderMaterial.new()
	m.shader = shader
	if water:
		m.set_shader_parameter("alpha", 0.62)
		m.set_shader_parameter("sparkle", 1.0)
		m.set_shader_parameter("pixel_size", 0.25)
		m.set_shader_parameter("pixel_noise", 0.02)
		m.render_priority = 1
	return m


## The material of the ground: the shader with its terrain part on and the texture of the grass blobs of a map of this size.
static func terrain_material(size_blocks: Vector3i) -> ShaderMaterial:
	var m := world_material()
	m.set_shader_parameter("terrain", true)
	m.set_shader_parameter("blob_tex", blob_texture(size_blocks))
	m.set_shader_parameter("blob_size", Vector2(size_blocks.x, size_blocks.z))
	return m


static var _blob_textures := {}


## MapPreset.blob (both of the blobs that colour the grass) at the middle of every square of BLOB_CELL blocks of the map: R the first,
## G the second. The shader reads it instead of working the sines out for each pixel.
static func blob_texture(size_blocks: Vector3i) -> ImageTexture:
	var key := Vector2i(size_blocks.x, size_blocks.z)
	if _blob_textures.has(key):
		return _blob_textures[key]
	var cell := 4
	var w := maxi(size_blocks.x / cell, 1)
	var h := maxi(size_blocks.z / cell, 1)
	var img := Image.create(w, h, false, Image.FORMAT_RG8)
	for j in h:
		for i in w:
			var x := (i + 0.5) * size_blocks.x / w
			var z := (j + 0.5) * size_blocks.z / h
			img.set_pixel(i, j, Color(MapPreset.blob(x, z, 1.0), MapPreset.blob(x - 90.0, z + 55.0, 0.55), 0.0))
	var tex := ImageTexture.create_from_image(img)
	_blob_textures[key] = tex
	return tex


func _ready() -> void:
	ensure_globals()
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
	_push("sun_direction", -light_from.normalized())
	_push("sun_color", Vector3(sun_col.r, sun_col.g, sun_col.b) * strength)
	_push("sky_ambient", Vector3(sky_amb.r, sky_amb.g, sky_amb.b))
	_push("ground_ambient", Vector3(ground_amb.r, ground_amb.g, ground_amb.b))
	if sun != null:
		sun.basis = Basis.looking_at(-light_from.normalized(), Vector3.UP)
		sun.light_color = sun_col
		sun.light_energy = 0.7 * strength
	if environment != null:
		environment.background_color = SKY_NIGHT.lerp(SKY_DAY, day).lerp(SKY_DUSK, low * day * 0.7)
		environment.ambient_light_color = sky_amb.lerp(ground_amb, 0.3)
		environment.ambient_light_energy = 0.9


func _push(key: String, v: Vector3) -> void:
	RenderingServer.global_shader_parameter_set(key, v)
