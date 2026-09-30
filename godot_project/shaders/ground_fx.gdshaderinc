// Ground effects shared by map_poly.gdshader and terrain.gdshader:
// - cloud_shade(): large soft cloud shadows drifting with the wind (two lookups of a tiling noise texture,
//   res://shaders/cloud_noise.tres, set on the materials by render/materials.cpp);
// - water(): sea shading - a sheen towards the horizon (sky reflection) and the sun's glint on small waves.
// Global shader uniforms (project.godot [shader_globals]): sun_direction (towards the sun, main.gd), sky_haze
// (linear, world/sky_environment.gd), and the Graphics settings' on/off switches (graphics_settings.gd).
global uniform vec3 sun_direction;
global uniform vec3 sky_haze;
global uniform float cloud_shadows_on;
global uniform float water_shine_on;
uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable;

const mat2 ROT_A = mat2(vec2(0.799, 0.602), vec2(-0.602, 0.799)); // rotated grids: no axis-aligned patterns
const mat2 ROT_B = mat2(vec2(0.259, -0.966), vec2(0.966, 0.259));
const float CLOUD_ALT = 1500.0;         // m: cloud shadows are cast along the sun from this height
const float CLOUD_TILE = 14000.0;       // m covered by one repeat of the noise texture
const vec2 CLOUD_WIND = vec2(9.0, 4.0); // m/s drift
const float CLOUD_COVER = 0.58;         // noise level above which there is cloud (higher = fewer clouds)
const float CLOUD_SOFT = 0.12;          // edge softness
const float CLOUD_DARK = 0.32;          // brightness lost under a cloud
const float WATER_SHEEN = 0.35;         // how far the sea turns to the sky's haze towards the horizon
const float GLINT_PATH = 0.08;          // faint sun path on the water
const float GLITTER = 2.0;              // sparkles inside the sun's reflection
const float GLITTER_CELL = 0.0025;      // sparkle size vs distance (~2 px at 1080p)
const float GLITTER_RATE = 7.0;         // twinkle speed (each sparkle adds its own random share)
const float GLINT_ZONE = 0.85;          // cos of the angle from the sun's mirror image where glint is computed
const float WAVE_SLOPE = 0.06;          // small waves for the glint (fade out with distance: no shimmer noise)
const float WAVE_SIZE = 75.0;           // m
const float WAVE_DRIFT = 0.05;          // wave pattern drift (noise units per second)
const float WAVE_FADE = 6000.0;         // m
const float GLITTER_RANGE = 3000.0;     // m: glitter fades out (sub-pixel beyond)
const vec3 GLINT_COLOR = vec3(1.0, 0.93, 0.8);

float gfx_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float gfx_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(gfx_hash(i), gfx_hash(i + vec2(1.0, 0.0)), f.x),
			mix(gfx_hash(i + vec2(0.0, 1.0)), gfx_hash(i + vec2(1.0)), f.x), f.y);
}

// Light left under the clouds at this world point (1 = no cloud).
float cloud_shade(vec3 world, float time) {
	vec3 sun = normalize(sun_direction);
	vec2 at_cloud = world.xz + sun.xz * ((CLOUD_ALT - world.y) / max(sun.y, 0.2));
	vec2 p = (at_cloud - CLOUD_WIND * time) / CLOUD_TILE;
	float n = texture(cloud_noise, p).r * 0.7 + texture(cloud_noise, ROT_B * p * 1.7 + 0.37).r * 0.3;
	return 1.0 - CLOUD_DARK * smoothstep(CLOUD_COVER - CLOUD_SOFT, CLOUD_COVER + CLOUD_SOFT, n);
}

// One layer of sparkles: a random point in each cell of a rotated grid, each twinkling at its own rate.
float gfx_sparkles(vec2 p, float time) {
	vec2 id = floor(p);
	vec2 f = fract(p) - (vec2(0.25) + 0.5 * vec2(gfx_hash(id), gfx_hash(id + 19.19)));
	float h = gfx_hash(id + 7.7);
	float twinkle = pow(max(sin(time * (GLITTER_RATE + 4.0 * h) + h * 40.0), 0.0), 12.0);
	return (1.0 - smoothstep(0.08, 0.25, length(f))) * twinkle;
}

// Sea shading: turns col towards the sky haze at grazing angles and, near the sun's reflection, adds the glint
// to emission: a faint path plus pixel-sized sparkles scattered at random that twinkle on small noise waves.
void water(inout vec3 col, inout vec3 emission, vec3 world, vec3 camera, float time) {
	vec3 to_eye = camera - world;
	float dist = length(to_eye);
	vec3 v = to_eye / max(dist, 0.001);
	col = mix(col, sky_haze, pow(1.0 - max(v.y, 0.0), 5.0) * WATER_SHEEN);
	vec3 sun = normalize(sun_direction);
	if (dot(reflect(-v, vec3(0.0, 1.0, 0.0)), sun) < GLINT_ZONE) {
		return; // far from the sun's reflection: no waves or sparkles to compute
	}
	vec2 w = world.xz;
	float slope = WAVE_SLOPE * (1.0 - smoothstep(WAVE_FADE * 0.5, WAVE_FADE, dist));
	vec2 wq = ROT_A * w / WAVE_SIZE + time * WAVE_DRIFT;
	vec2 tilt = vec2(gfx_noise(wq), gfx_noise(wq + 23.0)) + 0.5 * vec2(gfx_noise(wq * 2.7 + 11.0), gfx_noise(wq * 2.7 + 37.0));
	vec3 n = normalize(vec3((tilt.x - 0.75) * slope * 2.0, 1.0, (tilt.y - 0.75) * slope * 2.0));
	float s = max(dot(reflect(-v, n), sun), 0.0);
	float cell = max(dist * GLITTER_CELL, 0.3);
	float spark = gfx_sparkles(ROT_A * w / cell, time) + gfx_sparkles(ROT_B * w / (cell * 0.7) + 5.3, time);
	float fade = 1.0 - smoothstep(GLITTER_RANGE * 0.5, GLITTER_RANGE, dist);
	emission += GLINT_COLOR * (pow(s, 20.0) * GLINT_PATH + pow(s, 60.0) * min(spark, 1.0) * fade * GLITTER);
}
