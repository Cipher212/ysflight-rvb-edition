// Sky (world/sky_environment.gd). Gradient from the field's sky colour to a pale horizon haze, the sun
// (follows the DirectionalLight3D) and a band of distant low-poly hills on the horizon, so the world does
// not end at the map edge. Below the horizon: the haze, which is what the depth fog fades the sea ring into.
// Radiance pass (the ambient light on models): sky above, a dimmer ground bounce below, no sun disc.
// No TIME and no POSITION: Godot renders the radiance only once, and the visible sky is one cheap pass.
shader_type sky;

uniform vec3 sky_top : source_color;
uniform vec3 haze : source_color;
uniform vec3 ground : source_color;       // sea / land around the map (bounce light from below)
uniform vec3 hills : source_color;        // distant land before the haze
uniform float ground_bounce = 0.55;       // brightness of the light from below vs the ground colour
uniform float sun_scatter = 0.0;          // = Environment.fog_sun_scatter, so the haze matches the fogged ground

const float SKY_CURVE = 0.15;             // like Godot's ProceduralSkyMaterial: haze only near the horizon
const float HILL_SEGMENTS = 180.0;        // straight ridge segments around the horizon (2 degrees each)
const float HILL_MAX = 0.024;             // tallest hills, radians (~1.4 degrees)
const float HILL_HAZE = 0.62;             // how much the haze hides the hills (more at their base)
const float HILL_EDGE = 0.0012;           // soft silhouette, ~1 pixel at 1080p
const float SUN_RADIUS = 0.012;           // radians (~0.7 degrees: bigger than the real sun, reads in game)
const vec3 SUN_COLOR = vec3(1.0, 0.95, 0.82);

float hash(float n) {
	return fract(sin(n * 127.1 + 311.7) * 43758.5453);
}

// Elevation of the distant hills at this azimuth: straight segments between random heights, only in a
// few arcs of the horizon (islands and a coast, not a wall). Wraps seamlessly at +-PI.
float hill_height(float az) {
	float seg = az * HILL_SEGMENTS / TAU;
	float i = floor(seg);
	float h = mix(hash(mod(i, HILL_SEGMENTS)), hash(mod(i + 1.0, HILL_SEGMENTS)), seg - i);
	float big = hash(mod(floor(seg / 12.0), HILL_SEGMENTS / 12.0) + 7.0); // a few taller ranges
	float arc = smoothstep(0.05, 0.55, 0.6 * sin(az * 3.0 + 1.3) + 0.4 * sin(az * 5.0 + 0.4));
	return (0.12 + 0.88 * h) * mix(0.35, 1.0, big) * arc * HILL_MAX;
}

void sky() {
	vec3 d = EYEDIR;
	float el = asin(clamp(d.y, -1.0, 1.0));
	float c = clamp(1.0 - pow(1.0 - max(el, 0.0) / (PI * 0.5), 1.0 / SKY_CURVE), 0.0, 1.0);
	vec3 hz = haze;
	if (LIGHT0_ENABLED) { // warm haze towards the sun, the same term Godot adds to the fog colour
		hz += LIGHT0_COLOR * LIGHT0_ENERGY * pow(max(dot(d, LIGHT0_DIRECTION), 0.0), 8.0) * sun_scatter;
	}
	vec3 col = mix(hz, sky_top, c); // plain haze below the horizon
	if (AT_CUBEMAP_PASS) {
		if (el < 0.0) {
			col = mix(haze, ground * ground_bounce, smoothstep(0.0, 0.25, -el));
		}
		COLOR = col;
	} else {
		float hh = hill_height(atan(d.x, d.z));
		if (hh > 0.0 && el < hh + HILL_EDGE) {
			float up = clamp(el / hh, 0.0, 1.0);
			vec3 hill = mix(hz, hills, (1.0 - HILL_HAZE) * up);
			col = mix(col, hill, (1.0 - smoothstep(hh - HILL_EDGE, hh + HILL_EDGE, el)) * step(-0.02, el));
		}
		if (LIGHT0_ENABLED) {
			float a = acos(clamp(dot(d, LIGHT0_DIRECTION), -1.0, 1.0));
			float disc = 1.0 - smoothstep(SUN_RADIUS * 0.75, SUN_RADIUS, a);
			float glow = exp(-a * 60.0) * 0.6 + exp(-a * 9.0) * 0.18;
			col = mix(col, SUN_COLOR * 1.4, disc) + SUN_COLOR * glow * (1.0 - disc);
		}
		COLOR = col;
	}
}
