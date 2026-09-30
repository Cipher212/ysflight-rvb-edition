// Aircraft shadows (render/aircraft_shadows.cpp), like YSFlight's: the model flattened straight down onto the
// terrain under it (the node transform does the flattening), solid black. The vertex is pulled a hair towards
// the camera (YS: polygon offset) so the shadow wins over the ground it lies on.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

const float PULL = 0.0002; // fraction of the distance to the camera

void vertex() {
	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view_pos.xyz *= 1.0 - PULL;
	POSITION = PROJECTION_MATRIX * view_pos;
}

void fragment() {
	ALBEDO = vec3(0.0);
}
