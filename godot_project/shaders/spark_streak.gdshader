// Explosion spark streaks (fx/explosion_fx.gd). Written once at spawn, then flown on the GPU (drag + gravity).
// Mesh: crossed fins along Z (-0.5 .. 0.5), UV.y = 0 at the front tip.
// Instance data:
//   MODEL_MATRIX[0].xyz = start velocity   MODEL_MATRIX[1].xyz = (length m, life s, spawn time)
//   MODEL_MATRIX[3].xyz = spawn position    COLOR = colour
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled;

uniform float now;

void vertex() {
	float life = MODEL_MATRIX[1].y;
	float age = now - MODEL_MATRIX[1].z;
	float t = age / life;
	if (age < 0.0 || t >= 1.0) {
		POSITION = vec4(0.0, 0.0, -2.0, 1.0);
	} else {
		vec3 v0 = MODEL_MATRIX[0].xyz;
		float decay = exp(-2.5 * age);
		vec3 pos = MODEL_MATRIX[3].xyz + v0 * (1.0 - decay) / 2.5 + vec3(0.0, -9.0 * age * age, 0.0);
		vec3 dir = v0 * decay + vec3(0.0, -18.0 * age, 0.0);
		dir = length(dir) > 0.001 ? normalize(dir) : vec3(0.0, -1.0, 0.0);
		vec3 z_axis = -dir;
		vec3 up_ref = abs(z_axis.y) < 0.95 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 x_axis = normalize(cross(up_ref, z_axis));
		vec3 y_axis = cross(z_axis, x_axis);
		float len = max(MODEL_MATRIX[1].x * (1.0 - t * 0.55), 0.5);
		vec3 world = pos + x_axis * (VERTEX.x * 1.1) + y_axis * (VERTEX.y * 1.1) + z_axis * (VERTEX.z * len);
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
		COLOR.a *= 1.0 - t * t;
	}
}

void fragment() {
	float radial = pow(clamp(1.0 - abs(UV.x * 2.0 - 1.0), 0.0, 1.0), 1.5);
	float profile = smoothstep(0.0, 0.12, UV.y) * pow(clamp(1.0 - UV.y, 0.0, 1.0), 1.2);
	vec3 col = mix(COLOR.rgb, vec3(1.0, 0.98, 0.85), pow(radial, 2.5) * (1.0 - UV.y * 0.7));
	ALBEDO = col * (2.4 * radial * profile);
	ALPHA = clamp(radial * profile * COLOR.a, 0.0, 1.0);
}
