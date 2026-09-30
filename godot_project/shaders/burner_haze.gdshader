// Heat haze behind afterburners (render/burner_mesh.cpp, render/visual_sync.cpp): crossed planes along the
// exhaust that redraw the frame behind them with a small moving wobble. Only drawn within 300 m of the camera
// (visibility range; it fades out before that), and drawn before the other transparent effects (render
// priority -1) so flames, smoke and trails stay sharp on top. UV: across 0..1, along 0 (start) .. 1 (end).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D screen : hint_screen_texture, filter_linear, repeat_disable;
instance uniform float seed = 0.0;

const float STRENGTH = 0.006;   // offset as a fraction of the screen, at REF_DIST
const float REF_DIST = 25.0;
const float FADE_START = 180.0; // m; gone before HEAT_HAZE_RANGE_M (300 m) culls it
const float FADE_END = 280.0;
const float SPEED = 14.0;       // wobble pattern speed along the exhaust

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}

void fragment() {
	float x = abs(UV.x * 2.0 - 1.0);
	float v = UV.y;
	float dist = length(VERTEX);
	float mask = (1.0 - smoothstep(0.2, 1.0, x)) * smoothstep(0.0, 0.15, v) * (1.0 - smoothstep(0.45, 1.0, v))
			* smoothstep(0.1, 0.5, abs(dot(NORMAL, VIEW))) * (1.0 - smoothstep(FADE_START, FADE_END, dist));
	vec2 p = vec2(x * 3.0 + seed * 13.0, v * 9.0 - TIME * SPEED);
	vec2 wobble = vec2(noise(p), noise(p + vec2(5.2, 1.3))) - 0.5;
	vec2 offset = wobble * mask * STRENGTH * min(REF_DIST / max(dist, 1.0), 2.0);
	ALBEDO = texture(screen, SCREEN_UV + offset).rgb;
	ALPHA = smoothstep(0.0, 0.02, mask); // untouched outside the haze
}
