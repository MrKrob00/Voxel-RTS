shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;
// The look of the ground, the water and the props: a cartoon in big pixels, lit by hand (no Godot lights, no shadows, nothing
// per light: one normal, one dot product, a few bands). The sun and the sky come from DayCycle through global parameters, so
// the time of day costs nothing per object.

global uniform vec3 sun_direction;     // the way the light travels
global uniform vec3 sun_color;
global uniform vec3 sky_ambient;
global uniform vec3 ground_ambient;

uniform float pixel_size = 0.125;      // one "pixel" of texture, in blocks
uniform float pixel_noise = 0.045;     // how much the pixels differ from each other
uniform float steps = 3.0;             // bands of light
uniform vec3 tint = vec3(1.0);        // multiplies the colour (lumps of ore are the grey rock, tinted)
uniform float alpha = 1.0;
// Quality by distance: full detail (the dark corners, the noise of pixels, the ragged edges) nearer than detail_near, none beyond
// detail_far, fading between. Lighter work per pixel for what is far and small.
uniform float detail_near = 70.0;
uniform float detail_far = 150.0;
uniform float sparkle = 0.0;           // water: pixels that flicker
// The ground (ChunkMesher merges whole stretches of flat faces into one quad, so what varied per block and per corner is done here).
// UV.x is a sum of flags:
//   1 = a face of the grass top: coloured by blobs of three greens from the world position (MapPreset.blob), worn to bare earth where
//       cover_tex says (a ragged edge of single pixels, not a gradient);
//   2 = the light in the corners of the block comes from ao_tex (the 4 corners x 6 faces of every block of the chunk, 2 bits each);
//   4 = a slope of grass (colours are baked, COLOR.a is how much of the grass is worn away);
//   8 = the side of a grass block: earth with a lip of grass hanging over its top edge.
// UV.y = how much each block of the face differs from the next (cobble on cliffs).
uniform bool terrain = false;
uniform sampler3D ao_tex : filter_nearest, repeat_disable;
uniform sampler2D cover_tex : hint_default_black, filter_linear, repeat_disable;   // how much of the grass is worn away (GroundCover.slice of the chunk)
uniform vec2 cover_size = vec2(18.0, 1.0);                                         // its width in columns and the border of columns around the chunk
uniform vec3 bare_color = vec3(0.5412, 0.4157, 0.2627);
uniform vec3 side_earth = vec3(0.4784, 0.3529, 0.2275);      // the side of a grass block under its lip (Blocks earth)
// The blobs the grass is coloured by (MapPreset.blob at the middle of each square of the map): R the first, G the second. A texture read
// instead of ten sin() for every pixel of the ground.
uniform sampler2D blob_tex : hint_default_black, filter_linear, repeat_disable;
uniform vec2 blob_size = vec2(448.0, 448.0);                 // what the texture covers, in blocks
uniform vec3 surface_dark = vec3(0.3098, 0.6039, 0.2039);    // MapPreset colours as the vertex colours carry them (no sRGB conversion)
uniform vec3 surface_light = vec3(0.4157, 0.6588, 0.2353);
uniform vec3 surface_deep = vec3(0.2392, 0.5176, 0.2039);
// The shade the relief throws (ReliefShadow): one texel per block of the map, 0 = lit .. 1 = in the shadow of higher ground.
uniform sampler2D relief_tex : hint_default_black, filter_linear, repeat_disable;
uniform vec2 relief_size = vec2(448.0, 448.0);

varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 local_pos;
varying flat vec3 local_normal;
varying flat int v_flags;           // UV.x, as the whole number it is (see above)
varying flat float v_jitter;        // UV.y
varying flat mediump vec3 v_ambient;  // the light of a face of the ground, worked out once per vertex (its normal is the same all over it)
varying flat mediump vec3 v_sun;
varying float v_dist;               // distance from the camera, for the detail

