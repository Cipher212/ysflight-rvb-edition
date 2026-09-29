// Bullet and debris tracers (render/weapon_fx_renderer.cpp): thin glowing streaks on a crossed-fin mesh.
// UV.y = 0 at the leading tip, 1 at the tail. COLOR = instance colour.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled;

void fragment() {
	float radial = pow(clamp(1.0 - abs(UV.x * 2.0 - 1.0), 0.0, 1.0), 1.6); // brightest on the spine
	float profile = smoothstep(0.0, 0.08, UV.y) * pow(clamp(1.0 - UV.y, 0.0, 1.0), 1.35); // hot tip, long tail
	float core = pow(radial, 3.0) * smoothstep(0.55, 0.05, UV.y);
	vec3 col = mix(COLOR.rgb, vec3(1.0, 0.98, 0.92), core);
	ALBEDO = col * (1.8 * radial * profile);
	ALPHA = clamp(radial * profile * COLOR.a, 0.0, 1.0);
}
