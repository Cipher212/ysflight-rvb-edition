// Afterburner flame (render/burner_mesh.cpp): two crossed planes along the flame plus a disc on the nozzle
// facing aft. UV: flame = (across 0..1, nozzle 0 .. tip 1), disc = 0..1 square. UV2 = (part: 0 flame /
// 1 disc, flame length in m). Flame axis = local +Z. PS2 Ace Combat look: white core, yellow, orange tail.
// Shock diamonds stay fixed behind the nozzle; only the turbulence moves. `seed` is set per flame
// (visual_sync.cpp) so jets don't flicker in step. Premultiplied blending: the flame adds light and also
// dims what is behind it a little, so it stays orange against a bright sky (pure additive turns pink).
shader_type spatial;
render_mode unshaded, cull_disabled, blend_premul_alpha, depth_draw_never, shadows_disabled;

instance uniform float seed = 0.0;

const vec3 CORE = vec3(1.0, 0.96, 0.85);
const vec3 YELLOW = vec3(1.0, 0.72, 0.25);
const vec3 ORANGE = vec3(1.0, 0.38, 0.06);
const vec3 TAIL = vec3(0.7, 0.12, 0.03);
const float BRIGHTNESS = 1.8;
const float OCCLUSION = 0.5;        // how much of the background the flame hides (0 = purely additive)
const float DIAMONDS = 4.0;         // shock diamonds over the first DIAMOND_SPAN of the flame
const float DIAMOND_SPAN = 0.6;
const float FLICKER_HZ = 20.0;
const float STRETCH = 0.07;         // length breathes +-7 % (burner_mesh.cpp MAX_STRETCH covers it)
const float TURBULENCE_SPEED = 3.0; // flame lengths per second

varying float flicker;

float hash(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

float noise(float x) {
	float i = floor(x);
	float f = fract(x);
	return mix(hash(i), hash(i + 1.0), f * f * (3.0 - 2.0 * f));
}

void vertex() {
	float t = TIME * FLICKER_HZ + seed * 173.0;
	flicker = noise(t) * 0.7 + noise(t * 2.3 + 11.0) * 0.3;
	if (UV2.x < 0.5) {
		VERTEX.z += UV.y * UV2.y * (flicker - 0.5) * 2.0 * STRETCH;
	}
}

void fragment() {
	// Planes fade out as they turn edge-on, so the cross never shows as lines.
	float facing = abs(dot(NORMAL, VIEW));
	vec3 col;
	float a;
	if (UV2.x < 0.5) {
		float x = abs(UV.x * 2.0 - 1.0); // 0 on the axis, 1 at the plane edge
		float v = UV.y;                    // 0 nozzle .. 1 tip
		float width = mix(0.75, 0.12, v);
		float body = (1.0 - smoothstep(width * 0.35, width, x)) * (1.0 - smoothstep(0.55, 1.0, v));
		float core_w = mix(0.3, 0.04, clamp(v / 0.5, 0.0, 1.0));
		float core = (1.0 - smoothstep(0.0, core_w, x)) * (1.0 - smoothstep(0.3, 0.65, v));
		// Shock diamonds: the core pulses along its length with a white knot at each diamond.
		float d = v / DIAMOND_SPAN;
		float wave = 0.5 + 0.5 * cos(d * DIAMONDS * TAU);
		core *= d < 1.0 ? 0.45 + 0.55 * wave : 1.0;
		float diamond = pow(wave, 6.0) * (1.0 - smoothstep(0.0, 0.22, x)) * max(1.0 - d, 0.0);
		float turb = noise(v * 8.0 - TIME * TURBULENCE_SPEED * 8.0 + seed * 57.0);
		body *= 0.7 + 0.3 * turb;
		col = mix(TAIL, ORANGE, 1.0 - smoothstep(0.3, 0.9, v));
		col = mix(col, YELLOW, core);
		col = mix(col, CORE, max(core * core, diamond));
		a = (body + core * 0.6 + diamond * 0.5) * smoothstep(0.1, 0.5, facing);
	} else {
		float glow = clamp(1.0 - length(UV * 2.0 - 1.0), 0.0, 1.0);
		col = mix(ORANGE, CORE, smoothstep(0.15, 0.7, glow));
		a = pow(glow, 1.2) * smoothstep(0.05, 0.4, facing);
	}
	a = clamp(a * (0.85 + 0.3 * flicker), 0.0, 1.0);
	ALBEDO = col * (a * BRIGHTNESS);
	ALPHA = a * OCCLUSION;
}