// A number in 0..1 from three whole numbers (the pixel of the world a fragment is in): integer arithmetic only.
float hash_i(ivec3 c) {
	highp uint h = uint(c.x) * 73856093u ^ uint(c.y) * 19349663u ^ uint(c.z) * 83492791u;
	h ^= h >> 13u;
	h *= 0x5bd1e995u;
	h ^= h >> 15u;
	return float(h & 0xFFFFFFu) * 5.9604645e-8;
}

// The noise a pixel is worn by: lumps of 2 x 2 pixels on top of single pixels.
float wear_noise(ivec3 cell) {
	return mix(hash_i(cell), hash_i((cell >> 1) + ivec3(17)), 0.35);
}

// The green of the grass at a place (three blobs of colour).
mediump vec3 grass_green(vec2 p) {
	vec2 b = textureLod(blob_tex, p / blob_size, 0.0).rg;
	mediump vec3 g = mix(surface_dark, surface_light, b.x);
	return mix(g, surface_deep, smoothstep(0.58, 0.72, b.y) * 0.75);
}

// The light a face of this normal gets: [ambient, sun].
void face_light(vec3 nrm, out mediump vec3 amb, out mediump vec3 sun) {
	float t = clamp(dot(nrm, -sun_direction) * 0.5 + 0.5, 0.0, 1.0);
	float band = clamp(floor(t * steps + 0.5) / steps, 0.0, 1.0);
	amb = mix(ground_ambient, sky_ambient, nrm.y * 0.5 + 0.5);
	sun = sun_color * band * 0.62;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	local_pos = VERTEX;
	local_normal = NORMAL;
	v_flags = int(UV.x + 0.5);
	v_jitter = UV.y;
	v_dist = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;   // the depth in front of the camera
	// (worked out for everything, not only for the ground: whatever the fragment shader reads is always written)
	mediump vec3 amb;
	mediump vec3 sun;
	face_light(world_normal, amb, sun);
	v_ambient = amb;
	v_sun = sun;
}

// How lit the corners of the block face under this point are (the way ChunkMesher bakes it): 0.5 .. 1.0, smooth over the face.
float corner_light(vec3 p, vec3 nrm) {
	int f = 0;
	ivec3 ua = ivec3(0, 1, 0);   // tangent axes (as ChunkMesher.FACE_U / FACE_V)
	ivec3 va = ivec3(0, 0, 1);
	if (nrm.x < -0.5) { f = 1; ua = ivec3(0, 0, 1); va = ivec3(0, 1, 0); }
	else if (nrm.y > 0.5) { f = 2; ua = ivec3(0, 0, 1); va = ivec3(1, 0, 0); }
	else if (nrm.y < -0.5) { f = 3; ua = ivec3(1, 0, 0); va = ivec3(0, 0, 1); }
	else if (nrm.z > 0.5) { f = 4; ua = ivec3(1, 0, 0); va = ivec3(0, 1, 0); }
	else if (nrm.z < -0.5) { f = 5; ua = ivec3(0, 1, 0); va = ivec3(1, 0, 0); }
	vec3 c = p - nrm * 0.01;   // a point inside the block that owns the face
	vec3 cell = floor(c);
	vec3 fr = c - cell;
	float s = dot(fr, vec3(ua));
	float t = dot(fr, vec3(va));
	vec4 texel = texelFetch(ao_tex, ivec3(int(cell.x) * 2 + (f >= 4 ? 1 : 0), int(cell.z), int(cell.y)), 0);
	float chan = texel.r;
	int k = f & 3;
	if (k == 1) chan = texel.g;
	else if (k == 2) chan = texel.b;
	else if (k == 3) chan = texel.a;
	int packed = int(chan * 255.0 + 0.5);
	const float levels[4] = float[4](0.5, 0.68, 0.84, 1.0);   // ChunkMesher.AO_LEVELS
	float l0 = levels[packed & 3];
	float l1 = levels[(packed >> 2) & 3];
	float l2 = levels[(packed >> 4) & 3];
	float l3 = levels[(packed >> 6) & 3];
	return mix(mix(l0, l1, s), mix(l3, l2, s), t);
}

