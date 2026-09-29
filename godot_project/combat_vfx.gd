extends Node3D
class_name CombatVFX

# ==============================================================================
# YSFlight Godot Port - Frontier 2: Combat & Ordnance VFX Manager
# ==============================================================================
# This node renders all transient weapon visuals and particle effects in 3D:
#   1. Bullet & Debris Tracers (DCS / War Thunder / Ace Combat thin glowing streaks)
#   2. Missile, Rocket & Flare Puffing Smoke Trails (OGL2-style volumetric puffs)
#   3. Rocket Motor & Flare Exhaust Core Glows
#   4. Stylized Non-Spherical Explosions (Starburst flash + Shockwave ring +
#      Directional spark streaks + Billowing fire-to-charcoal smoke clouds)
#
# NOTE FOR FUTURE LLMs:
# See `logs/vfx_instructions.md` for full documentation on how data flows from
# `ysflight_sim.get_active_weapons()` and `ysflight_sim.get_active_explosions()`
# into this script, and how to replace any MultiMesh / Shader / Particle pass.
# ==============================================================================

# YSFlight FSWEAPONTYPE constants (from ysce/src/core/fsdef.h)
const WPN_GUN: int = 0
const WPN_AIM9: int = 1
const WPN_AGM65: int = 2
const WPN_BOMB: int = 3
const WPN_ROCKET: int = 4
const WPN_FLARE: int = 5
const WPN_AIM120: int = 6
const WPN_BOMB250: int = 7
const WPN_SMOKE: int = 8
const WPN_BOMB500HD: int = 9
const WPN_AIM9X: int = 10
const WPN_FUELTANK: int = 12
const WPN_DEBRIS: int = 200

const MAX_TRACERS: int = 512
const MAX_EXHAUST_GLOWS: int = 128
const MAX_SMOKE_PUFFS: int = 1536
const MAX_SPARK_STREAKS: int = 512
const MAX_FLASH_BURSTS: int = 64

var tracer_mmi: MultiMeshInstance3D = null
var exhaust_mmi: MultiMeshInstance3D = null
var smoke_mmi: MultiMeshInstance3D = null
var spark_mmi: MultiMeshInstance3D = null
var flash_mmi: MultiMeshInstance3D = null

# Volumetric smoke puffs: MultiMesh instances are GPU-aged from a ring buffer
var smoke_material: ShaderMaterial = null
var smoke_head: int = 0
var smoke_spawned: int = 0
var vfx_time: float = 0.0
# Ring buffer of active high-velocity explosion spark streaks
var spark_streaks: Array = []
# Active starburst flash + shockwave rings for explosions
var flash_bursts: Array = []
# Pooled OmniLight3D nodes for explosion flashes
var flash_lights: Array = []

# Tracks the last world position where each active weapon slot emitted a smoke puff
var weapon_last_trail_pos: Dictionary = {}
# Tracks explosion UIDs that have already triggered their initial burst
var spawned_explosion_uids: Dictionary = {}

var _rng := RandomNumberGenerator.new()

func _ready():
	_rng.randomize()
	_init_tracer_multimesh()
	_init_exhaust_multimesh()
	_init_smoke_multimesh()
	_init_spark_multimesh()
	_init_flash_multimesh()
	_init_flash_lights()

# ==============================================================================
# 1. INITIALIZATION: MESHES, SHADERS & MULTIMESH BATCHES
# ==============================================================================

func _build_crossed_fin_mesh(half_width: float, length: float) -> ArrayMesh:
	# Builds two perpendicular crossed quads along the Z axis (-length*0.5 .. +length*0.5)
	# UV.y = 0.0 at front tip (-Z), UV.y = 1.0 at tail (+Z)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var z_front := -length * 0.5
	var z_back := length * 0.5

	# Vertical fin (Y axis)
	verts.append(Vector3(0.0,  half_width, z_front)); uvs.append(Vector2(0.0, 0.0))
	verts.append(Vector3(0.0, -half_width, z_front)); uvs.append(Vector2(1.0, 0.0))
	verts.append(Vector3(0.0, -half_width, z_back));  uvs.append(Vector2(1.0, 1.0))

	verts.append(Vector3(0.0,  half_width, z_front)); uvs.append(Vector2(0.0, 0.0))
	verts.append(Vector3(0.0, -half_width, z_back));  uvs.append(Vector2(1.0, 1.0))
	verts.append(Vector3(0.0,  half_width, z_back));  uvs.append(Vector2(0.0, 1.0))

	# Horizontal fin (X axis)
	verts.append(Vector3( half_width, 0.0, z_front)); uvs.append(Vector2(0.0, 0.0))
	verts.append(Vector3(-half_width, 0.0, z_front)); uvs.append(Vector2(1.0, 0.0))
	verts.append(Vector3(-half_width, 0.0, z_back));  uvs.append(Vector2(1.0, 1.0))

	verts.append(Vector3( half_width, 0.0, z_front)); uvs.append(Vector2(0.0, 0.0))
	verts.append(Vector3(-half_width, 0.0, z_back));  uvs.append(Vector2(1.0, 1.0))
	verts.append(Vector3( half_width, 0.0, z_back));  uvs.append(Vector2(0.0, 1.0))

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

