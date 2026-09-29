// Smoke puffs for explosions and crash plumes (fx/puff_system.gd). Written once at spawn, then aged on the
// GPU: no per-puff CPU work. Deliberately cheap (no noise, no discard): large transparent quads are the
// main GPU cost on integrated graphics.
// Instance data:
//   MODEL_MATRIX[0].xyz = start velocity (m/s; horizontal part slows down, vertical part is kept)
//   MODEL_MATRIX[1].xyz = (start size, end size, life s)   MODEL_MATRIX[2].x = spawn time
//   MODEL_MATRIX[3].xyz = spawn position   COLOR = colour   INSTANCE_CUSTOM.x = heat (fire glow, 0..1+)
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

uniform float now;
varying float v_heat;

void vertex() {
	float life = MODEL_MATRIX[1].z;
	float age = now - MODEL_MATRIX[2].x;
	float t = age / life;
	v_heat = 0.0;
	if (age < 0.0 || t >= 1.0) {
		POSITION = vec4(0.0, 0.0, -2.0, 1.0); // dead: collapsed off-screen
	} else {
		vec3 vel = MODEL_MATRIX[0].xyz;
		float drag = (1.0 - exp(-2.2 * age)) / 2.2;
		vec3 centre = MODEL_MATRIX[3].xyz + vec3(vel.x * drag, vel.y * age, vel.z * drag);
		float size = mix(MODEL_MATRIX[1].x, MODEL_MATRIX[1].y, 1.0 - (1.0 - t) * (1.0 - t));
		vec3 world = centre + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * size;
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
		COLOR.a *= smoothstep(0.0, 0.06, t) * pow(1.0 - t, 1.5);
		v_heat = INSTANCE_CUSTOM.x * clamp(1.0 - t * 3.2, 0.0, 1.0);
	}
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r2 = clamp(dot(p, p), 0.0, 1.0);
	float falloff = (1.0 - r2) * (1.0 - r2);
	ALBEDO = COLOR.rgb + vec3(1.0, 0.55, 0.15) * (v_heat * (1.0 - r2) * 1.6);
	ALPHA = clamp(falloff * COLOR.a, 0.0, 1.0);
}
