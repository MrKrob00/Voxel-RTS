shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;
// The furnace: the shared toon body with the textures of the furnace worked out in it (see FURNACE in toon_world.gdshaderinc).
#define FURNACE
#include "res://shaders/toon_world.gdshaderinc"
