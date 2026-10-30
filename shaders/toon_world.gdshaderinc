// The look of the ground, the water and the props: a cartoon in big pixels, lit by hand (no Godot lights, no shadows, nothing
// per light: one normal, one dot product, a few bands). The sun and the sky come from DayCycle through the texture day_light.
// This is the part the three shaders share (toon_world, toon_world_2s, toon_water); they differ in the render mode, in whether the water's
// ALPHA is written (#define WATER), and nothing else.

// The light of the day: four texels of a texture that DayCycle fills, one for each of: the way the sun's light travels, the colour of the
// sun, the sky ambient, the ground ambient (rgb). A texture and not shader globals: it is read the same everywhere, and the materials
// (also the baked ones) point to ONE file, so a change of the time of day reaches all of them.
// For finding what costs on a device (FrameProbe makes a copy of the shader with one of these defined, the picture is the same but for that part):
//   PROBE_NO_NOISE   no noise of pixels, no jitter of the cobble, no ragged lip (the hashes)
//   PROBE_NO_AO      no dark corners of blocks (the texture of corners)
//   PROBE_NO_COVER   no read of the grass picture of the chunk (one green, nothing worn)
//   PROBE_NO_RELIEF  no shade of the relief (its texture)
//   PROBE_NO_LIGHT   no read of the light of the day (a fixed light)
// The ground is lit from uniforms of its one material (DayCycle sets them with the texture), the rest from the texture: a uniform costs nothing, a read does.
uniform vec3 l_dir = vec3(0.4, -0.8, 0.4);
uniform vec3 l_sun = vec3(1.0);
uniform vec3 l_sky = vec3(0.5, 0.55, 0.65);
uniform vec3 l_ground = vec3(0.3);
uniform sampler2D day_light : hint_default_white, filter_nearest, repeat_disable;

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
//   1 = a face of the grass top: coloured by blobs of three greens (MapPreset.grass_colour, baked per column into cover_tex), worn to bare earth where
//       cover_tex says (a ragged edge of single pixels, not a gradient);
//   2 = the light in the corners of the block comes from ao_tex (the 4 corners x 6 faces of every block of the chunk, 2 bits each);
//   4 = a slope of grass (colours are baked, COLOR.a is how much of the grass is worn away);
//   8 = the side of a grass block: earth with a lip of grass hanging over its top edge.
// UV.y = how much each block of the face differs from the next (cobble on cliffs).
uniform bool terrain = false;
// How much of the ground's work is done (to find which part a graphics card cannot do): 0 only colour and light, 1 + the dark corners
// (a texture), 2 + the worn earth and the shade of the relief (textures), 3 everything (the noise of pixels).
uniform float features = 3.0;
uniform sampler2DArray ao_tex : filter_nearest, repeat_disable;   // a layer for each chunk (GroundLayers), 32 x 256 texels: (x * 2 + face / 4, y * 16 + z) of the block
uniform sampler2DArray cover_tex : filter_linear, repeat_disable; // a layer for each chunk: the grass of the chunk, a texel per column: rgb its green (MapPreset.grass_colour), a how much of it is worn away (GroundCover.slice)
uniform vec2 cover_size = vec2(18.0, 1.0);                                         // its width in columns and the border of columns around the chunk
uniform vec3 bare_color = vec3(0.5412, 0.4157, 0.2627);
uniform vec3 side_earth = vec3(0.4784, 0.3529, 0.2275);      // the side of a grass block under its lip (Blocks earth)
// The shade the relief throws (ReliefShadow): one texel per block of the map, 0 = lit .. 1 = in the shadow of higher ground.
uniform sampler2D relief_tex : hint_default_black, filter_linear, repeat_disable;
uniform vec2 relief_size = vec2(448.0, 448.0);

varying vec3 world_pos;
varying vec3 world_normal;
varying float v_flags;              // UV.x (a whole number: see above)
varying float v_layer;      // UV2.x: the layer of the pictures of the chunk (GroundLayers)
varying float v_jitter;             // UV.y

