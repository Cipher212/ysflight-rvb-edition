// Debris shards thrown off a shot-down aircraft (fx/death_fx.gd): flat, unshaded, opaque triangles in charred
// greys, YSFlight-style. Written once at the kill, then flown on the GPU: the aircraft's velocity plus a kick,
// air drag, gravity and a tumble. Opaque, so no overdraw; they shrink away at the end of their life.
// Instance data:
//   MODEL_MATRIX[0].xyz = start velocity     MODEL_MATRIX[1].xyz = (size m, life s, spawn time)
//   MODEL_MATRIX[2].xyz = spin axis * rad/s  MODEL_MATRIX[3].xyz = spawn position     COLOR.rgb = shade
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

uniform float now;

const float DRAG = 0.35;     // 1/s
const float GRAVITY = 9.8;   // m/s^2

vec3 rotate(vec3 v, vec3 axis, float angle) { // Rodrigues
	return v * cos(angle) + cross(axis, v) * sin(angle) + axis * dot(axis, v) * (1.0 - cos(angle));
}

void vertex() {
	float size = MODEL_MATRIX[1].x;
	float life = MODEL_MATRIX[1].y;
	float age = now - MODEL_MATRIX[1].z;
	float t = age / life;
	if (age < 0.0 || t >= 1.0) {
		POSITION = vec4(0.0, 0.0, -2.0, 1.0);
	} else {
		vec3 spin = MODEL_MATRIX[2].xyz;
		float rate = length(spin);
		vec3 axis = rate > 0.001 ? spin / rate : vec3(0.0, 1.0, 0.0);
		float scale = size * (1.0 - smoothstep(0.85, 1.0, t));
		vec3 local = rotate(VERTEX * scale, axis, rate * age + MODEL_MATRIX[1].z * 7.0);
		vec3 pos = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * (1.0 - exp(-DRAG * age)) / DRAG
			+ vec3(0.0, -0.5 * GRAVITY * age * age, 0.0);
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(pos + local, 1.0));
	}
}

void fragment() {
	ALBEDO = COLOR.rgb;
}
