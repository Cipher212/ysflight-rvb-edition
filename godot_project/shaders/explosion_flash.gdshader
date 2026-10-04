// Explosion flash: PS2-style sprite-based fireball and flash using GPU-aged MultiMesh
// (fx/explosion_fx.gd).
// Instance data:
//   MODEL_MATRIX[1].xyz = (start size, end size, life s)
//   MODEL_MATRIX[2].xyz = (spawn time, roll, atlas frame index)
//   MODEL_MATRIX[3].xyz = position   COLOR = colour
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled;

uniform float now;
uniform sampler2D explosion_atlas : filter_linear, repeat_disable;
varying float v_progress;
varying float v_frame;

void vertex() {
	float life = MODEL_MATRIX[1].z;
	float age = now - MODEL_MATRIX[2].x;
	float t = age / life;
	v_progress = t;
	v_frame = MODEL_MATRIX[2].z;
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
	float r2 = dot(p, p);
	float edge_mask = clamp(1.0 - smoothstep(0.65, 0.98, sqrt(r2)), 0.0, 1.0);
	
	float progress = v_progress;
	float fade = clamp(1.0 - progress, 0.0, 1.0);

	float tex_val = 0.0;
	if (v_frame >= 0.0) {
		float frame = clamp(floor(v_frame + 0.05), 0.0, 4.0);
		vec2 atlas_uv = vec2((clamp(UV.x, 0.0, 1.0) + frame) / 5.0, clamp(UV.y, 0.0, 1.0));
		tex_val = texture(explosion_atlas, atlas_uv).r * edge_mask;
	} else {
		tex_val = pow(clamp(1.0 - sqrt(r2), 0.0, 1.0), 2.0) * edge_mask;
	}

	vec3 core_white = vec3(1.0, 0.98, 0.88);
	vec3 fire_color = mix(COLOR.rgb * 0.45, COLOR.rgb, smoothstep(0.12, 0.55, tex_val));
	fire_color = mix(fire_color, core_white, smoothstep(0.65, 0.95, tex_val));

	float intensity = tex_val * fade * COLOR.a;
	ALBEDO = fire_color * intensity * 2.2;
	ALPHA = clamp(intensity, 0.0, 1.0);
}
