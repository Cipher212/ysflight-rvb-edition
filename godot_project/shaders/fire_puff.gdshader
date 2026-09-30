// PS2 / Ace Combat style fire puff (fx/death_fx.gd): a flat camera-facing quad, additive, unshaded, that
// grows and burns from yellow to orange over its short life, then is gone. No soft-particle depth reads.
// Instance data: MODEL_MATRIX[1].xyz = (start size, end size, life s), MODEL_MATRIX[2].x = spawn time,
//                MODEL_MATRIX[3].xyz = position.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled, fog_disabled;

uniform float now;
varying float v_t;

void vertex() {
	float life = MODEL_MATRIX[1].z;
	float t = (now - MODEL_MATRIX[2].x) / life;
	v_t = t;
	if (t < 0.0 || t >= 1.0) {
		POSITION = vec4(0.0, 0.0, -2.0, 1.0);
	} else {
		float size = mix(MODEL_MATRIX[1].x, MODEL_MATRIX[1].y, t);
		vec3 world = MODEL_MATRIX[3].xyz + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * size;
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
	}
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float core = clamp(1.0 - r, 0.0, 1.0);
	vec3 col = mix(vec3(1.0, 0.9, 0.35), vec3(1.0, 0.42, 0.05), v_t); // yellow -> orange as it burns
	ALBEDO = col * (core * 1.1); // kept below white so the yellow/orange stays saturated
	ALPHA = clamp(core * 1.5, 0.0, 1.0);
}
