// Ground object shadows (render/ground_shadows.cpp): baked collision shells dropped onto terrain,
// projected along the sun vector onto the local terrain plane on the GPU.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, blend_mix, depth_draw_never;
stencil_mode read, write, compare_not_equal, 2;

global uniform vec3 sun_direction;
global uniform float daylight_strength;

const float MIN_SUN_Y = 0.25;      // lowest sun elevation (~14.5 deg), matches C++ sun_shadow.h
const float MIN_SUN_DOT_N = 0.15;  // grazing threshold, matches C++ sun_shadow.h
const float MIN_DAYLIGHT = 0.02;   // night threshold, matches C++ sun_shadow.h
const float SHADOW_ALPHA = 0.6;    // restrained PS2 Ace Combat look
const float PULL = 0.0002;         // fraction of distance towards camera to prevent z-fighting

void vertex() {
	vec3 L = normalize(sun_direction);
	if (L.y < MIN_SUN_Y) {
		float h = length(L.xz);
		if (h > 1e-6) {
			vec2 dir = normalize(L.xz);
			float horiz = sqrt(1.0 - MIN_SUN_Y * MIN_SUN_Y);
			L = vec3(dir.x * horiz, MIN_SUN_Y, dir.y * horiz);
		} else {
			L = vec3(0.0, 1.0, 0.0);
		}
	}
	vec3 n = NORMAL;
	float d = max(dot(L, n), MIN_SUN_DOT_N);
	VERTEX += UV.x * (vec3(0.0, 1.0, 0.0) - (n.y / d) * L);

	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view_pos.xyz *= 1.0 - PULL;
	POSITION = PROJECTION_MATRIX * view_pos;
}

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = SHADOW_ALPHA * smoothstep(MIN_DAYLIGHT, 0.6, daylight_strength);
}
