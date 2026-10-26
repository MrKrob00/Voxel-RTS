class_name Blueprint
extends Node3D
## The plan of a building the player has put down: a translucent shape on the ground that nothing stands on yet. Units bring what it
## costs, from the stockpiles, whenever the stockpiles have it; when everything has arrived it is replaced by the real building.
## Covers the ground it will take, so nothing else is planned or built there.

var kind_type := "stockpile"     ## "stockpile" or "station"
var kind := 0                    ## Stockpile.Style or Station.Kind
var origin := Vector3i.ZERO
var size := Vector2i(2, 2)
var cost := {}                   ## Resources.Kind -> how many
var delivered := {}              ## Resources.Kind -> how many have arrived
var done := false
var title := ""
var _label: Label3D
var _ghost_log: MeshInstance3D


func covers(c: Vector3i) -> bool:
	return c.y == origin.y and c.x >= origin.x and c.x < origin.x + size.x and c.z >= origin.z and c.z < origin.z + size.y


func remaining() -> Dictionary:
	var out := {}
	for k in cost:
		var left: int = cost[k] - delivered.get(k, 0)
		if left > 0:
			out[k] = left
	return out


func is_complete() -> bool:
	return remaining().is_empty()


## Takes what is still missing of `k` (at most `n`); returns how many it took.
func deliver(k: int, n: int) -> int:
	var took := clampi(cost.get(k, 0) - delivered.get(k, 0), 0, n)
	delivered[k] = delivered.get(k, 0) + took
	_refresh()
	return took


func needs_text() -> String:
	var parts := PackedStringArray()
	for k in cost:
		parts.append("%s %d/%d" % [Resources.label(k).to_lower(), delivered.get(k, 0), cost[k]])
	return ", ".join(parts)


## Where a unit may stand to work on it: any standable cell around the footprint.
func access_cells(nav: Navigation) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for dz in range(-1, size.y + 1):
		for dx in range(-1, size.x + 1):
			if dx >= 0 and dx < size.x and dz >= 0 and dz < size.y:
				continue
			var c := Vector3i(origin.x + dx, origin.y, origin.z + dz)
			if nav.standable(c):
				out.append(c)
	return out


func center() -> Vector3:
	return Vector3(origin.x + size.x * 0.5, origin.y, origin.z + size.y * 0.5)


func build(type: String, k: int, at: Vector3i, sz: Vector2i, price: Dictionary, name_text: String) -> void:
	kind_type = type
	kind = k
	origin = at
	size = sz
	cost = price.duplicate()
	title = name_text
	name = "Blueprint_%d_%d" % [at.x, at.z]
	position = Vector3(at.x, at.y, at.z)
	var height := _make_ghost()
	_label = Label3D.new()
	_label.font_size = 22
	_label.pixel_size = 0.0045
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.outline_size = 8
	_label.position = Vector3(sz.x * 0.5, height + 0.7, sz.y * 0.5)
	add_child(_label)
	_refresh()


## The picture of the plan: the real building (a stockpile platform, the stump with its axe, the rope machine) drawn translucent, with no
## label and no goods. Returns how high it stands.
func _make_ghost() -> float:
	var model: Node3D
	if kind_type == "station":
		var st := Station.new()
		add_child(st)
		st.build(kind, Vector3i.ZERO)
		model = st
	else:
		var sp := Stockpile.new()
		add_child(sp)
		sp.build(Vector3i.ZERO)
		model = sp
	model.set_process(false)
	model.set_physics_process(false)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.35, 0.65, 1.0, 0.45)
	var top := 0.5
	for n in model.find_children("*", "", true, false):
		if n is MeshInstance3D:
			(n as MeshInstance3D).material_override = m
			top = maxf(top, (n as MeshInstance3D).get_aabb().end.y * (n as MeshInstance3D).scale.y + (n as MeshInstance3D).position.y)
		elif n is Label3D:
			n.queue_free()
	return top


## A log is on its way here in somebody's hands: it hangs over the plan as a translucent log until it is put in.
func show_incoming_log(on: bool) -> void:
	if on and _ghost_log == null:
		_ghost_log = MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = LooseLog.RADIUS
		cyl.bottom_radius = LooseLog.RADIUS
		cyl.height = LooseLog.LENGTH
		_ghost_log.mesh = cyl
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(0.7, 0.5, 0.25, 0.55)
		_ghost_log.material_override = m
		_ghost_log.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
		_ghost_log.position = Vector3(size.x * 0.5, 0.75, size.y * 0.5)
		add_child(_ghost_log)
	if _ghost_log != null:
		_ghost_log.visible = on


func is_ghost_log_shown() -> bool:
	return _ghost_log != null and _ghost_log.visible


func _refresh() -> void:
	if _label != null:
		_label.text = "%s\n%s" % [title, needs_text()]
