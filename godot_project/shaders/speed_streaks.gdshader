// Speed lines and mist around the player's camera (fx/speed_streaks.gd). Each streak is placed from its
// instance index: a random spot in a ring around the flight path through the camera, cycling through
// BOX_LEN metres of air as the jet flies (travel). Streaks are camera-facing ribbons along the flight
// direction (node -Z; the air moves to +Z). Even instances are speed lines (thin, long with speed), odd
// ones mist (short, soft, wider).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled, skip_vertex_transform;

uniform float travel = 0.0; // m flown, wrapped to BOX_LEN
uniform float speed = 0.0;  // m/s
uniform float lines = 0.0;  // 0..1 speed-line strength
uniform float mist = 0.0;   // 0..1 mist strength

const float BOX_LEN = 120.0;
const float R_MIN = 4.0;        // m from the flight path
const float R_MAX = 22.0;
const float LINE_WIDTH = 0.005;
const float LINE_ALPHA = 0.1;
const float LINE_BLUR_S = 0.03; // a streak is the distance flown in this time (motion blur, no strobing)
const float MIST_WIDTH = 0.5;
const float MIST_BLUR_S = 0.02;
const float MIST_ALPHA = 0.1;

varying float v_alpha;

float hash(float n) {
	return fract(sin(n) * 43758.5453);
}

void vertex() {
	float id = float(INSTANCE_ID);
	bool is_mist = mod(id, 2.0) > 0.5;
	float r = mix(R_MIN, R_MAX, sqrt(hash(id * 1.7 + 0.3)));
	float ang = hash(id * 3.1 + 1.9) * TAU;
	float along = fract(hash(id * 5.3 + 4.1) + travel / BOX_LEN); // 0 ahead .. 1 behind
	float len = is_mist ? clamp(speed * MIST_BLUR_S, 1.5, 8.0) : clamp(speed * LINE_BLUR_S, 2.0, 14.0);
	vec3 centre = vec3(cos(ang) * r, sin(ang) * r, (along - 0.5) * BOX_LEN - len * VERTEX.z);
	vec3 p = (MODELVIEW_MATRIX * vec4(centre, 1.0)).xyz;
	vec3 axis = normalize((MODELVIEW_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz);
	VERTEX = p + normalize(cross(axis, p)) * VERTEX.x * (is_mist ? MIST_WIDTH : LINE_WIDTH);
	NORMAL = vec3(0.0, 0.0, 1.0);
	float ends = smoothstep(0.0, 0.15, along) * (1.0 - smoothstep(0.85, 1.0, along));
	float near = smoothstep(2.0, 6.0, length(p)); // no huge streaks across the lens
	v_alpha = ends * near * (0.5 + 0.5 * hash(id * 7.7)) * (is_mist ? mist * MIST_ALPHA : lines * LINE_ALPHA);
}

void fragment() {
	float across = abs(UV.x * 2.0 - 1.0);
	ALBEDO = vec3(1.0);
	ALPHA = (1.0 - across * across) * sin(UV.y * PI) * v_alpha;
}