void fragment() {
	// how much of the detail this pixel gets: 1 near, 0 far
	float lod = clamp((detail_far - v_dist) / (detail_far - detail_near), 0.0, 1.0);
	// the pixel this fragment is in (nudged a hair so a block edge does not flicker between two pixels)
	ivec3 cell = ivec3(floor(world_pos / pixel_size + 0.002));
	vec3 face = FRONT_FACING ? world_normal : -world_normal;   // (the back of a two-sided thing is lit the other way)
	mediump vec3 base = COLOR.rgb;
	if (terrain) {
		int fl = v_flags;
		if ((fl & 2) != 0 && lod > 0.0) {
			base *= mix(1.0, corner_light(local_pos, normalize(round(local_normal))), lod);
		}
		// where the grass is worn the earth shows through in single pixels: a pixel is earth when the wear is more than its own noise
		float worn = 0.0;
		if ((fl & 1) != 0) {
			worn = textureLod(cover_tex, (local_pos.xz + cover_size.y) / cover_size.x, 0.0).r;
		} else if ((fl & 4) != 0) {
			worn = COLOR.a;
		}
		if (worn > 0.0) {
			// a faint wear shows nothing (no sparse dots over a wide field); the edge itself is ragged, pixel by pixel
			worn = worn < 0.5 ? 0.0 : mix(0.4, 1.0, smoothstep(0.5, 0.85, worn));
			bool bare = worn > wear_noise(cell);
			if (bare && worn < 0.97 && lod > 0.0) {
				// a pixel of earth needs a neighbour of earth: no lone dots
				bare = worn > wear_noise(cell + ivec3(1, 0, 0)) || worn > wear_noise(cell - ivec3(1, 0, 0)) || worn > wear_noise(cell + ivec3(0, 0, 1)) || worn > wear_noise(cell - ivec3(0, 0, 1));
			}
			if ((fl & 1) != 0) {
				base *= bare ? bare_color : grass_green(world_pos.xz);
			} else if ((fl & 4) != 0 && bare) {
				base = bare_color;
			}
		} else if ((fl & 1) != 0) {
			base *= grass_green(world_pos.xz);
		}
		if ((fl & 8) != 0) {
			// the lip: a few pixels of grass along the top edge of the wall, each column a different length
			float row = (floor(world_pos.y / pixel_size + 0.002) + 0.5) * pixel_size;
			float depth = floor(row) + 1.0 - row;
			float lip = 0.2 + 0.3 * (lod > 0.0 ? hash_i(ivec3(cell.x, 3, cell.z)) : 0.5);
			base *= depth < lip ? grass_green(world_pos.xz) : side_earth;
		}
		if (v_jitter > 0.0 && lod > 0.0) {
			base *= 1.0 + (hash_i(ivec3(floor(world_pos - face * 0.01))) - 0.5) * 2.0 * v_jitter * lod;
		}
	}
	mediump vec3 albedo = base * tint;
	if (lod > 0.0) {
		albedo *= 1.0 + (hash_i(cell) - 0.5) * pixel_noise * 2.0 * lod;
	}
	// the light: bands of sun on top of a sky/ground ambient. The ground has flat faces and got it from the vertex shader; the props
	// have smooth normals (the bands run across their triangles) and the back of a two-sided thing is lit the other way: here.
	mediump vec3 amb = v_ambient;
	mediump vec3 sun = v_sun;
	if (!terrain || !FRONT_FACING) {
		face_light(face, amb, sun);
	}
	float shade = terrain ? textureLod(relief_tex, world_pos.xz / relief_size, 0.0).r * smoothstep(0.3, 0.7, face.y) : 0.0;   // high ground in the way of the sun
	mediump vec3 col = albedo * (amb + sun * (1.0 - shade));
	if (sparkle > 0.0) {
		float s = hash_i(ivec3(cell.x, cell.z, int(floor(TIME * 1.5))));
		col += vec3(0.18) * step(0.93, s) * sparkle;
	}
	ALBEDO = col;
	ALPHA = alpha * COLOR.a;
}