func _init_tracer_multimesh():
	var shd := Shader.new()
	shd.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

void fragment() {
	// Cross-sectional core intensity (brightest along center spine UV.x = 0.5)
	float radial = 1.0 - abs(UV.x * 2.0 - 1.0);
	radial = pow(clamp(radial, 0.0, 1.0), 1.6);

	// Longitudinal taper: white-hot leading tip (UV.y ~ 0.08), long glowing tail (UV.y -> 1.0)
	float head_ramp = smoothstep(0.0, 0.08, UV.y);
	float tail_fade = pow(clamp(1.0 - UV.y, 0.0, 1.0), 1.35);
	float profile = head_ramp * tail_fade;

	float core = pow(radial, 3.0) * smoothstep(0.55, 0.05, UV.y);
	vec3 col = mix(COLOR.rgb, vec3(1.0, 0.98, 0.92), core);
	ALBEDO = col * (1.8 * radial * profile);
	ALPHA = clamp(radial * profile * COLOR.a, 0.0, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shd

	var mesh := _build_crossed_fin_mesh(0.14, 1.0)
	mesh.surface_set_material(0, mat)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = MAX_TRACERS
	mm.visible_instance_count = 0
	mm.mesh = mesh

	tracer_mmi = MultiMeshInstance3D.new()
	tracer_mmi.name = "TracerMultiMesh"
	tracer_mmi.multimesh = mm
	tracer_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(tracer_mmi)

func _init_exhaust_multimesh():
	var shd := Shader.new()
	shd.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

void vertex() {
	// Camera-facing billboard quad preserving instance scale
	vec3 scale = vec3(
		length(MODEL_MATRIX[0].xyz),
		length(MODEL_MATRIX[1].xyz),
		length(MODEL_MATRIX[2].xyz)
	);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(INV_VIEW_MATRIX[0].xyz * scale.x, 0.0),
		vec4(INV_VIEW_MATRIX[1].xyz * scale.y, 0.0),
		vec4(INV_VIEW_MATRIX[2].xyz * scale.z, 0.0),
		MODEL_MATRIX[3]
	);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float glow = pow(clamp(1.0 - r, 0.0, 1.0), 2.2);
	float rays = pow(clamp(1.0 - abs(p.x * p.y) * 6.0, 0.0, 1.0), 3.0) * smoothstep(1.0, 0.15, r);
	float intensity = glow + rays * 0.65;
	vec3 col = mix(COLOR.rgb, vec3(1.0, 1.0, 0.95), pow(glow, 2.5));
	ALBEDO = col * (intensity * 2.2);
	ALPHA = clamp(intensity * COLOR.a, 0.0, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shd

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = MAX_EXHAUST_GLOWS
	mm.visible_instance_count = 0
	mm.mesh = quad

	exhaust_mmi = MultiMeshInstance3D.new()
	exhaust_mmi.name = "ExhaustGlowMultiMesh"
	exhaust_mmi.multimesh = mm
	exhaust_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(exhaust_mmi)

func _init_smoke_multimesh():
	# Volumetric smoke puffs: MultiMesh instances are GPU-aged from a ring buffer
	var shd := Shader.new()
	shd.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform float now;
varying vec4 v_custom;

void vertex() {
	vec3 pos0 = MODEL_MATRIX[3].xyz;
	vec3 vel0 = MODEL_MATRIX[0].xyz;
	float s0 = MODEL_MATRIX[1].x;
	float s1 = MODEL_MATRIX[1].y;
	float max_age = MODEL_MATRIX[1].z;
	float spawn_t = MODEL_MATRIX[2].x;
	float roll0 = MODEL_MATRIX[2].y;
	float roll_speed = MODEL_MATRIX[2].z;
	float age = now - spawn_t;
	float t = age / max_age;

	if (age < 0.0 || t >= 1.0) {
		POSITION = vec4(0.0, 0.0, -2.0, 1.0);
	} else {
		float k = 2.2;
		float decay = (1.0 - exp(-k * age)) / k;
		vec3 center = pos0 + vec3(vel0.x * decay, vel0.y * age, vel0.z * decay);
		float roll = roll0 + roll_speed * age;
		float sc = mix(s0, s1, 1.0 - pow(1.0 - t, 2.0));
		float fade_in = smoothstep(0.0, 0.06, t);
		float fade_out = pow(clamp(1.0 - t, 0.0, 1.0), 1.5);
		float heat = INSTANCE_CUSTOM.x * pow(clamp(1.0 - t * 3.2, 0.0, 1.0), 2.0);

		vec3 right = INV_VIEW_MATRIX[0].xyz;
		vec3 up = INV_VIEW_MATRIX[1].xyz;
		float c = cos(roll);
		float s = sin(roll);
		vec2 q = vec2(VERTEX.x * c - VERTEX.y * s, VERTEX.x * s + VERTEX.y * c) * sc;
		vec3 world = center + right * q.x + up * q.y;
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));

		COLOR = vec4(COLOR.rgb, COLOR.a * fade_in * fade_out);
		v_custom = vec4(roll, heat, INSTANCE_CUSTOM.y, t);
	}
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	if (r > 1.0) {
		discard;
	}
	// Multi-lobed procedural puff edge so smoke looks organic & billowy
	float theta = atan(p.y, p.x);
	float lobe = 0.08 * sin(theta * 3.0 + v_custom.z * 6.2831)
	           + 0.05 * cos(theta * 5.0 - v_custom.x * 2.0);
	float eff_r = clamp(r + lobe * smoothstep(0.15, 0.85, r), 0.0, 1.0);
	float puff_alpha = pow(1.0 - eff_r * eff_r, 1.75);

	// Subtle hemispherical self-shading (lighter top, slightly denser bottom)
	float shade = mix(0.84, 1.08, clamp(p.y * 0.5 + 0.5, 0.0, 1.0));
	// Warm internal fire glow when v_custom.y > 0.0 (fresh missile exhaust or explosion core)
	vec3 base_col = COLOR.rgb * shade;
	vec3 fire_col = vec3(1.0, 0.55, 0.15) * (v_custom.y * (1.0 - eff_r * 0.65) * 1.6);

	ALBEDO = base_col + fire_col;
	ALPHA = clamp(puff_alpha * COLOR.a, 0.0, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shd
	smoke_material = mat

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.instance_count = MAX_SMOKE_PUFFS

	# Initialise every instance so it renders as dead (collapsed by vertex shader)
	var dead_basis := Basis(Vector3.ZERO, Vector3(0.0, 0.0, 0.1), Vector3(-1000.0, 0.0, 0.0))
	var dead_xform := Transform3D(dead_basis, Vector3.ZERO)
	var dead_col := Color(0.0, 0.0, 0.0, 0.0)
	var dead_custom := Color(0.0, 0.0, 0.0, 0.0)
	for i in range(MAX_SMOKE_PUFFS):
		mm.set_instance_transform(i, dead_xform)
		mm.set_instance_color(i, dead_col)
		mm.set_instance_custom_data(i, dead_custom)

	mm.visible_instance_count = MAX_SMOKE_PUFFS
	mm.mesh = quad

	smoke_mmi = MultiMeshInstance3D.new()
	smoke_mmi.name = "SmokePuffMultiMesh"
	smoke_mmi.multimesh = mm
	smoke_mmi.custom_aabb = AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7))
	smoke_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(smoke_mmi)

func _init_spark_multimesh():
	# Reuses crossed-fin geometry with a hot spark shader for explosion shrapnel streaks
	var shd := Shader.new()
	shd.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

void fragment() {
	float radial = pow(clamp(1.0 - abs(UV.x * 2.0 - 1.0), 0.0, 1.0), 1.5);
	float profile = smoothstep(0.0, 0.12, UV.y) * pow(clamp(1.0 - UV.y, 0.0, 1.0), 1.2);
	vec3 col = mix(COLOR.rgb, vec3(1.0, 0.98, 0.85), pow(radial, 2.5) * (1.0 - UV.y * 0.7));
	ALBEDO = col * (2.4 * radial * profile);
	ALPHA = clamp(radial * profile * COLOR.a, 0.0, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shd

	var mesh := _build_crossed_fin_mesh(0.18, 1.0)
	mesh.surface_set_material(0, mat)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = MAX_SPARK_STREAKS
	mm.visible_instance_count = 0
	mm.mesh = mesh

	spark_mmi = MultiMeshInstance3D.new()
	spark_mmi.name = "SparkStreakMultiMesh"
	spark_mmi.multimesh = mm
	spark_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(spark_mmi)

func _init_flash_multimesh():
	# Stylized anime/arcade starburst flash + crisp expanding shockwave ring
	var shd := Shader.new()
	shd.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

varying vec4 v_custom;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	float angle = INSTANCE_CUSTOM.x;
	float s = sin(angle);
	float c = cos(angle);
	vec3 scale = vec3(
		length(MODEL_MATRIX[0].xyz),
		length(MODEL_MATRIX[1].xyz),
		length(MODEL_MATRIX[2].xyz)
	);
	vec3 right = (INV_VIEW_MATRIX[0].xyz * c + INV_VIEW_MATRIX[1].xyz * s) * scale.x;
	vec3 up    = (-INV_VIEW_MATRIX[0].xyz * s + INV_VIEW_MATRIX[1].xyz * c) * scale.y;
	vec3 fwd   = INV_VIEW_MATRIX[2].xyz * scale.z;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(right, 0.0),
		vec4(up, 0.0),
		vec4(fwd, 0.0),
		MODEL_MATRIX[3]
	);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	if (r > 1.0) {
		discard;
	}
	float progress = v_custom.y; // 0.0 -> 1.0

	// 1. Central hot flash core (fades quickly in first 35% of life)
	float core_life = clamp(1.0 - progress * 2.6, 0.0, 1.0);
	float core = pow(clamp(1.0 - r * 1.35, 0.0, 1.0), 2.4) * core_life;

	// 2. Anime/arcade 4-point & diagonal starburst spikes
	float spk_main = pow(clamp(1.0 - min(abs(p.x), abs(p.y)) * 11.0, 0.0, 1.0), 2.5) * pow(clamp(1.0 - r, 0.0, 1.0), 1.4);
	vec2 pr = vec2(p.x + p.y, p.x - p.y) * 0.7071;
	float spk_diag = pow(clamp(1.0 - min(abs(pr.x), abs(pr.y)) * 15.0, 0.0, 1.0), 2.5) * pow(clamp(1.0 - r * 1.25, 0.0, 1.0), 1.6);
	float spikes = (spk_main + spk_diag * 0.6) * clamp(1.0 - progress * 1.8, 0.0, 1.0);

	// 3. Expanding crisp shockwave ring
	float ring_r = mix(0.18, 0.92, pow(progress, 0.65));
	float ring_w = mix(0.09, 0.035, progress);
	float ring = exp(-pow((r - ring_r) / max(ring_w, 0.01), 2.0)) * (1.0 - progress);

	float total = core * 1.8 + spikes * 1.5 + ring * 1.35;
	vec3 col = mix(COLOR.rgb, vec3(1.0, 0.99, 0.92), clamp(core + spikes * 0.6, 0.0, 1.0));
	ALBEDO = col * total * 2.0;
	ALPHA = clamp(total * COLOR.a, 0.0, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shd

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.instance_count = MAX_FLASH_BURSTS
	mm.visible_instance_count = 0
	mm.mesh = quad

	flash_mmi = MultiMeshInstance3D.new()
	flash_mmi.name = "ExplosionFlashMultiMesh"
	flash_mmi.multimesh = mm
	flash_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flash_mmi)

func _init_flash_lights():
	for i in range(4):
		var light := OmniLight3D.new()
		light.name = "ExplosionLight_%d" % i
		light.light_color = Color(1.0, 0.68, 0.28)
		light.omni_range = 120.0
		light.light_energy = 0.0
		light.shadow_enabled = false
		light.visible = false
		add_child(light)
		flash_lights.append({
			"node": light,
			"age": 1.0,
			"max_age": 0.25,
			"peak_energy": 0.0
		})

# ==============================================================================
# 2. PER-FRAME UPDATE ENTRY POINT
# ==============================================================================

# PERF: per-stage time (usec summed) and counts, read and reset by main.gd's perf logger
var perf_us := [0, 0, 0, 0, 0]
var perf_frames: int = 0

func update_vfx(delta: float, active_weapons: Array, active_explosions: Array):
	vfx_time += delta
	var t0 := Time.get_ticks_usec()
	_process_active_weapons(delta, active_weapons)
	var t1 := Time.get_ticks_usec()
	_process_active_explosions(delta, active_explosions)
	var t2 := Time.get_ticks_usec()
	smoke_material.set_shader_parameter("now", vfx_time)
	var t3 := Time.get_ticks_usec()
	_step_and_upload_sparks(delta)
	var t4 := Time.get_ticks_usec()
	_step_and_upload_flashes(delta)
	var t5 := Time.get_ticks_usec()
	perf_us[0] += t1 - t0
	perf_us[1] += t2 - t1
	perf_us[2] += t3 - t2
	perf_us[3] += t4 - t3
	perf_us[4] += t5 - t4
	perf_frames += 1

func perf_report() -> String:
	var n: float = max(perf_frames, 1) * 1000.0
	var s := "PERF vfx split (ms per frame): weapons %.2f | explosions %.2f | smoke step %.2f (%d puffs) | sparks %.2f (%d) | flashes %.2f (%d)" % [
		perf_us[0] / n, perf_us[1] / n, perf_us[2] / n, min(smoke_spawned, MAX_SMOKE_PUFFS), perf_us[3] / n, spark_streaks.size(), perf_us[4] / n, flash_bursts.size()]
	perf_us = [0, 0, 0, 0, 0]
	perf_frames = 0
	return s

# ==============================================================================
# 3. WEAPONS: BULLET TRACERS, EXHAUST GLOWS & PUFFING SMOKE TRAILS
# ==============================================================================

func _process_active_weapons(_delta: float, active_weapons: Array):
	var tracer_mm: MultiMesh = tracer_mmi.multimesh
	var exhaust_mm: MultiMesh = exhaust_mmi.multimesh

	var tracer_count: int = 0
	var exhaust_count: int = 0
	var active_slot_ids: Dictionary = {}

	for i in range(active_weapons.size()):
		var w: Dictionary = active_weapons[i]
		var w_type: int = int(w.get("type", -1))
		var life_rem: float = float(w.get("life_remain", 0.0))
		var slot_id: int = int(w.get("slot_id", -1))
		var pos: Vector3 = w.get("pos", Vector3.ZERO)
		var prev_pos: Vector3 = w.get("prev_pos", pos)
		var vel: Vector3 = w.get("vel", Vector3.ZERO)

		# ------------------------------------------------------------------
		# A. Bullet & Debris Tracers (Thin high-contrast glowing streaks)
		# ------------------------------------------------------------------
		if (w_type == WPN_GUN or w_type == WPN_DEBRIS) and life_rem > 0.0:
			if tracer_count < MAX_TRACERS:
				var seg: Vector3 = pos - prev_pos
				var seg_len: float = seg.length()
				var dir: Vector3 = Vector3.FORWARD
				if seg_len > 0.01:
					dir = seg / seg_len
				elif vel.length_squared() > 0.01:
					dir = vel.normalized()

				# DCS / War Thunder / Ace Combat style thin elongated tracer streak
				var tracer_len: float = clamp(max(seg_len * 0.95, 11.0), 7.0, 22.0)
				var width_scale: float = 1.0
				var col := Color(1.0, 0.78, 0.22, 0.96) # Warm 20mm Vulcan yellow-orange tracer
				if w_type == WPN_DEBRIS:
					tracer_len = clamp(max(seg_len * 0.85, 4.5), 3.0, 10.0)
					width_scale = 1.25
					col = Color(1.0, 0.48, 0.14, 0.90)

				var mid_pos: Vector3 = pos - dir * (tracer_len * 0.45)
				var basis := _basis_from_forward(dir, Vector3(width_scale, width_scale, tracer_len))
				tracer_mm.set_instance_transform(tracer_count, Transform3D(basis, mid_pos))
				tracer_mm.set_instance_color(tracer_count, col)
				tracer_count += 1
			continue

		# ------------------------------------------------------------------
		# B. Missiles, Rockets & Flares (Flying phase: life_remain > 0.0)
		# ------------------------------------------------------------------
		var is_propelled_missile: bool = (
			w_type == WPN_AIM9 or w_type == WPN_AIM9X or
			w_type == WPN_AIM120 or w_type == WPN_AGM65 or
			w_type == WPN_ROCKET
		)
		var is_flare: bool = (w_type == WPN_FLARE)

		if (is_propelled_missile or is_flare) and life_rem > 0.0:
			active_slot_ids[slot_id] = true

			# 1. Rocket motor / Flare core glow at tail
			if exhaust_count < MAX_EXHAUST_GLOWS:
				var tfm: Transform3D = w.get("transform", Transform3D.IDENTITY)
				# In Godot right-handed coordinates, -Z is nose forward, +Z is tail
				var tail_offset: float = 1.6 if is_propelled_missile else 0.0
				var glow_pos: Vector3 = pos + tfm.basis.z * tail_offset
				var glow_size: float = _rng.randf_range(2.2, 3.1) if is_propelled_missile else _rng.randf_range(3.2, 4.4)
				var glow_col := Color(1.0, 0.72, 0.28, 0.95) if is_propelled_missile else Color(1.0, 0.92, 0.60, 1.0)
				var glow_basis := Basis.IDENTITY.scaled(Vector3(glow_size, glow_size, glow_size))
				exhaust_mm.set_instance_transform(exhaust_count, Transform3D(glow_basis, glow_pos))
				exhaust_mm.set_instance_color(exhaust_count, glow_col)
				exhaust_count += 1

			# 2. Emit OGL2-style puffing smoke trail along world path
			var tfm_w: Transform3D = w.get("transform", Transform3D.IDENTITY)
			var emit_pos: Vector3 = pos + tfm_w.basis.z * (1.8 if is_propelled_missile else 0.0)
			if not weapon_last_trail_pos.has(slot_id):
				weapon_last_trail_pos[slot_id] = emit_pos
				# Initial launch puff burst off the rail
				if is_propelled_missile:
					for p_i in range(4):
						var jitter := Vector3(
							_rng.randf_range(-0.6, 0.6),
							_rng.randf_range(-0.6, 0.6),
							_rng.randf_range(-0.6, 0.6)
						)
						_spawn_smoke_puff(
							emit_pos + jitter,
							vel * 0.08 + jitter * 2.0,
							_rng.randf_range(1.4, 2.1),
							_rng.randf_range(4.8, 6.8),
							_rng.randf_range(1.8, 2.5),
							Color(0.92, 0.92, 0.95, 0.52),
							0.55
						)
			else:
				var last_pos: Vector3 = weapon_last_trail_pos[slot_id]
				var dist: float = last_pos.distance_to(emit_pos)
				var step_dist: float = 3.4 if is_propelled_missile else 2.0
				if dist >= step_dist:
					var steps: int = clampi(int(floor(dist / step_dist)), 1, 12)
					for s_idx in range(1, steps + 1):
						var t_lerp: float = float(s_idx) / float(steps)
						var p_pos: Vector3 = last_pos.lerp(emit_pos, t_lerp)
						var jitter := Vector3(
							_rng.randf_range(-0.22, 0.22),
							_rng.randf_range(-0.22, 0.22),
							_rng.randf_range(-0.22, 0.22)
						)
						if is_propelled_missile:
							_spawn_smoke_puff(
								p_pos + jitter,
								jitter * 1.4 + Vector3(0.0, 0.35, 0.0),
								_rng.randf_range(0.95, 1.35),
								_rng.randf_range(4.5, 6.4),
								_rng.randf_range(2.2, 3.0),
								Color(0.90, 0.91, 0.94, 0.44),
								0.35
							)
						else:
							# Countermeasure flare dense white-gold smoke trail
							_spawn_smoke_puff(
								p_pos + jitter * 0.6,
								jitter * 0.9 + Vector3(0.0, 0.25, 0.0),
								_rng.randf_range(0.75, 1.1),
								_rng.randf_range(2.8, 4.0),
								_rng.randf_range(1.6, 2.2),
								Color(0.98, 0.96, 0.88, 0.55),
								0.5
							)
					weapon_last_trail_pos[slot_id] = emit_pos

	# Clean up trail tracking for slots that finished flying
	var stale_slots := []
	for k in weapon_last_trail_pos.keys():
		if not active_slot_ids.has(k):
			stale_slots.append(k)
	for k in stale_slots:
		weapon_last_trail_pos.erase(k)

	tracer_mm.visible_instance_count = tracer_count
	exhaust_mm.visible_instance_count = exhaust_count

# ==============================================================================
# 4. STYLIZED EXPLOSIONS (FLASH + SHOCKWAVE + SPARKS + BILLOWING SMOKE)
# ==============================================================================

func _process_active_explosions(_delta: float, active_explosions: Array):
	var current_uids: Dictionary = {}
	for i in range(active_explosions.size()):
		var exp_dict: Dictionary = active_explosions[i]
		var uid: int = int(exp_dict.get("uid", 0))
		current_uids[uid] = true
		if not spawned_explosion_uids.has(uid):
			spawned_explosion_uids[uid] = true
			var pos: Vector3 = exp_dict.get("pos", Vector3.ZERO)
			var radius: float = float(exp_dict.get("radius", 25.0))
			var exp_type: int = int(exp_dict.get("exp_type", 0))
			_trigger_stylized_explosion(pos, radius, exp_type)

	# Prune finished explosion UIDs
	if spawned_explosion_uids.size() > 128:
		var to_remove := []
		for uid_key in spawned_explosion_uids.keys():
			if not current_uids.has(uid_key):
				to_remove.append(uid_key)
		for uid_key in to_remove:
			spawned_explosion_uids.erase(uid_key)

func _trigger_stylized_explosion(pos: Vector3, radius: float, exp_type: int):
	var base_scale: float = clamp(radius, 12.0, 95.0)

	# Water plume (exp_type == 1)
	if exp_type == 1:
		for i in range(10):
			var spread := Vector3(
				_rng.randf_range(-0.35, 0.35) * base_scale,
				_rng.randf_range(0.0, 0.25) * base_scale,
				_rng.randf_range(-0.35, 0.35) * base_scale
			)
			var up_vel := Vector3(
				spread.x * 0.6,
				_rng.randf_range(12.0, 28.0),
				spread.z * 0.6
			)
			_spawn_smoke_puff(
				pos + spread,
				up_vel,
				base_scale * 0.28,
				base_scale * 0.95,
				_rng.randf_range(1.6, 2.6),
				Color(0.88, 0.94, 1.0, 0.65),
				0.0
			)
		return

	# 1. Central Starburst Flash + Shockwave Ring (2 layered bursts at different angles)
	_spawn_flash_burst(pos, base_scale * 0.45, base_scale * 2.35, 0.32, _rng.randf_range(0.0, TAU), Color(1.0, 0.72, 0.25, 0.98))
	_spawn_flash_burst(pos, base_scale * 0.35, base_scale * 1.75, 0.22, _rng.randf_range(0.0, TAU), Color(1.0, 0.92, 0.65, 0.95))

	# 2. Trigger pooled OmniLight3D flash
	_activate_flash_light(pos, base_scale)

	# 3. High-velocity directional spark & shrapnel streaks (anime/arcade flair)
	var num_sparks: int = clampi(int(base_scale * 0.65), 16, 32)
	for i in range(num_sparks):
		var dir := Vector3(
			_rng.randf_range(-1.0, 1.0),
			_rng.randf_range(-0.35, 1.0),
			_rng.randf_range(-1.0, 1.0)
		).normalized()
		var speed: float = _rng.randf_range(base_scale * 1.6, base_scale * 3.8)
		var spark_len: float = _rng.randf_range(base_scale * 0.18, base_scale * 0.42)
		var col := Color(1.0, _rng.randf_range(0.55, 0.88), _rng.randf_range(0.15, 0.35), 0.98)
		_spawn_spark_streak(
			pos + dir * (base_scale * 0.08),
			dir * speed,
			spark_len,
			_rng.randf_range(0.32, 0.68),
			col
		)

	# 4. Fiery inner core puffs that rapidly cool into dark billowing charcoal smoke
	var num_core_puffs: int = 8
	for i in range(num_core_puffs):
		var offset := Vector3(
			_rng.randf_range(-1.0, 1.0),
			_rng.randf_range(-0.4, 0.9),
			_rng.randf_range(-1.0, 1.0)
		).normalized() * _rng.randf_range(0.05, 0.35) * base_scale
		var vel := offset * _rng.randf_range(1.2, 2.2) + Vector3(0.0, _rng.randf_range(3.5, 8.5), 0.0)
		_spawn_smoke_puff(
			pos + offset,
			vel,
			base_scale * _rng.randf_range(0.28, 0.45),
			base_scale * _rng.randf_range(0.95, 1.45),
			_rng.randf_range(1.4, 2.4),
			Color(0.26, 0.24, 0.23, 0.78),
			1.25 # Starts with strong internal orange-red fire glow
		)

	# 5. Outer lingering dark smoke cloud ring
	var num_smoke_puffs: int = 10
	for i in range(num_smoke_puffs):
		var angle: float = (TAU * float(i) / float(num_smoke_puffs)) + _rng.randf_range(-0.25, 0.25)
		var ring_dir := Vector3(cos(angle), _rng.randf_range(-0.2, 0.45), sin(angle)).normalized()
		var start_p := pos + ring_dir * (base_scale * _rng.randf_range(0.15, 0.42))
		var vel := ring_dir * (base_scale * _rng.randf_range(0.35, 0.75)) + Vector3(0.0, _rng.randf_range(2.5, 6.5), 0.0)
		var shade: float = _rng.randf_range(0.16, 0.30)
		_spawn_smoke_puff(
			start_p,
			vel,
			base_scale * _rng.randf_range(0.32, 0.52),
			base_scale * _rng.randf_range(1.15, 1.75),
			_rng.randf_range(2.2, 3.6),
			Color(shade, shade * 0.97, shade * 0.95, 0.72),
			0.55
		)

# ==============================================================================
# 5. PARTICLE POOL STEPPING & MULTIMESH UPLOAD
# ==============================================================================

# Smoke puffs are GPU-aged from a ring buffer: written once at spawn, simulated entirely in vertex shader.
func _spawn_smoke_puff(pos: Vector3, vel: Vector3, start_scale: float, end_scale: float, max_age: float, col: Color, heat: float):
	var slot: int = smoke_head
	smoke_head = (smoke_head + 1) % MAX_SMOKE_PUFFS
	smoke_spawned += 1

	var roll0: float = _rng.randf_range(0.0, TAU)
	var roll_speed: float = _rng.randf_range(-0.8, 0.8)
	var basis := Basis(vel, Vector3(start_scale, end_scale, max(max_age, 0.1)), Vector3(vfx_time, roll0, roll_speed))
	var xform := Transform3D(basis, pos)

	var mm: MultiMesh = smoke_mmi.multimesh
	mm.set_instance_transform(slot, xform)
	mm.set_instance_color(slot, col)
	mm.set_instance_custom_data(slot, Color(heat, _rng.randf(), 0.0, 0.0))

func _spawn_spark_streak(pos: Vector3, vel: Vector3, length: float, max_age: float, col: Color):
	if spark_streaks.size() >= MAX_SPARK_STREAKS:
		spark_streaks.pop_front()
	spark_streaks.append({
		"pos": pos,
		"vel": vel,
		"len": length,
		"age": 0.0,
		"max_age": max(max_age, 0.08),
		"col": col
	})

func _step_and_upload_sparks(delta: float):
	var mm: MultiMesh = spark_mmi.multimesh
	var write_idx: int = 0
	var count: int = spark_streaks.size()

	for i in range(count):
		var sp: Dictionary = spark_streaks[i]
		var age: float = float(sp["age"]) + delta
		var max_age: float = float(sp["max_age"])
		if age >= max_age:
			continue

		sp["age"] = age
		var vel: Vector3 = sp["vel"]
		vel = vel * max(1.0 - delta * 2.5, 0.2) + Vector3(0.0, -18.0 * delta, 0.0)
		sp["vel"] = vel
		var pos: Vector3 = (sp["pos"] as Vector3) + vel * delta
		sp["pos"] = pos

		var t: float = clamp(age / max_age, 0.0, 1.0)
		var speed: float = vel.length()
		var dir: Vector3 = vel / max(speed, 0.001)
		var cur_len: float = float(sp["len"]) * (1.0 - t * 0.55)
		var base_col: Color = sp["col"]
		var alpha: float = base_col.a * (1.0 - t * t)

		var basis := _basis_from_forward(dir, Vector3(1.1, 1.1, max(cur_len, 0.5)))
		mm.set_instance_transform(write_idx, Transform3D(basis, pos))
		mm.set_instance_color(write_idx, Color(base_col.r, base_col.g, base_col.b, alpha))

		spark_streaks[write_idx] = sp
		write_idx += 1

	spark_streaks.resize(write_idx)
	mm.visible_instance_count = write_idx

func _spawn_flash_burst(pos: Vector3, start_scale: float, end_scale: float, max_age: float, roll: float, col: Color):
	if flash_bursts.size() >= MAX_FLASH_BURSTS:
		flash_bursts.pop_front()
	flash_bursts.append({
		"pos": pos,
		"start_scale": start_scale,
		"end_scale": end_scale,
		"age": 0.0,
		"max_age": max(max_age, 0.05),
		"roll": roll,
		"col": col
	})

func _step_and_upload_flashes(delta: float):
	var mm: MultiMesh = flash_mmi.multimesh
	var write_idx: int = 0
	var count: int = flash_bursts.size()

	for i in range(count):
		var fb: Dictionary = flash_bursts[i]
		var age: float = float(fb["age"]) + delta
		var max_age: float = float(fb["max_age"])
		if age >= max_age:
			continue

		fb["age"] = age
		var t: float = clamp(age / max_age, 0.0, 1.0)
		var sc: float = lerpf(float(fb["start_scale"]), float(fb["end_scale"]), pow(t, 0.55))
		var base_col: Color = fb["col"]

		var basis := Basis.IDENTITY.scaled(Vector3(sc, sc, sc))
		mm.set_instance_transform(write_idx, Transform3D(basis, fb["pos"]))
		mm.set_instance_color(write_idx, Color(base_col.r, base_col.g, base_col.b, base_col.a * (1.0 - t)))
		mm.set_instance_custom_data(write_idx, Color(float(fb["roll"]), t, 0.0, 0.0))

		flash_bursts[write_idx] = fb
		write_idx += 1

	flash_bursts.resize(write_idx)
	mm.visible_instance_count = write_idx

	# Step pooled OmniLight3D flashes
	for i in range(flash_lights.size()):
		var fl: Dictionary = flash_lights[i]
		var node: OmniLight3D = fl["node"]
		if not node.visible:
			continue
		var age: float = float(fl["age"]) + delta
		var max_age: float = float(fl["max_age"])
		if age >= max_age:
			node.visible = false
			node.light_energy = 0.0
		else:
			fl["age"] = age
			var t: float = clamp(age / max_age, 0.0, 1.0)
			node.light_energy = float(fl["peak_energy"]) * pow(1.0 - t, 2.2)

func _activate_flash_light(pos: Vector3, scale_radius: float):
	var best_idx: int = 0
	var best_age: float = -1.0
	for i in range(flash_lights.size()):
		var fl: Dictionary = flash_lights[i]
		var node: OmniLight3D = fl["node"]
		if not node.visible:
			best_idx = i
			break
		if float(fl["age"]) > best_age:
			best_age = float(fl["age"])
			best_idx = i

	var slot: Dictionary = flash_lights[best_idx]
	var light: OmniLight3D = slot["node"]
	light.global_position = pos + Vector3(0.0, 2.0, 0.0)
	light.omni_range = clamp(scale_radius * 4.5, 60.0, 320.0)
	slot["age"] = 0.0
	slot["max_age"] = 0.24
	slot["peak_energy"] = clamp(scale_radius * 0.12, 2.5, 6.5)
	light.light_energy = slot["peak_energy"]
	light.visible = true

func _basis_from_forward(fwd_dir: Vector3, scale_vec: Vector3) -> Basis:
	# Constructs a right-handed basis where -Z points along fwd_dir
	var z_axis := -fwd_dir.normalized()
	var up_ref := Vector3.UP if abs(z_axis.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x_axis := up_ref.cross(z_axis).normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	return Basis(x_axis * scale_vec.x, y_axis * scale_vec.y, z_axis * scale_vec.z)
