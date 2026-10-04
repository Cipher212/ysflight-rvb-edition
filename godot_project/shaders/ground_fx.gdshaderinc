// Ground effects shared by map_poly.gdshader and terrain.gdshader:
// - cloud_shade(): large soft cloud shadows drifting with the wind (two lookups of a tiling noise texture,
//   res://shaders/cloud_noise.tres, set on the materials by render/materials.cpp);
// - water(): sea shading - a sheen towards the horizon (sky reflection) and the sun's glint on small waves;
// - ground_detail(): natural land (greens / browns, not grey runways or roads) gets flat-coloured flecks near the
//   camera (a sense of speed and height when low) and very large, faint patches on green (land vs sea up high).
// Global shader uniforms (project.godot [shader_globals]): sun_direction (towards the sun, main.gd), sky_haze
// (linear, world/sky_environment.gd), and the Graphics settings' on/off switches (graphics_settings.gd).
global uniform vec3 sun_direction;
global uniform vec3 sky_haze;
global uniform float daylight_strength;
global uniform float cloud_shadows_on;
global uniform float water_shine_on;
global uniform float ground_detail_on;
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
const float GLITTER = 1.35;             // sparkles inside the sun's reflection (visible, restrained highlight)
const float GLITTER_SPEED = 0.8;        // sparkle twinkle animation speed multiplier (responsive in flight)
const float GLITTER_CELL = 0.0030;      // sparkle cell size vs distance (~40% of original density on single grid)
const float GLITTER_RATE = 7.0;         // twinkle base rate (scaled uniformly by GLITTER_SPEED)
const float GLINT_ZONE = -0.3;          // cos of the angle from the sun's mirror image where sparkles start...
const float GLINT_ZONE_FULL = 0.6;      // ...and reach full strength (soft edge: no visible cut-off)
const float GLITTER_OFF_SUN = 0.22;     // sparkle brightness away from the sun's reflection (visible speed cues)
const float WAVE_SLOPE = 0.06;          // small waves for the glint (fade out with distance: no shimmer noise)
const float WAVE_SIZE = 75.0;           // m
const float WAVE_DRIFT = 0.035;         // wave pattern drift (calmer surface drift)
const float WAVE_FADE = 6000.0;         // m
const float GLITTER_RANGE = 3000.0;     // m: glitter fades out (covers forward flight path from altitude)
const vec3 GLINT_COLOR = vec3(1.0, 0.93, 0.8);
const float FLECK_CELL = 0.004;         // fleck cell size vs distance, in doubling steps (min FLECK_CELL_MIN)
const float FLECK_CELL_MIN = 1.5;       // m
const float FLECK_DENSITY = 0.6;        // share of cells with a fleck
const float FLECK_DARK = 0.78;          // brightness of a dark fleck (tuft, rock shadow)...
const float FLECK_LIGHT = 1.12;         // ...and of a light one (dry grass, stone)
const float FLECK_RANGE = 1500.0;       // m: flecks fade out (sub-pixel beyond)
const float PATCH_TILE = 2600.0;        // m per repeat of the noise for the large patches
const float PATCH_DEPTH = 0.09;         // brightness swing of the patches
const vec3 PATCH_DRY = vec3(1.06, 1.0, 0.8); // tint towards dry grass on the light side

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
	if (daylight_strength <= 0.001) {
		return 1.0;
	}
	vec3 sun = normalize(sun_direction);
	vec2 at_cloud = world.xz + sun.xz * ((CLOUD_ALT - world.y) / max(sun.y, 0.2));
	vec2 p = (at_cloud - CLOUD_WIND * time) / CLOUD_TILE;
	float n = texture(cloud_noise, p).r * 0.7 + texture(cloud_noise, ROT_B * p * 1.7 + 0.37).r * 0.3;
	return 1.0 - CLOUD_DARK * daylight_strength * smoothstep(CLOUD_COVER - CLOUD_SOFT, CLOUD_COVER + CLOUD_SOFT, n);
}

// One layer of sparkles: a random point in each cell of a rotated grid, each twinkling at its own rate.
// Glints are horizontally elongated like wave facets for authentic PS2 water reflections.
float gfx_sparkles(vec2 p, float time) {
	vec2 id = floor(p);
	vec2 f = fract(p) - (vec2(0.25) + 0.5 * vec2(gfx_hash(id), gfx_hash(id + 19.19)));
	float h = gfx_hash(id + 7.7);
	float twinkle = pow(max(sin(time * GLITTER_SPEED * (GLITTER_RATE + 4.0 * h) + h * 40.0), 0.0), 3.0);
	float d = length(vec2(f.x * 0.8, f.y * 1.3));
	return (1.0 - smoothstep(0.08, 0.32, d)) * twinkle;
}

