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
	var ghost := MeshInstance3D.new()
	var box := BoxMesh.new()
	var height := 0.5
	box.size = Vector3(sz.x - 0.1, height, sz.y - 0.1)
	ghost.mesh = box
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.35, 0.65, 1.0, 0.45)
	ghost.material_override = m
	ghost.position = Vector3(sz.x * 0.5, height * 0.5, sz.y * 0.5)
	add_child(ghost)
	_label = Label3D.new()
	_label.font_size = 22
	_label.pixel_size = 0.0045
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.outline_size = 8
	_label.position = Vector3(sz.x * 0.5, height + 0.7, sz.y * 0.5)
	add_child(_label)
	_refresh()


func _refresh() -> void:
	if _label != null:
		_label.text = "%s\n%s" % [title, needs_text()]
