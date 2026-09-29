// Explosion flash: bright core, star spikes and an expanding shock ring on a camera-facing quad
// (fx/explosion_fx.gd). Written once at spawn, then aged on the GPU.
// Instance data:
//   MODEL_MATRIX[1].xyz = (start size, end size, life s)   MODEL_MATRIX[2].xy = (spawn time, roll)
//   MODEL_MATRIX[3].xyz = position   COLOR = colour
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled;

uniform float now;
varying float v_progress;

void vertex() {
	float life = MODEL_MATRIX[1].z;
	float age = now - MODEL_MATRIX[2].x;
	float t = age / life;
	v_progress = t;
	if (age < 0.0 || t >= 1.0) {
		POSITION = vec4(0.0, 0.0, -2.0, 1.0);
	} else {
		float size = mix(MODEL_MATRIX[1].x, MODEL_MATRIX[1].y, pow(t, 0.55));
		float c = cos(MODEL_MATRIX[2].y);
		float s = sin(MODEL_MATRIX[2].y);
		vec3 right = INV_VIEW_MATRIX[0].xyz * c + INV_VIEW_MATRIX[1].xyz * s;
		vec3 up = -INV_VIEW_MATRIX[0].xyz * s + INV_VIEW_MATRIX[1].xyz * c;
		vec3 world = MODEL_MATRIX[3].xyz + (right * VERTEX.x + up * VERTEX.y) * size;
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
		COLOR.a *= 1.0 - t;
	}
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float progress = v_progress;
	float core = pow(clamp(1.0 - r * 1.35, 0.0, 1.0), 2.4) * clamp(1.0 - progress * 2.6, 0.0, 1.0);
	float spk_main = pow(clamp(1.0 - min(abs(p.x), abs(p.y)) * 11.0, 0.0, 1.0), 2.5) * pow(clamp(1.0 - r, 0.0, 1.0), 1.4);
	vec2 pr = vec2(p.x + p.y, p.x - p.y) * 0.7071;
	float spk_diag = pow(clamp(1.0 - min(abs(pr.x), abs(pr.y)) * 15.0, 0.0, 1.0), 2.5) * pow(clamp(1.0 - r * 1.25, 0.0, 1.0), 1.6);
	float spikes = (spk_main + spk_diag * 0.6) * clamp(1.0 - progress * 1.8, 0.0, 1.0);
	float ring_r = mix(0.18, 0.92, pow(progress, 0.65));
	float ring_w = mix(0.09, 0.035, progress);
	float ring = exp(-pow((r - ring_r) / max(ring_w, 0.01), 2.0)) * (1.0 - progress);
	float total = core * 1.8 + spikes * 1.5 + ring * 1.35;
	vec3 col = mix(COLOR.rgb, vec3(1.0, 0.99, 0.92), clamp(core + spikes * 0.6, 0.0, 1.0));
	ALBEDO = col * total * 2.0;
	ALPHA = clamp(total * COLOR.a * step(r, 1.0), 0.0, 1.0);
}
