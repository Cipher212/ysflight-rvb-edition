// Rocket motor and flare glow (render/weapon_fx_renderer.cpp): camera-facing quad, size = instance scale,
// never smaller than MIN_PX on screen so flares stay visible from far away. COLOR may exceed 1 (brighter).
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled;

const float MIN_PX = 6.0;

void vertex() {
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	float dist = length(MODEL_MATRIX[3].xyz - INV_VIEW_MATRIX[3].xyz);
	float metres_per_px = 2.0 * dist / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	scale = max(scale, vec3(MIN_PX * metres_per_px));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(INV_VIEW_MATRIX[0].xyz * scale.x, 0.0),
		vec4(INV_VIEW_MATRIX[1].xyz * scale.y, 0.0),
		vec4(INV_VIEW_MATRIX[2].xyz * scale.z, 0.0),
		MODEL_MATRIX[3]);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float glow = pow(clamp(1.0 - r, 0.0, 1.0), 2.2);
	float rays = pow(clamp(1.0 - abs(p.x * p.y) * 6.0, 0.0, 1.0), 3.0) * smoothstep(1.0, 0.15, r);
	float intensity = glow + rays * 0.65;
	vec3 col = mix(COLOR.rgb, vec3(1.0, 1.0, 0.95), pow(glow, 2.5));
	ALBEDO = col * (intensity * 2.2);
	ALPHA = clamp(intensity * COLOR.a, 0.0, 1.0);
}
