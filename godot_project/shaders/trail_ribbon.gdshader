// Smoke trails, wingtip lines and fire trails (render/trail_renderer.cpp fills the instances).
// One MultiMesh instance = one segment p0 -> p1 of a trail, drawn as a flat strip that faces the camera.
// Neighbouring segments share the end point, tangent and width, so a trail has no cracks.
// Instance data:
//   MODEL_MATRIX[0].xyz = p0          MODEL_MATRIX[1].xyz = p1
//   MODEL_MATRIX[2].xyz = tangent p0  MODEL_MATRIX[3].xyz = tangent p1
//   INSTANCE_CUSTOM = (width p0, width p1, alpha p0, alpha p1), widths in metres
//   COLOR.rgb = colour; COLOR.a = minimum width in pixels. Positive: a strip thinner than that is widened
//   and faded to keep its coverage (smoke). Negative: widened but not faded (thin lines stay visible).
//   COLOR.r < 0: shot-down plume, colour from the age ramp below; COLOR.g / COLOR.b = age/life at p0 / p1.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

varying float v_alpha;
varying float v_age;      // age/life along a shot-down plume
varying float v_ramp;     // 1 = colour from death_ramp()

// Ramp (linear colour; unshaded, so over 1.0 reads as burning bright): fire at the smoke point, a quick turn
// to dense charcoal, then thick dark grey (the trail fades out over its last 15 %, trail_renderer.cpp).
const vec3 FIRE_HOT = vec3(1.5, 0.75, 0.15);
const vec3 FIRE_EDGE = vec3(1.0, 0.3, 0.04);
const vec3 CHARCOAL = vec3(0.016);   // ~#1f1f1f
const vec3 SMOKE_GREY = vec3(0.05);
// In age/life of the 7 s plume (trail_renderer.cpp DEATH): fire for ~0.1 s, charcoal by ~0.25 s. As a share of
// life, 8 % would be 140 m of fire behind a jet falling at 250 m/s.
const float FIRE_END = 0.014;
const float CHARCOAL_AT = 0.036;

vec3 death_ramp(float f) {
	if (f < FIRE_END) {
		return mix(FIRE_HOT, FIRE_EDGE, f / FIRE_END);
	}
	if (f < CHARCOAL_AT) {
		return mix(FIRE_EDGE, CHARCOAL, smoothstep(FIRE_END, CHARCOAL_AT, f));
	}
	return mix(CHARCOAL, SMOKE_GREY, smoothstep(CHARCOAL_AT, 0.85, f));
}

void vertex() {
	float e = VERTEX.y + 0.5; // QuadMesh y: -0.5 at p0, +0.5 at p1
	vec3 p = e < 0.5 ? MODEL_MATRIX[0].xyz : MODEL_MATRIX[1].xyz;
	vec3 tangent = e < 0.5 ? MODEL_MATRIX[2].xyz : MODEL_MATRIX[3].xyz;
	float w = e < 0.5 ? INSTANCE_CUSTOM.x : INSTANCE_CUSTOM.y;
	float a = e < 0.5 ? INSTANCE_CUSTOM.z : INSTANCE_CUSTOM.w;

	vec3 to_cam = INV_VIEW_MATRIX[3].xyz - p;
	float dist = max(length(to_cam), 0.01);
	vec3 side = cross(tangent, to_cam / dist);
	float side_len = length(side);
	side = side_len > 0.001 ? side / side_len : INV_VIEW_MATRIX[0].xyz;

	float metres_per_px = 2.0 * dist / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float w_eff = max(w, abs(COLOR.a) * metres_per_px);
	if (COLOR.a > 0.0) {
		a *= w / max(w_eff, 0.0001);
	}
	// Fade smoke the camera is inside of (a wide trail right in front of the lens would fill the screen)
	a *= clamp((dist - w_eff * 0.5) / (w_eff * 1.5 + 0.001), 0.0, 1.0);

	// Draw on the camera-facing side of the trail's thickness (a trail is a tube, not a flat sheet): wide
	// fire/smoke then wraps around the aircraft it comes from instead of being cut in half by the airframe.
	float pull = min(w_eff * 0.5, dist * 0.5);
	vec3 world = p + side * (VERTEX.x * w_eff) + (to_cam / dist) * pull;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
	v_alpha = a;
	v_ramp = COLOR.r < 0.0 ? 1.0 : 0.0;
	v_age = e < 0.5 ? COLOR.g : COLOR.b;
}

void fragment() {
	float edge = 1.0 - abs(UV.x * 2.0 - 1.0); // 1 on the centre line, 0 at the edges
	ALBEDO = v_ramp > 0.5 ? death_ramp(v_age) : COLOR.rgb;
	ALPHA = clamp(v_alpha * smoothstep(0.0, 0.9, edge), 0.0, 1.0);
}
