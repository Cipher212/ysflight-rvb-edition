// Low-poly 3-in-1 dynamic water splash crown (fx/water_splash_fx.gd).
// Geometry components encoded in COLOR.r:
//   0.0 = Central Spout
//   0.5 = Spreading Jagged Crown (COLOR.g = jagged peak/valley)
//   1.0 = Surface Foam Annulus
// Instance data:
//   MODEL_MATRIX[1].xyz = (base_radius, top_radius, height)
//   MODEL_MATRIX[2].xyz = (spawn_time, lifetime, surface_y)
//   MODEL_MATRIX[3].xyz = world position at water contact level
//   COLOR = (component_id, jagged_factor, 0.0, alpha_multiplier)

shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled;

uniform float now;

const float SURFACE_OFFSET = 0.04; // small lift to avoid z-fighting with the sea plane

varying float v_alpha;
varying vec3 v_color;
varying float v_comp;

void vertex() {
	float spawn_time = MODEL_MATRIX[2].x;
	float life = MODEL_MATRIX[2].y;
	float age = now - spawn_time;
	float t = age / life;

	if (age < 0.0 || t >= 1.0) {
		// Dead: collapsed offscreen so GPU rasterizer clips triangles before fragment shading
		POSITION = vec4(0.0, 0.0, -2.0, 1.0);
		v_alpha = 0.0;
		v_color = vec3(0.0);
		v_comp = 0.0;
	} else {
		float base_rad = MODEL_MATRIX[1].x;
		float top_rad = MODEL_MATRIX[1].y;
		float max_height = MODEL_MATRIX[1].z;

		float comp = COLOR.r;
		v_comp = comp;

		vec3 pos = VERTEX;
		float h_ratio = UV.y; // 0.0 at base, 1.0 at tip

		if (comp < 0.25) {
			// 1. Central Spout: narrow vertical jet erupting highest
			// Smooth bell curve: starts at water, peaks at t=0.5, returns to water at t=1.0
			float y_curve = sin(t * 3.14159265);
			pos.y = h_ratio * max_height * y_curve * 1.12;
			float r_scale = mix(base_rad * 0.45, top_rad * 0.55, h_ratio);
			pos.xz = normalize(pos.xz + vec2(0.0001)) * r_scale * (0.8 + 0.35 * t);
		} else if (comp < 0.75) {
			// 2. Jagged Crown: flaring conical curtain with alternating jagged teeth
			float jag = COLOR.g; // 1.0 at peaks, 0.0 at valleys
			float eff_height = max_height * (0.60 + 0.40 * jag);

			// Ballistic upward curve
			float y_curve = sin(t * 3.14159265);
			pos.y = h_ratio * eff_height * y_curve;

			// Outward radial flare / blossom as crown expands
			float flare = mix(0.35, 1.25, pow(t, 0.55));
			float r_scale = mix(base_rad, top_rad * flare, h_ratio);
			pos.xz = normalize(pos.xz + vec2(0.0001)) * r_scale;
		} else {
			// 3. Surface Foam Annulus: stays flat on water plane with small offset
			pos.y = SURFACE_OFFSET;
			float ripple_expand = mix(0.4, 1.45, pow(t, 0.65));
			float r_scale = (h_ratio > 0.5 ? top_rad : base_rad) * ripple_expand;
			pos.xz = normalize(pos.xz + vec2(0.0001)) * r_scale;
		}

		vec3 world_pos = MODEL_MATRIX[3].xyz + pos;
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world_pos, 1.0));

		// Continuous fade: fast rise, sustained body, smooth fadeout
		float alpha_fade = smoothstep(0.0, 0.06, t) * (1.0 - t * t);
		v_alpha = alpha_fade * COLOR.a;

		// Water shading: bright sea-foam white on tips/rim, translucent pale cyan in body
		vec3 foam_white = vec3(0.93, 0.97, 1.0);
		vec3 water_cyan = vec3(0.68, 0.86, 0.94);
		float foam_factor = (comp > 0.75) ? 0.75 : (h_ratio * 0.70 + COLOR.g * 0.30);
		v_color = mix(water_cyan, foam_white, clamp(foam_factor, 0.0, 1.0));
	}
}

void fragment() {
	ALBEDO = v_color;
	float base_alpha = (v_comp > 0.75) ? 0.52 : 0.78;
	ALPHA = clamp(v_alpha * base_alpha, 0.0, 1.0);
}
