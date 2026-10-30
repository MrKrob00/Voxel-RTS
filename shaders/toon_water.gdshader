shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;
// The water (see-through: it writes ALPHA). The body is shared: toon_world.gdshaderinc.
#define WATER
#include "res://shaders/toon_world.gdshaderinc"
