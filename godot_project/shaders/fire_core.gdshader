// Fireball over a shot-down aircraft (fx/death_fx.gd): one camera-facing quad per burning jet, centred
// on the aircraft's origin and pulled towards the camera so it draws over the airframe (the jet looks engulfed).
// The ragged edge and the flicker come from the shader (value noise on TIME + a per-jet seed): nothing is updated
// per frame except the position. Instance data: MODEL_MATRIX[0].xy = (aircraft radius m, seed),
// MODEL_MATRIX[3].xyz = centre.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled, fog_disabled; // mix: stays orange on a bright sea or sky

const float SIZE = 1.1;        // quad half-size vs the aircraft radius (covers most of the model)
const float PULL = 0.8;        // towards the camera, x radius
const vec3 CORE = vec3(1.7, 1.0, 0.3);   // over 1.0: reads as burning bright
const vec3 BODY = vec3(1.2, 0.36, 0.05);
const vec3 EDGE = vec3(0.45, 0.08, 0.02);

varying float v_seed;

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}

void vertex() {
	float radius = MODEL_MATRIX[0].x;
	v_seed = MODEL_MATRIX[0].y;
	vec3 centre = MODEL_MATRIX[3].xyz;
	vec3 to_cam = normalize(INV_VIEW_MATRIX[3].xyz - centre);
	float pulse = 1.0 + 0.06 * sin(TIME * 11.0 + v_seed) + 0.04 * sin(TIME * 17.0 + v_seed * 2.3);
	vec2 v = VERTEX.xy * (2.0 * SIZE * radius * pulse);
	vec3 world = centre + to_cam * (radius * PULL) + INV_VIEW_MATRIX[0].xyz * v.x + INV_VIEW_MATRIX[1].xyz * v.y;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	// Two octaves of drifting noise: the edge is ragged and never repeats
	vec2 q = p * 2.2 + vec2(v_seed, v_seed * 0.37 - TIME * 2.6);
	float n = noise(q) * 0.65 + noise(q * 2.3 + 7.1) * 0.35;
	float r = length(p) / (0.62 + 0.42 * n);
	vec3 col = mix(CORE, BODY, smoothstep(0.1, 0.6, r));
	col = mix(col, EDGE, smoothstep(0.6, 0.95, r));
	ALBEDO = col;
	ALPHA = 0.95 * (1.0 - smoothstep(0.7, 1.0, r));
}