// A number in 0..1 from three whole numbers (the pixel of the world a fragment is in).
float hash_i(ivec3 c) {
	// all in floats (a hash without sines): the 32-bit integer multiplies it was made of are slow on a phone's GPU
	vec3 p = fract(vec3(c) * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// The noise a pixel is worn by: lumps of 2 x 2 pixels on top of single pixels.
float wear_noise(ivec3 cell) {
	return mix(hash_i(cell), hash_i((cell >> 1) + ivec3(17)), 0.35);
}

// The light a face of this normal gets: [ambient, sun].
void face_light(vec3 nrm, out vec3 amb, out vec3 sun) {
#ifdef PROBE_NO_LIGHT
	vec3 to_light = vec3(-0.4, 0.8, -0.4);
	vec3 sun_rgb = vec3(0.9);
	vec3 sky_rgb = vec3(0.45);
	vec3 ground_rgb = vec3(0.25);
#else
	vec3 to_light = -l_dir;
	vec3 sun_rgb = l_sun;
	vec3 sky_rgb = l_sky;
	vec3 ground_rgb = l_ground;
	if (!terrain) {
		to_light = -texelFetch(day_light, ivec2(0, 0), 0).xyz;
		sun_rgb = texelFetch(day_light, ivec2(1, 0), 0).xyz;
		sky_rgb = texelFetch(day_light, ivec2(2, 0), 0).xyz;
		ground_rgb = texelFetch(day_light, ivec2(3, 0), 0).xyz;
	}
#endif
	float t = clamp(dot(nrm, to_light) * 0.5 + 0.5, 0.0, 1.0);
	float band = clamp(floor(t * steps + 0.5) / steps, 0.0, 1.0);
	amb = mix(ground_rgb, sky_rgb, nrm.y * 0.5 + 0.5);
	sun = sun_rgb * band * 0.62;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	v_flags = UV.x;
	v_jitter = UV.y;
	v_layer = UV2.x;
}

// How lit the corners of the block face under this point are (the way ChunkMesher bakes it): 0.5 .. 1.0, smooth over the face.
float corner_light(vec3 p, vec3 nrm, int layer) {
	int f = 0;
	ivec3 ua = ivec3(0, 1, 0);   // tangent axes (as ChunkMesher.FACE_U / FACE_V)
	ivec3 va = ivec3(0, 0, 1);
	if (nrm.y > 0.5) { f = 2; ua = ivec3(0, 0, 1); va = ivec3(1, 0, 0); }   // (the tops first: most of the ground seen from above)
	else if (nrm.x < -0.5) { f = 1; ua = ivec3(0, 0, 1); va = ivec3(0, 1, 0); }
	else if (nrm.y < -0.5) { f = 3; ua = ivec3(1, 0, 0); va = ivec3(0, 0, 1); }
	else if (nrm.z > 0.5) { f = 4; ua = ivec3(1, 0, 0); va = ivec3(0, 1, 0); }
	else if (nrm.z < -0.5) { f = 5; ua = ivec3(0, 1, 0); va = ivec3(1, 0, 0); }
	vec3 c = p - nrm * 0.01;   // a point inside the block that owns the face
	vec3 cell = floor(c);
	vec3 fr = c - cell;
	float s = dot(fr, vec3(ua));
	float t = dot(fr, vec3(va));
	vec4 texel = texelFetch(ao_tex, ivec3(int(cell.x) * 2 + (f >= 4 ? 1 : 0), int(cell.z) + int(cell.y) * 16, layer), 0);
	float chan = texel.r;
	int k = f & 3;
	if (k == 1) chan = texel.g;
	else if (k == 2) chan = texel.b;
	else if (k == 3) chan = texel.a;
	int packed = int(chan * 255.0 + 0.5);
	const vec4 levels = vec4(0.5, 0.68, 0.84, 1.0);   // ChunkMesher.AO_LEVELS (a vector, not an array: no table to index by a variable)
	float l0 = levels[packed & 3];
	float l1 = levels[(packed >> 2) & 3];
	float l2 = levels[(packed >> 4) & 3];
	float l3 = levels[(packed >> 6) & 3];
	return mix(mix(l0, l1, s), mix(l3, l2, s), t);
}

void fragment() {
	// how much of the detail this pixel gets: 1 near, 0 far
#ifdef PROBE_NO_NOISE
	float lod = 0.0;
#else
	float lod = features >= 3.0 ? clamp((detail_far + VERTEX.z) / (detail_far - detail_near), 0.0, 1.0) : 0.0;
#endif
	// the pixel this fragment is in (nudged a hair so a block edge does not flicker between two pixels)
	ivec3 cell = ivec3(floor(world_pos / pixel_size + 0.002));
	vec3 n = dot(world_normal, world_normal) > 0.25 ? normalize(world_normal) : vec3(0.0, 1.0, 0.0);
	vec3 local_pos = world_pos - MODEL_MATRIX[3].xyz;   // (a chunk is only moved: no varying for the place in the chunk)
	vec3 face = FRONT_FACING ? n : -n;   // (the back of a two-sided thing is lit the other way)
	vec3 base = COLOR.rgb;
	if (terrain) {
		int layer = int(v_layer + 0.5);
		int fl = int(v_flags + 0.5);   // (the UV is the same on every vertex of a face, but interpolated it is not exact)
		vec4 grass = vec4(0.0);        // the green of the grass here and how worn it is: one read of the picture of the chunk
#ifdef PROBE_NO_COVER
		grass = vec4(0.42, 0.66, 0.24, 0.0);
#else
		if ((fl & 9) != 0) {
			grass = textureLod(cover_tex, vec3((local_pos.xz + cover_size.y) / cover_size.x, float(layer)), 0.0);
		}
#endif
		if (features < 2.0) {
			fl &= 2;
		}
#ifndef PROBE_NO_AO
		if ((fl & 2) != 0 && features >= 1.0 && (features < 3.0 || lod > 0.0)) {
			base *= mix(1.0, corner_light(local_pos, normalize(round(n)), layer), features >= 3.0 ? lod : 1.0);
		}
#endif
		// where the grass is worn the earth shows through in single pixels: a pixel is earth when the wear is more than its own noise
		float worn = 0.0;
		if ((fl & 1) != 0) {
			worn = grass.a;
		} else if ((fl & 4) != 0) {
			worn = COLOR.a;
		}
		if (worn > 0.0) {
			// a faint wear shows nothing (no sparse dots over a wide field); the edge itself is ragged, pixel by pixel
			worn = worn < 0.5 ? 0.0 : mix(0.4, 1.0, smoothstep(0.5, 0.85, worn));
			bool bare = worn > (features >= 3.0 ? wear_noise(cell) : 0.5);
			if (bare && worn < 0.97 && lod > 0.0) {
				// a pixel of earth needs a neighbour of earth: no lone dots
				bare = worn > wear_noise(cell + ivec3(1, 0, 0)) || worn > wear_noise(cell - ivec3(1, 0, 0)) || worn > wear_noise(cell + ivec3(0, 0, 1)) || worn > wear_noise(cell - ivec3(0, 0, 1));
			}
			if ((fl & 1) != 0) {
				base *= bare ? bare_color : grass.rgb;
			} else if ((fl & 4) != 0 && bare) {
				base = bare_color;
			}
		} else if ((fl & 1) != 0) {
			base *= grass.rgb;
		}
		if ((fl & 8) != 0) {
			// the lip: a few pixels of grass along the top edge of the wall, each column a different length
			float row = (floor(world_pos.y / pixel_size + 0.002) + 0.5) * pixel_size;
			float depth = floor(row) + 1.0 - row;
			float lip = 0.2 + 0.3 * (lod > 0.0 ? hash_i(ivec3(cell.x, 3, cell.z)) : 0.5);
			base *= depth < lip ? grass.rgb : side_earth;
		}
		if (v_jitter > 0.0 && lod > 0.0) {
			base *= 1.0 + (hash_i(ivec3(floor(world_pos - face * 0.01))) - 0.5) * 2.0 * v_jitter * lod;
		}
	}
	vec3 albedo = base * tint;
	if (lod > 0.0) {
		albedo *= 1.0 + (hash_i(cell) - 0.5) * pixel_noise * 2.0 * lod;
	}
	// the light: bands of sun on top of a sky/ground ambient. Worked out here, in the pixel shader, where the sun and the sky are read:
	// the props have smooth normals (the bands run across their triangles) and the back of a two-sided thing is lit the other way.
	vec3 amb;
	vec3 sun;
	face_light(face, amb, sun);
#ifdef PROBE_NO_RELIEF
	float shade = 0.0;
#else
	float shade = (terrain && features >= 2.0) ? textureLod(relief_tex, world_pos.xz / relief_size, 0.0).r * smoothstep(0.3, 0.7, face.y) : 0.0;   // high ground in the way of the sun
#endif
	vec3 col = albedo * (amb + sun * (1.0 - shade));
	if (sparkle > 0.0) {
		float s = hash_i(ivec3(cell.x, cell.z, int(floor(TIME * 1.5))));
		col += vec3(0.18) * step(0.93, s) * sparkle;
	}
	ALBEDO = col;
#ifdef WATER
	ALPHA = alpha * COLOR.a;
#endif
}
