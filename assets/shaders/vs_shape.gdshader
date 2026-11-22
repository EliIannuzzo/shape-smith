// ShapeSmith's preview of how Vintage Story draws a shape's faces. Written for
// ShapeSmith; it reproduces the game's maths (face shading, glow, reflective
// modes and wind) so the preview matches, without using the game's code.
//
// Variants (TextureLibrary adds the defines): VS_CULL_BACK culls back faces;
// VS_BLEND alpha-blends instead of cutting out; VS_PREPASS (with VS_BLEND)
// also writes depth for opaque pixels, for the Auto pass.
shader_type spatial;

#ifdef VS_CULL_BACK
#define VS_CULL cull_back
#else
#define VS_CULL cull_disabled
#endif
#ifdef VS_PREPASS
render_mode unshaded, shadows_disabled, VS_CULL, depth_prepass_alpha;
#else
render_mode unshaded, shadows_disabled, VS_CULL;
#endif

uniform sampler2D face_texture : source_color, filter_nearest, repeat_enable;
uniform bool textured = false;
uniform vec4 tint : source_color = vec4(1.0);
uniform vec2 texture_pixels = vec2(16.0);
// Face glow, 0 to 255.
uniform float glow_level = 0.0;
// Element "shade": false keeps every side at full brightness.
uniform bool shade = true;
// 0 none, 1 weak, 2 medium, 3 strong, 4 sparkly, 5 mild (the face's reflectiveMode).
uniform int reflective_mode = 0;
// Pixels less opaque than this are cut out (alpha-tested passes).
uniform float alpha_cutoff = 0.25;

// Environment (Lighting panel). sun_direction points towards the sun.
uniform vec3 sun_direction = vec3(0.32, 0.88, 0.35);
// Brightness of daylight: 1 at noon, low at night. Glow keeps faces lit.
uniform float daylight = 1.0;
// Darkest a face turned away from the sun gets: 0.45, or 0.34 with shadows.
uniform float min_shade = 0.45;
// How strongly glow (and reflective glints) brighten the face, standing in for
// the game's bloom pass.
uniform float bloom = 0.6;
uniform bool wind = false;
uniform float wind_speed = 0.5;

// Per vertex: CUSTOM0.x = windMode, CUSTOM0.y = windData (see Geometry).
varying vec3 world_position;
varying vec3 world_normal;
varying vec3 view_position;


// The game's gradient noise, rewritten: a hash of the lattice point into a
// gradient in [-1, 1]^3, smoothstep-blended over the cell, scaled by 1.2.
vec3 lattice_gradient(vec3 p) {
	vec3 o = vec3(
		127.1 * p.x + 311.7 * p.y + 74.7 * p.z,
		269.5 * p.x + 183.3 * p.y + 246.1 * p.z,
		113.5 * p.x + 271.9 * p.y + 124.6 * p.z);
	vec3 q = (o * 0.025 + 8.0) * o;
	return 2.0 * fract(mod(q, 289.0) / 41.0) - 1.0;
}

float gradient_noise(vec3 p) {
	vec3 cell = floor(p);
	vec3 f = p - cell;
	vec3 s = f * f * (3.0 - 2.0 * f);
	float corners[8];
	for (int i = 0; i < 8; i++) {
		vec3 corner = vec3(float((i >> 2) & 1), float((i >> 1) & 1), float(i & 1));
		corners[i] = dot(lattice_gradient(cell + corner), f - corner);
	}
	// corners index bits: x, y, z (x is the high bit).
	float x00 = mix(corners[0], corners[4], s.x);
	float x01 = mix(corners[1], corners[5], s.x);
	float x10 = mix(corners[2], corners[6], s.x);
	float x11 = mix(corners[3], corners[7], s.x);
	float y0 = mix(x00, x10, s.y);
	float y1 = mix(x01, x11, s.y);
	return 1.2 * mix(y0, y1, s.z);
}


