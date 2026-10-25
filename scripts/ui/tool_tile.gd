class_name ToolTile
extends Button
## A square button of the tool palette: the picture of the tool with a short caption under it. The picture is the photograph of a block
## or a structure (assets/blocks/icons, assets/structures/icons: made from their own models) or an icon from assets/icons.

const INK := Color(0.93, 0.93, 0.9)
const WARM := Color("ffc933")
const ICON_TINT := Color(0.96, 0.84, 0.5)

var mode := Tools.Mode.SELECT
var caption := ""


func setup(tool_mode: int, text: String) -> ToolTile:
	mode = tool_mode
	caption = text
	custom_minimum_size = Vector2(68, 76)
	focus_mode = Control.FOCUS_NONE
	tooltip_text = text
	var picture: Texture2D = BlockCatalog.icon(Tools.block_of(tool_mode)) if Tools.is_block(tool_mode) else Tools.structure_picture(tool_mode)
	var tint := Color.WHITE
	if picture == null:
		picture = Tools.icon_texture(tool_mode)
		tint = ICON_TINT
	if picture != null:
		var pic := TextureRect.new()
		pic.texture = picture
		pic.modulate = tint
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.offset_bottom = -14.0
		pic.offset_left = 4.0
		pic.offset_right = -4.0
		add_child(pic)
	return self


func _draw() -> void:
	var font := get_theme_default_font()
	var w := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_CENTER, size.x - 4.0, 11).x
	draw_string(font, Vector2((size.x - minf(w, size.x - 4.0)) * 0.5, size.y - 8.0), caption, HORIZONTAL_ALIGNMENT_LEFT, size.x - 4.0, 11, WARM if button_pressed else INK)
