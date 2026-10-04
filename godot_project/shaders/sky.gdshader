// Sky (world/sky_environment.gd). Gradient from the sky colour to a pale horizon haze, and the sun disc
// (follows the DirectionalLight3D). Below the horizon: the haze, which is what the depth fog fades the sea ring into.
// Radiance pass (when generated): sky above, a dimmer ground bounce below, no sun disc.
// No TIME and no POSITION: cheap single pass.
shader_type sky;

uniform vec3 sky_top : source_color;
uniform vec3 haze : source_color;
uniform vec3 ground : source_color;       // sea / land around the map (bounce light from below)
uniform float ground_bounce = 0.55;       // brightness of the light from below vs the ground colour
uniform float sun_scatter = 0.0;          // = Environment.fog_sun_scatter, so the haze matches the fogged ground

const float SKY_CURVE = 0.15;             // like Godot's ProceduralSkyMaterial: haze only near the horizon
const float SUN_RADIUS = 0.012;           // radians (~0.7 degrees: reads clearly in game)

void sky() {
	vec3 d = EYEDIR;
	float el = asin(clamp(d.y, -1.0, 1.0));
	float c = clamp(1.0 - pow(1.0 - max(el, 0.0) / (PI * 0.5), 1.0 / SKY_CURVE), 0.0, 1.0);
	vec3 hz = haze;
	if (LIGHT0_ENABLED && LIGHT0_ENERGY > 0.0) { // warm haze towards the sun, matching fog sun scatter
		hz += LIGHT0_COLOR * LIGHT0_ENERGY * pow(max(dot(d, LIGHT0_DIRECTION), 0.0), 8.0) * sun_scatter;
	}
	vec3 col = mix(hz, sky_top, c); // plain haze below the horizon
	if (AT_CUBEMAP_PASS) {
		if (el < 0.0) {
			col = mix(haze, ground * ground_bounce, smoothstep(0.0, 0.25, -el));
		}
		COLOR = col;
	} else {
		if (LIGHT0_ENABLED && LIGHT0_ENERGY > 0.0) {
			float a = acos(clamp(dot(d, LIGHT0_DIRECTION), -1.0, 1.0));
			float disc = 1.0 - smoothstep(SUN_RADIUS * 0.85, SUN_RADIUS, a);
			float sun_vis = disc * clamp(LIGHT0_ENERGY, 0.0, 1.0);
			col = mix(col, LIGHT0_COLOR * 1.4, sun_vis);
		}
		COLOR = col;
	}
}
