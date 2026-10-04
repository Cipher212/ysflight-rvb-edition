shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert_wrap, skip_vertex_transform;

// Low-poly cosmetic cloud layer shader.
// Restrained PS2 / YSFlight aesthetic: opaque geometry with vertex colours (off-white top,
// cool grey underside) and directional sunlight. No transparency, no specular, no raymarching.
// Rigidly wraps entire cloud centres across the field boundary to prevent vertex tearing.

uniform vec3 wind_offset = vec3(0.0);
uniform vec2 field_min = vec2(-24000.0, -24000.0);
uniform vec2 field_size = vec2(48000.0, 48000.0);

void vertex() {
	// Transform to world space using inverse-transpose for normals to preserve vertical orientation under non-uniform scale
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	mat3 norm_mat = transpose(inverse(mat3(MODEL_MATRIX)));
	vec3 world_norm = normalize(norm_mat * NORMAL);

	// Center of this cloud instance
	vec3 base_center = MODEL_MATRIX[3].xyz;
	float speed_mult = INSTANCE_CUSTOM.r > 0.01 ? INSTANCE_CUSTOM.r : 1.0;
	vec3 moved_center = base_center + wind_offset * speed_mult;

	// Wrap entire cloud center across the field bounds
	float rel_x = moved_center.x - field_min.x;
	float rel_z = moved_center.z - field_min.y;
	float wrapped_x = field_min.x + mod(mod(rel_x, field_size.x) + field_size.x, field_size.x);
	float wrapped_z = field_min.y + mod(mod(rel_z, field_size.y) + field_size.y, field_size.y);

	// Rigid displacement applied to all vertices belonging to this instance
	vec3 shift = vec3(wrapped_x - base_center.x, wind_offset.y, wrapped_z - base_center.z);
	world_pos += shift;

	// Transform to view space (required with skip_vertex_transform)
	VERTEX = (VIEW_MATRIX * vec4(world_pos, 1.0)).xyz;
	NORMAL = (VIEW_MATRIX * vec4(world_norm, 0.0)).xyz;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	EMISSION = COLOR.rgb * 0.08;
}