// Natural land only: greens and browns (saturated, not blue-dominant); runways, roads and concrete are grey.
float gfx_natural(vec3 col) {
	float hi = max(col.r, max(col.g, col.b));
	float lo = min(col.r, min(col.g, col.b));
	float sat = (hi - lo) / max(hi, 0.0001);
	return smoothstep(0.18, 0.3, sat) * step(col.b, max(col.r, col.g));
}

void ground_detail(inout vec3 col, vec3 world, vec3 camera, float px) {
	float natural = gfx_natural(col);
	if (natural <= 0.0) {
		return;
	}
	vec2 w = world.xz;
	
	// Large faint patches on green ground (Macro scale)
	float green = smoothstep(0.0, 0.05, col.g - max(col.r, col.b));
	float n = texture(cloud_noise, w / PATCH_TILE + 0.61).r;
	float swing = (n - 0.5) * 2.0 * PATCH_DEPTH * green * natural;
	col *= mix(vec3(1.0), PATCH_DRY, max(swing, 0.0) / PATCH_DEPTH * 0.5) * (1.0 + swing);
	
	// Fade out the micro-detail in the distance
	float dist = length(camera - world);
	float fade = 1.0 - smoothstep(100.0, 2000.0, dist);
	if (fade <= 0.0) {
		return;
	}
	
	// SUPER CHEAP MICRO-DETAIL: Sine Wave Interference
	// Creates organic, smooth splotches with native math instructions
	vec2 p = w / 35.0; // Size of the splotches
	float wave = sin(p.x) + sin(p.y);
	
	// Rotate and add a smaller wave to break up the pattern
	p = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8)) * p * 2.3;
	wave += (sin(p.x) + sin(p.y)) * 0.5;
	
	// Scale the wave to a gentle color multiplier
	wave *= 0.25; 
	
	// Apply the dark/light colors smoothly based on the wave
	col *= mix(1.0, FLECK_DARK, max(-wave * fade * natural, 0.0));
	col *= mix(1.0, FLECK_LIGHT, max(wave * fade * natural, 0.0));
}

// Rotated sparkle grid with this cell size (m). Single grid with jittered points reduces shader cost.
float gfx_sparkle_cells(vec2 w, float cell, float time) {
	return gfx_sparkles(ROT_A * w / cell, time);
}

// Sea shading: turns col towards the sky haze at grazing angles and adds the glint to emission: a faint path in
// the sun's reflection plus pixel-sized sparkles that twinkle over a wide area around it (so the sea below the
// player glitters too, not only a patch far off towards the sun), fading softly at the edge and with distance.
void water(inout vec3 col, inout vec3 emission, vec3 world, vec3 camera, float time) {
	vec3 to_eye = camera - world;
	float dist = length(to_eye);
	vec3 v = to_eye / max(dist, 0.001);
	col = mix(col, sky_haze, pow(1.0 - max(v.y, 0.0), 5.0) * WATER_SHEEN);
	vec3 sun = normalize(sun_direction);
	float mirror = dot(reflect(-v, vec3(0.0, 1.0, 0.0)), sun);
	if (mirror < GLINT_ZONE || daylight_strength <= 0.001) {
		return; // facing away from the sun's reflection or night: no waves or sparkles to compute
	}
	float zone = smoothstep(GLINT_ZONE, GLINT_ZONE_FULL, mirror);
	vec2 w = world.xz;
	float slope = WAVE_SLOPE * (1.0 - smoothstep(WAVE_FADE * 0.5, WAVE_FADE, dist));
	float s;
	if (slope > 0.0) {
		vec2 wq = ROT_A * w / WAVE_SIZE + time * WAVE_DRIFT;
		vec2 tilt = vec2(gfx_noise(wq), gfx_noise(wq + 23.0)) + 0.5 * vec2(gfx_noise(wq * 2.7 + 11.0), gfx_noise(wq * 2.7 + 37.0));
		vec3 n = normalize(vec3((tilt.x - 0.75) * slope * 2.0, 1.0, (tilt.y - 0.75) * slope * 2.0));
		s = max(dot(reflect(-v, n), sun), 0.0);
	} else {
		s = max(mirror, 0.0);
	}
	float pow_s20 = pow(s, 20.0);
	float fade = 1.0 - smoothstep(GLITTER_RANGE * 0.5, GLITTER_RANGE, dist);
	float glitter = 0.0;
	if (fade > 0.0) {
		// The cell size grows with distance in doubling steps, cross-faded like mipmaps: a size that changed smoothly
		// per pixel sheared the grid into radial streaks around the camera.
		float level = log2(max(dist * GLITTER_CELL, 0.3));
		float step_lo = floor(level);
		float cell = exp2(step_lo);
		float spark = mix(gfx_sparkle_cells(w, cell, time), gfx_sparkle_cells(w, cell * 2.0, time), level - step_lo);
		glitter = min(spark, 1.0) * fade * GLITTER * mix(GLITTER_OFF_SUN, 1.0, pow_s20);
	}
	emission += GLINT_COLOR * zone * (pow_s20 * GLINT_PATH + glitter) * daylight_strength;
}
