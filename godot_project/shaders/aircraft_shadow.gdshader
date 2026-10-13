// Aircraft shadows (render/aircraft_shadows.cpp): flattened onto the terrain along the sun vector
// (projection along the sun is done by the C++ node transform). The vertex is pulled a hair towards
// the camera so the shadow wins over the ground it lies on.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, blend_mix, depth_draw_never;
stencil_mode read, write, compare_not_equal, 1;

global uniform float daylight_strength;

const float MIN_DAYLIGHT = 0.02; // matches C++ sun_shadow.h
const float SHADOW_ALPHA = 0.6;  // restrained PS2 Ace Combat look
const float PULL = 0.0002;       // fraction of the distance to the camera

void vertex() {
	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view_pos.xyz *= 1.0 - PULL;
	POSITION = PROJECTION_MATRIX * view_pos;
}

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = SHADOW_ALPHA * smoothstep(MIN_DAYLIGHT, 0.6, daylight_strength);
}
