// Screen glow of nearby explosions (fx/blast_glow.gd): a soft bloom around each blast, sized from the blast's
// apparent size, and a brief brightening of the whole view for very close ones. Full-screen quad; a bloom is
// dropped when something nearer than the blast covers it (depth buffer, reverse Z: larger = nearer).
// Each blast's screen position, size and test depth are worked out in the vertex stage (4 vertices), so a
// pixel only does a depth read and two exponentials per blast.
shader_type spatial;
render_mode unshaded, blend_add, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform mat4 blasts;   // column i: xyz world position, w size (m)
uniform vec4 strength; // component i: 1 at the flash, fading to 0
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

const vec3 GLOW = vec3(1.0, 0.68, 0.32);
const float BLOOM = 0.9;         // concentrated glow over the fireball...
const float BLOOM_SCALE = 1.4;   // ...radius vs the blast's size on screen
const float HALO = 0.12;         // faint wide halo around it
const float MIN_RADIUS = 0.015;  // screen fraction
const float VEIL = 0.08;         // whole-view brightening at point blank...
const float VEIL_RANGE = 300.0;  // ...gone by this distance (m)

varying flat vec4 v_b0; // per blast: screen uv, radius (screen fraction), strength (0 = none)
varying flat vec4 v_b1;
varying flat vec4 v_b2;
varying flat vec4 v_b3;
varying flat vec4 v_front; // per blast: depth one blast size in front of its centre
varying flat float v_veil;

vec4 to_screen(vec4 b, float k, mat4 view, mat4 proj, out float front_z, inout float veil) {
	front_z = 2.0;
	if (k <= 0.0) {
		return vec4(0.0);
	}
	vec3 vp = (view * vec4(b.xyz, 1.0)).xyz;
	float dist = length(vp);
	veil += VEIL * k * (1.0 - smoothstep(VEIL_RANGE * 0.3, VEIL_RANGE, dist));
	if (vp.z > -1.0) {
		return vec4(0.0); // behind the camera
	}
	vec4 clip = proj * vec4(vp, 1.0);
	vec4 front = proj * vec4(vp * max(1.0 - b.w / dist, 0.05), 1.0);
	front_z = front.z / front.w;
	return vec4(clip.xy / clip.w * 0.5 + 0.5, max(b.w * BLOOM_SCALE * proj[1][1] * 0.5 / dist, MIN_RADIUS), k);
}

float bloom(vec4 b, float front_z, float scene_z, vec2 uv, vec2 aspect) {
	if (b.w <= 0.0) {
		return 0.0;
	}
	bool on_screen = all(greaterThanEqual(b.xy, vec2(0.0))) && all(lessThanEqual(b.xy, vec2(1.0)));
	if (on_screen && scene_z > front_z) {
		return 0.0; // covered by terrain or an aircraft
	}
	float g = length((uv - b.xy) * aspect) / b.z;
	return b.w * (BLOOM * exp(-g * g) + HALO * exp(-g * 0.35));
}

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
	float veil = 0.0;
	vec4 fz;
	v_b0 = to_screen(blasts[0], strength.x, VIEW_MATRIX, PROJECTION_MATRIX, fz.x, veil);
	v_b1 = to_screen(blasts[1], strength.y, VIEW_MATRIX, PROJECTION_MATRIX, fz.y, veil);
	v_b2 = to_screen(blasts[2], strength.z, VIEW_MATRIX, PROJECTION_MATRIX, fz.z, veil);
	v_b3 = to_screen(blasts[3], strength.w, VIEW_MATRIX, PROJECTION_MATRIX, fz.w, veil);
	v_front = fz;
	v_veil = veil;
}

void fragment() {
	vec2 aspect = vec2(VIEWPORT_SIZE.x / VIEWPORT_SIZE.y, 1.0);
	float sum = v_veil;
	sum += bloom(v_b0, v_front.x, texture(depth_tex, v_b0.xy).r, SCREEN_UV, aspect);
	sum += bloom(v_b1, v_front.y, texture(depth_tex, v_b1.xy).r, SCREEN_UV, aspect);
	sum += bloom(v_b2, v_front.z, texture(depth_tex, v_b2.xy).r, SCREEN_UV, aspect);
	sum += bloom(v_b3, v_front.w, texture(depth_tex, v_b3.xy).r, SCREEN_UV, aspect);
	ALBEDO = GLOW * sum;
	ALPHA = 1.0; // transparent pass: after the scene, with the depth texture available
}
