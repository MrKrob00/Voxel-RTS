class_name FrameProbe
extends Node
## WHAT A FRAME COSTS ON THE DEVICE, LAYER BY LAYER (the HUD's Probe button; the way TerraTest's profiler did it). A phone's GPU gives no
## timestamps in the Compatibility renderer, and a desktop's pixels say little about a phone's, so the device measures itself: each layer
## of the picture is switched OFF for WINDOW seconds between two windows with it ON, and the cost of the layer is the mean frame time
## with it off against the mean of the two ons round it. The table goes to the HUD and to the clipboard. A switch writes the field the game
## owns and puts the saved value back; every node is asked `is_instance_valid` after each wait. The sync to the screen's refresh is
## switched off for the run (a frame that waits for the screen costs nothing to see), and put back after it.

signal finished(text: String)

const SETTLE := 0.6               ## seconds after a switch before a window is counted
const WINDOW := 2.5
const ROUNDS := 2                 ## each layer is switched off this many times and the costs averaged

var status := ""
var _main: Node
var _lines: Array[String] = []


func run(main: Node) -> void:
	_main = main
	_lines.clear()
	var vsync := DisplayServer.window_get_vsync_mode()
	var max_fps := Engine.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_lines.append("PROBE  %s  %s" % [Time.get_datetime_string_from_system(), RenderingServer.get_video_adapter_name()])
	var base: float = await _measure()
	_lines.append("base %.1f ms (%d fps)%s" % [base, int(1000.0 / maxf(base, 0.1)), "   (the screen's refresh may still cap it)" if base < 16.9 else ""])
	for c in _cases():
		var nm: String = c[0]
		var flip: Callable = c[1]
		var cost := 0.0
		var offs := 0.0
		var on := base
		for r in ROUNDS:
			status = "probe: %s off (%d/%d)" % [nm, r + 1, ROUNDS]
			var saved: Variant = flip.call(true, null)
			var off: float = await _measure()
			flip.call(false, saved)
			status = "probe: %s on (%d/%d)" % [nm, r + 1, ROUNDS]
			var after: float = await _measure()
			cost += (on + after) * 0.5 - off
			offs += off
			on = after
		_lines.append("%-22s %+6.1f ms  (off %.1f, on %.1f)" % [nm, cost / ROUNDS, offs / ROUNDS, on])
		base = on
	_lines.append("+ = what the layer costs, - = what it saves; noise is about +-2 ms")
	DisplayServer.window_set_vsync_mode(vsync)
	Engine.max_fps = max_fps
	var text := "\n".join(_lines)
	print(text)
	DisplayServer.clipboard_set(text)
	status = ""
	finished.emit(text)


func _measure() -> float:
	await _wait(SETTLE)
	var frames := 0
	var t0 := Time.get_ticks_usec()
	var end := t0 + int(WINDOW * 1000000.0)
	while Time.get_ticks_usec() < end:
		await get_tree().process_frame
		frames += 1
	return float(Time.get_ticks_usec() - t0) / 1000.0 / maxf(float(frames), 1.0)


func _wait(sec: float) -> void:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame


## Each case: [name, Callable(off: bool, saved) -> saved]. Called with true it switches the layer off and returns what it needs to put it
## back; with false and that value it restores.
func _cases() -> Array:
	var out: Array = []
	var world: Node3D = _main.get("world")
	out.append(["ground + water", _vis(world)])
	out.append(["far ground", _vis(_main.get("far_terrain"))])
	if _main.get("props") != null:
		out.append(["trees, rocks, grass", _vis(_main.get("props"))])
	out.append(["units", _vis(_main.get("units"))])
	out.append(["HUD", _vis(_main.get("hud"))])
	var mat: ShaderMaterial = world.call("solid_material")
	# the ground shader's levels (toon_world.gdshaderinc `features`): the cost of what the next level adds
	for level in [2, 1, 0]:
		out.append(["shader level 3 -> %d" % level, _level(mat, level)])
	# the same shader with one part of its work cut out (the PROBE_* defines of toon_world.gdshaderinc), on the one material of the ground
	for v in [["no pixel noise", "PROBE_NO_NOISE"], ["no dark corners", "PROBE_NO_AO"], ["no grass picture", "PROBE_NO_COVER"], ["no relief shade", "PROBE_NO_RELIEF"], ["no light read", "PROBE_NO_LIGHT"]]:
		out.append([v[0], _variant(mat, v[1])])
	out.append(["ground plain material", _plain(world)])
	out.append(["culling (-: saves)", _culling()])
	out.append(["3D scale x0.5", _scale()])
	return out


func _vis(n: Node) -> Callable:
	return func(off: bool, _s: Variant) -> Variant:
		if is_instance_valid(n):
			n.set("visible", not off)
		return true


func _variant(mat: ShaderMaterial, define: String) -> Callable:
	return func(off: bool, s: Variant) -> Variant:
		if off:
			var keep := mat.shader
			var sh := Shader.new()
			sh.code = "shader_type spatial;\nrender_mode unshaded, cull_back, depth_draw_opaque;\n#define %s\n#include \"res://shaders/toon_world.gdshaderinc\"\n" % define
			mat.shader = sh
			return keep
		mat.shader = s
		return null


func _level(mat: ShaderMaterial, level: int) -> Callable:
	return func(off: bool, s: Variant) -> Variant:
		if off:
			var keep: Variant = mat.get_shader_parameter("features")
			mat.set_shader_parameter("features", float(level))
			return keep if keep != null else 3.0
		mat.set_shader_parameter("features", s)
		return null


## Every chunk and far node drawn with a flat unshaded material: what is left is the cost of the geometry and of the pixels at all.
func _plain(world: Node3D) -> Callable:
	return func(off: bool, s: Variant) -> Variant:
		if not is_instance_valid(world):
			return null
		var nodes: Array = []
		for c in world.get_children():
			if c is MeshInstance3D:
				nodes.append(c)
		var far: Node = _main.get("far_terrain")
		if is_instance_valid(far):
			for c in far.get_children():
				if c is MeshInstance3D:
					nodes.append(c)
		if off:
			var flat := StandardMaterial3D.new()
			flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			flat.albedo_color = Color(0.4, 0.6, 0.3)
			for n: MeshInstance3D in nodes:
				n.material_override = flat
			return null
		for n: MeshInstance3D in nodes:
			n.material_override = null
		return null


## The horizon, picture and far-ground culling off: everything the game keeps out of the picture is drawn.
func _culling() -> Callable:
	return func(off: bool, _s: Variant) -> Variant:
		for key in ["horizon", "far_terrain"]:
			var n: Node = _main.get(key)
			if is_instance_valid(n):
				n.set("enabled", not off)
		return true


func _scale() -> Callable:
	return func(off: bool, s: Variant) -> Variant:
		var vp := get_viewport()
		if off:
			var keep := vp.scaling_3d_scale
			vp.scaling_3d_scale = keep * 0.5
			return keep
		vp.scaling_3d_scale = s
		return null
