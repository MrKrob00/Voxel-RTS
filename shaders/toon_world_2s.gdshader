shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
// Props that are seen from both sides (leaves, grass). The body is shared: toon_world.gdshaderinc.
#include "res://shaders/toon_world.gdshaderinc"