// Wind: the game's per-vertex sway. heightBend grows towards the top of each
// block; the wiggle is a sum of sines.
vec3 apply_wind(vec3 p, int mode, float data, float t) {
	if (mode <= 0 || mode == 12) {
		return p;
	}
	float x = p.x;
	float y = ceil(p.y * 10000.0) / 10000.0;
	float z = p.z;
	if (mode == 6) {
		p.y += gradient_noise(vec3(x / 3.0, z / 3.0, t / 8.0 + t / 4.0)) / 10.0;
		return p;
	}
	float strength = (1.0 + wind_speed) / 30.0;
	float height_bend = 0.0;
	float vertical_bend = 1.3 / 5.0;
	float high_frequency = t * 1.2;
	float y_factor = 1.0;
	float noise_factor = 1.4;
	float bend_constant = 0.8;
	float bend_counter = t;
	if (mode == 1 || mode == 13) {
		strength = 0.005 + 0.015 * wind_speed;
		height_bend = (fract(y) + data) / 7.0 * 1.3;
	} else if (mode == 2) {
		strength = 0.005 + 0.015 * wind_speed;
		height_bend = (fract(y) + data) / 4.0 * 1.3;
	} else if (mode == 3) {
		strength *= 0.5;
		height_bend = (fract(y) + data) / 12.0 * 1.3;
		height_bend = height_bend / 2.0 + pow(height_bend, 1.5) / 2.0;
	} else if (mode == 4) {
		strength = 0.0;
		height_bend = (fract(y) + data) / 7.0 * 1.3;
	} else if (mode == 5) {
		strength = 0.0;
		height_bend = (fract(y) + data) / 14.0 * 1.3;
		height_bend = height_bend / 2.0 + pow(height_bend, 1.5) / 2.0;
		vertical_bend = 0.0;
	} else if (mode == 7) {
		strength = 0.01;
		height_bend = (fract(y) + data) / 7.0 * 0.6;
	} else if (mode == 8) {
		strength *= 0.15;
		y += ((data == 0.0 ? -1.0 : data) + 4.0) / 32.0;
		y_factor = 3.0;
	} else if (mode == 9) {
		strength *= 0.2;
	} else if (mode == 10) {
		strength *= 0.5;
		height_bend = ((1.0 - fract(y)) + data) / 14.0 * 1.5;
	} else if (mode == 11) {
		strength = data * (0.013 + 0.002 * wind_speed);
		high_frequency /= 5.0;
		height_bend = data / 7.0 * 1.3;
		noise_factor = 2.4;
		bend_constant = 0.1;
		bend_counter /= 1.8;
	}
	float bend = wind_speed * height_bend;
	if (bend != 0.0) {
		bend *= bend_constant + wind_speed * 0.2 + noise_factor * gradient_noise(vec3(x * 0.1, z * 0.1, mod(bend_counter, 1024.0) * 0.25));
		bend = min(4.0, bend);
	}
	x += high_frequency;
	y += high_frequency;
	z += high_frequency;
	p.x += bend + strength * (2.0 * sin(x * 0.5) + sin(x + y) + sin(0.5 + 4.0 * x + 2.0 * y) + sin(1.0 + 6.0 * x + 3.0 * y) / 3.0);
	if (mode == 1) {
		p.x += sin(x * 20.0) * strength * 0.2 * wind_speed;
	}
	p.y += -bend * vertical_bend + strength * y_factor * (sin(5.0 * y) / 15.0 + cos(10.0 * x / y_factor) / 10.0 + sin(3.0 * z / y_factor) / 2.0 + cos(x / y_factor * 2.0) / 2.2);
	p.z += strength * (2.0 * sin(z * 0.25) + sin(z + 3.0 * y) + sin(0.5 + 4.0 * z + 2.0 * y) + sin(1.0 + 6.0 * z + y) / 3.0);
	return p;
}


void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (wind) {
		world = apply_wind(world, int(round(CUSTOM0.x)), CUSTOM0.y, TIME);
		VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
	}
	world_position = world;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	view_position = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
}


// The game's reflective modes. Brightness rises with noise that is fixed per
// texture pixel and per position, scaled by how much the face points at the sun.
// In the game Mild uses the same branch as Strong. The game works on atlas
// coordinates; texel (the face's image pixel) stands in, as on a 2048 atlas.
// offset is the position relative to the camera.
vec3 reflect_face(vec3 color, inout float glint, vec3 normal, vec2 texel, vec3 offset) {
	float facing = max(0.1, 0.5 * dot(normal, sun_direction));
	float noise = 0.0;
	if (reflective_mode == 1) {
		noise = gradient_noise(vec3(round(texel.x) * 4.0 / 32.0, round(texel.y) * 4.0 / 32.0, 8.0));
		noise *= 25.0 * gradient_noise(round(offset * 20.0) / 30.0);
		noise = max(0.0, noise + 1.0);
		glint += facing * noise * 0.15;
		return color * (1.0 + facing * noise / 2.0);
	}
	if (reflective_mode == 2) {
		noise = gradient_noise(vec3(round(texel.x) * 8.0 / 32.0, round(texel.y) * 8.0 / 32.0, 8.0));
		noise *= 15.0 * gradient_noise(round(offset * 30.0) / 30.0);
		noise = max(0.0, noise + 1.0);
		glint += facing * noise * 0.15;
		return color * (1.0 + facing * noise / 2.0);
	}
	if (reflective_mode == 3 || reflective_mode == 5) {
		noise = gradient_noise(vec3(round(texel.x) * 8.0 / 32.0, round(texel.y) * 8.0 / 32.0, 8.0));
		noise *= 25.0 * gradient_noise(round(offset * 100.0) / 30.0);
		noise = max(0.0, noise + 1.0);
		glint += facing * noise * 0.15;
		return color * (1.4 + facing * noise / 2.0);
	}
	if (reflective_mode == 4) {
		noise = gradient_noise(vec3(round(texel.x * 2.0) * 8.0 / 32.0, round(texel.y * 2.0) * 8.0 / 32.0, 0.0));
		noise *= 50.0 * gradient_noise(round(view_position * 150.0) / 30.0);
		noise = max(0.0, noise + 1.0);
		glint += facing * noise * 0.03;
		return color * (1.0 + facing * noise / 2.0);
	}
	return color;
}


void fragment() {
	vec4 color = textured ? texture(face_texture, UV) * tint : tint;
#ifdef VS_BLEND
	if (color.a < 0.005) {
		discard;
	}
#else
	if (color.a < alpha_cutoff) {
		discard;
	}
#endif
	vec3 normal = normalize(world_normal) * (FRONT_FACING ? 1.0 : -1.0);
	// Face shading: the side facing the sun is brightest; up faces stay light.
	float brightness = shade ? max(max(min_shade, 0.5 + 0.5 * dot(normal, sun_direction)), normal.y * 0.95) : 1.0;
	float glow = glow_level / 256.0;
	// Glow keeps the face lit when daylight is low.
	vec3 rgb = color.rgb * max(glow, daylight) * brightness;
	float glint = 0.0;
	if (reflective_mode > 0) {
		rgb = reflect_face(rgb, glint, normal, UV * texture_pixels, world_position - CAMERA_POSITION_WORLD);
	}
	rgb += color.rgb * (glow + glint) * bloom;
	ALBEDO = rgb;
#ifdef VS_BLEND
	ALPHA = color.a;
#endif
}
