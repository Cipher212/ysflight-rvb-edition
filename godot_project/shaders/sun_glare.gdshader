// Sun glare (fx/sun_glare.gd): a soft bloom around the sun, a faint veil over the screen when looking into
// it and three faint lens-flare ghosts on the line through the screen centre (PS2 Ace Combat style).
// Full-screen quad. Dims when the sun is covered: depth taps around it (the sky's depth is 0, reverse Z).
shader_type spatial;
render_mode unshaded, blend_add, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 to_sun = vec3(0.0, 1.0, 0.0);
uniform float fade_from = 0.34; // cos of the view angle where the glare starts
uniform float fade_full = 0.7;
uniform float sun_strength = 1.0;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

const vec3 GLOW = vec3(1.0, 0.9, 0.72);
const float BLOOM = 0.3;
const float BLOOM_FALLOFF = 5.0;
const float VEIL = 0.04;
const float GHOSTS = 0.06;
const float TAP = 0.008; // screen fraction between occlusion taps
const float GHOST_POS[3] = {0.45, 0.9, 1.5};    // along the line sun -> centre -> beyond (1 = mirrored sun)
const float GHOST_SIZE[3] = {0.05, 0.1, 0.035};
const vec3 GHOST_COLOR[3] = {vec3(1.0, 0.6, 0.25), vec3(0.4, 0.8, 1.0), vec3(0.8, 0.5, 1.0)};

varying vec3 v_sun; // xy: sun position in screen UV, z: cos of the angle between view and sun

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
	vec3 s = (VIEW_MATRIX * vec4(to_sun, 0.0)).xyz;
	vec4 clip = PROJECTION_MATRIX * vec4(s, 0.0);
	v_sun = vec3(clip.xy / max(clip.w, 1e-4) * 0.5 + 0.5, -s.z);
}

float sky_at(vec2 uv) {
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return 1.0; // off screen: unknown, assume clear
	}
	return texture(depth_tex, uv).r <= 0.0 ? 1.0 : 0.0;
}

void fragment() {
	vec2 sun = v_sun.xy;
	float clear = (sky_at(sun) + sky_at(sun + vec2(TAP, 0.0)) + sky_at(sun - vec2(TAP, 0.0))
			+ sky_at(sun + vec2(0.0, TAP)) + sky_at(sun - vec2(0.0, TAP))) * 0.2;
	vec2 aspect = vec2(VIEWPORT_SIZE.x / VIEWPORT_SIZE.y, 1.0);
	float bloom = exp(-length((SCREEN_UV - sun) * aspect) * BLOOM_FALLOFF) * BLOOM;
	float veil = pow(max(v_sun.z, 0.0), 8.0) * VEIL;
	vec2 q = (SCREEN_UV - 0.5) * aspect;
	vec2 s = (sun - 0.5) * aspect;
	vec3 ghosts = vec3(0.0);
	for (int i = 0; i < 3; i++) {
		float r = length(q + s * GHOST_POS[i]);
		ghosts += GHOST_COLOR[i] * (1.0 - smoothstep(GHOST_SIZE[i] * 0.6, GHOST_SIZE[i], r));
	}
	float facing = smoothstep(fade_from, fade_full, v_sun.z);
	// Lens ghosts only while the sun is in the frame (fading out just past the screen edge).
	vec2 outside = max(-sun, sun - 1.0);
	float in_frame = 1.0 - smoothstep(0.0, 0.12, max(outside.x, outside.y));
	ALBEDO = (GLOW * (bloom + veil) + ghosts * GHOSTS * in_frame) * clear * facing * sun_strength;
	ALPHA = 1.0;
}
