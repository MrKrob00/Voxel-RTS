class_name ToolTile
extends Button
## A square button of the tool palette: a small drawn emblem with a short caption under it, like the original's icon tiles
## (there is no art yet, so the emblems are simple shapes drawn in code).

const INK := Color(0.93, 0.93, 0.9)
const WARM := Color("ffc933")
const GREEN := Color(0.35, 0.78, 0.3)
const STONE := Color(0.62, 0.64, 0.68)
const WOOD := Color(0.72, 0.5, 0.28)

var mode := Tools.Mode.SELECT
var caption := ""
var has_picture := false


func setup(tool_mode: int, text: String) -> ToolTile:
	mode = tool_mode
	caption = text
	custom_minimum_size = Vector2(68, 76)
	focus_mode = Control.FOCUS_NONE
	tooltip_text = text
	var picture: Texture2D = BlockCatalog.icon(Tools.block_of(tool_mode)) if Tools.is_block(tool_mode) else Tools.structure_picture(tool_mode)
	has_picture = picture != null
	if picture != null:
		# a block or a structure is shown by its photograph (assets/blocks/icons, assets/structures/icons: made from its own model)
		var pic := TextureRect.new()
		pic.texture = picture
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.offset_bottom = -14.0
		add_child(pic)
	return self


func _draw() -> void:
	var c := Vector2(size.x * 0.5, size.y * 0.4)
	var u := minf(size.x, size.y) / 76.0
	if not has_picture:
		_emblem(c, u)
	var font := get_theme_default_font()
	var w := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_CENTER, size.x - 4.0, 11).x
	draw_string(font, Vector2((size.x - minf(w, size.x - 4.0)) * 0.5, size.y - 8.0), caption, HORIZONTAL_ALIGNMENT_LEFT, size.x - 4.0, 11, WARM if button_pressed else INK)


func _rect(c: Vector2, u: float, x: float, y: float, w: float, h: float, col: Color) -> void:
	draw_rect(Rect2(c + Vector2(x, y) * u, Vector2(w, h) * u), col)


func _emblem(c: Vector2, u: float) -> void:
	match mode:
		Tools.Mode.MARK_TREES:
			draw_colored_polygon([c + Vector2(0, -22) * u, c + Vector2(-14, 4) * u, c + Vector2(14, 4) * u], GREEN)
			draw_colored_polygon([c + Vector2(0, -12) * u, c + Vector2(-18, 12) * u, c + Vector2(18, 12) * u], GREEN.darkened(0.15))
			_rect(c, u, -3, 12, 6, 8, WOOD)
		Tools.Mode.MARK_GRASS:
			for i in 5:
				draw_line(c + Vector2(-12 + i * 6, 16) * u, c + Vector2(-16 + i * 8, -14 + (i % 2) * 8) * u, GREEN, 3.0 * u)
		Tools.Mode.MARK_DIG, Tools.Mode.DIG:
			draw_line(c + Vector2(-16, 14) * u, c + Vector2(14, -16) * u, WOOD, 4.0 * u)
			draw_arc(c + Vector2(6, -12) * u, 14.0 * u, deg_to_rad(200), deg_to_rad(340), 12, STONE, 4.0 * u)
		Tools.STOP:
			draw_arc(c, 16.0 * u, 0, TAU, 24, Color(0.95, 0.25, 0.3), 5.0 * u)
			draw_line(c + Vector2(-11, 11) * u, c + Vector2(11, -11) * u, Color(0.95, 0.25, 0.3), 5.0 * u)
		Tools.OPEN_BLOCKS:
			draw_line(c + Vector2(-14, 16) * u, c + Vector2(8, -6) * u, WOOD, 5.0 * u)
			_rect(c, u, -2, -22, 26, 14, STONE)
		Tools.Mode.STOCKPILE:
			for i in 3:
				_rect(c, u, -20, -8 + i * 9, 40, 7, WOOD)
		Tools.Mode.FRAME:
			draw_rect(Rect2(c + Vector2(-18, -18) * u, Vector2(36, 36) * u), WOOD, false, 4.0 * u)
			draw_line(c + Vector2(-18, -18) * u, c + Vector2(18, 18) * u, WOOD, 3.0 * u)
		Tools.Mode.STUMP:
			draw_circle(c + Vector2(0, 4) * u, 14.0 * u, WOOD)
			draw_circle(c + Vector2(0, 0) * u, 14.0 * u, WOOD.lightened(0.25))
			draw_line(c + Vector2(6, -22) * u, c + Vector2(-2, 2) * u, STONE, 4.0 * u)
		Tools.Mode.ROPE_MACHINE:
			draw_arc(c, 14.0 * u, 0, TAU, 20, Color(0.8, 0.7, 0.45), 4.0 * u)
			draw_arc(c, 6.0 * u, 0, TAU, 14, Color(0.8, 0.7, 0.45), 3.0 * u)
		Tools.Mode.STONE_CUBE, Tools.Mode.WOOD_CUBE, Tools.Mode.VOXEL:
			_rect(c, u, -12, -12, 24, 24, WOOD if mode == Tools.Mode.WOOD_CUBE else STONE)
		Tools.Mode.STONE_BRICK, Tools.Mode.WOOD_BRICK:
			_rect(c, u, -22, -8, 44, 18, WOOD if mode == Tools.Mode.WOOD_BRICK else STONE)
			draw_line(c + Vector2(0, -8) * u, c + Vector2(0, 10) * u, Color(0, 0, 0, 0.35), 2.0 * u)
		_:
			draw_circle(c, 10.0 * u, INK)
