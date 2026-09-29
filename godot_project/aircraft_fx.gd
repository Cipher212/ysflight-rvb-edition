extends Node3D
class_name AircraftFX

# ==============================================================================
# YSFlight Godot Port - Aircraft Effects Manager (aircraft_fx.gd)
# ==============================================================================
# High-performance 3D visual effects for aircraft:
#   1. Damage smoke (darkening grey puffs proportional to damage, upward drift)
#   2. Dying smoke & fire (thick black smoke + hot burning fire particles)
#   3. High-G wingtip vapour trails (left and right wingtip condensation)
#   4. High-altitude contrails (persistent expanding ice trails above 8000m)
#   5. Crash plumes (burst of smoke/fire + lingering rising ground smoke emitter)
#
# PERFORMANCE ARCHITECTURE:
#   - Zero per-frame node creation; nodes and multi-meshes are allocated once at start.
#   - GPU-aged ring buffers: instances are written once into MultiMesh transforms/colors
#     and simulated entirely inside vertex shaders (billboarding, age expansion, fade).
#   - Zero per-particle CPU work after spawn; vertex shader collapses expired puffs.
#   - Distance-travelled spawn stepping ensures frame-rate independent visual density.
#   - Distance culling skips aircraft farther than 6 km (except ground crash plumes).
#   - Bounded per-frame spawn counts keep CPU time well under the 0.4 ms budget.
# ==============================================================================

const MAX_SMOKE: int = 2048
const MAX_TRAILS: int = 3072
const MAX_SPAWN_DIST_SQ: float = 36000000.0 # 6000 m squared
const CONTRAIL_ALT_M: float = 8000.0
const MAX_PLUMES: int = 8

const SMOKE_SHADER_CODE: String = """
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
	float theta = atan(p.y, p.x);
	float lobe = 0.08 * sin(theta * 3.0 + v_custom.z * 6.2831)
	           + 0.05 * cos(theta * 5.0 - v_custom.x * 2.0);
	float eff_r = clamp(r + lobe * smoothstep(0.15, 0.85, r), 0.0, 1.0);
	float puff_alpha = pow(1.0 - eff_r * eff_r, 1.75);

	float shade = mix(0.84, 1.08, clamp(p.y * 0.5 + 0.5, 0.0, 1.0));
	vec3 base_col = COLOR.rgb * shade;
	vec3 fire_col = vec3(1.0, 0.55, 0.15) * (v_custom.y * (1.0 - eff_r * 0.65) * 1.6);

	ALBEDO = base_col + fire_col;
	ALPHA = clamp(puff_alpha * COLOR.a, 0.0, 1.0);
}
"""

const TRAILS_SHADER_CODE: String = """
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
		float k = 1.2;
		float decay = (1.0 - exp(-k * age)) / k;
		vec3 center = pos0 + vec3(vel0.x * decay, vel0.y * age, vel0.z * decay);
		float roll = roll0 + roll_speed * age;
		float sc = mix(s0, s1, 1.0 - pow(1.0 - t, 2.0));
		float fade_in = smoothstep(0.0, 0.06, t);
		float fade_out = pow(clamp(1.0 - t, 0.0, 1.0), 1.35);

		vec3 right = INV_VIEW_MATRIX[0].xyz;
		vec3 up = INV_VIEW_MATRIX[1].xyz;
		float c = cos(roll);
		float s = sin(roll);
		vec2 q = vec2(VERTEX.x * c - VERTEX.y * s, VERTEX.x * s + VERTEX.y * c) * sc;
		vec3 world = center + right * q.x + up * q.y;
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));

		COLOR = vec4(COLOR.rgb, COLOR.a * fade_in * fade_out);
		v_custom = vec4(roll, 0.0, INSTANCE_CUSTOM.y, t);
	}
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	if (r > 1.0) {
		discard;
	}
	float theta = atan(p.y, p.x);
	float lobe = 0.06 * sin(theta * 3.0 + v_custom.z * 6.2831)
	           + 0.04 * cos(theta * 4.0 - v_custom.x * 2.0);
	float eff_r = clamp(r + lobe * smoothstep(0.15, 0.85, r), 0.0, 1.0);
	float puff_alpha = pow(clamp(1.0 - eff_r, 0.0, 1.0), 1.5);

	ALBEDO = COLOR.rgb;
	ALPHA = clamp(puff_alpha * COLOR.a, 0.0, 1.0);
}
"""

var main: Node = null
var ysflight_sim: YSFlightSimulation = null
var controls: Node = null

var smoke_mmi: MultiMeshInstance3D = null
var trails_mmi: MultiMeshInstance3D = null

var smoke_material: ShaderMaterial = null
var trails_material: ShaderMaterial = null

var smoke_head: int = 0
var trails_head: int = 0
var smoke_spawned: int = 0
var trails_spawned: int = 0
var fx_time: float = 0.0

var _rng := RandomNumberGenerator.new()
# Maps aircraft_key -> { source_name: Vector3 }
var _last_sources: Dictionary = {}
# Active ground plume emitters: Array of Dictionary { pos: Vector3, age: float, timer: float }
var _active_plumes: Array = []

func _ready() -> void:
	_rng.randomize()
	_init_smoke_multimesh()
	_init_trails_multimesh()

func setup(p_main: Node, p_sim: YSFlightSimulation, p_controls: Node) -> void:
	main = p_main
	ysflight_sim = p_sim
	controls = p_controls

func _init_smoke_multimesh() -> void:
	var shd := Shader.new()
	shd.code = SMOKE_SHADER_CODE
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
	mm.instance_count = MAX_SMOKE

	var dead_basis := Basis(Vector3.ZERO, Vector3(0.0, 0.0, 0.1), Vector3(-1000.0, 0.0, 0.0))
	var dead_xform := Transform3D(dead_basis, Vector3.ZERO)
	var dead_col := Color(0.0, 0.0, 0.0, 0.0)
	var dead_custom := Color(0.0, 0.0, 0.0, 0.0)
	for i in range(MAX_SMOKE):
		mm.set_instance_transform(i, dead_xform)
		mm.set_instance_color(i, dead_col)
		mm.set_instance_custom_data(i, dead_custom)

	mm.visible_instance_count = MAX_SMOKE
	mm.mesh = quad

	smoke_mmi = MultiMeshInstance3D.new()
	smoke_mmi.name = "AircraftSmokeMultiMesh"
	smoke_mmi.multimesh = mm
	smoke_mmi.custom_aabb = AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7))
	smoke_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(smoke_mmi)

func _init_trails_multimesh() -> void:
	var shd := Shader.new()
	shd.code = TRAILS_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shd
	trails_material = mat

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.instance_count = MAX_TRAILS

	var dead_basis := Basis(Vector3.ZERO, Vector3(0.0, 0.0, 0.1), Vector3(-1000.0, 0.0, 0.0))
	var dead_xform := Transform3D(dead_basis, Vector3.ZERO)
	var dead_col := Color(0.0, 0.0, 0.0, 0.0)
	var dead_custom := Color(0.0, 0.0, 0.0, 0.0)
	for i in range(MAX_TRAILS):
		mm.set_instance_transform(i, dead_xform)
		mm.set_instance_color(i, dead_col)
		mm.set_instance_custom_data(i, dead_custom)

	mm.visible_instance_count = MAX_TRAILS
	mm.mesh = quad

	trails_mmi = MultiMeshInstance3D.new()
	trails_mmi.name = "AircraftTrailsMultiMesh"
	trails_mmi.multimesh = mm
	trails_mmi.custom_aabb = AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7))
	trails_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(trails_mmi)

func _spawn_smoke(pos: Vector3, vel: Vector3, s0: float, s1: float, life: float, col: Color, heat: float = 0.0) -> void:
	var slot: int = smoke_head
	smoke_head = (smoke_head + 1) % MAX_SMOKE
	smoke_spawned += 1

	var roll0: float = _rng.randf_range(0.0, TAU)
	var roll_speed: float = _rng.randf_range(-0.8, 0.8)
	var basis := Basis(vel, Vector3(s0, s1, max(life, 0.1)), Vector3(fx_time, roll0, roll_speed))
	var xform := Transform3D(basis, pos)

	var mm: MultiMesh = smoke_mmi.multimesh
	mm.set_instance_transform(slot, xform)
	mm.set_instance_color(slot, col)
	mm.set_instance_custom_data(slot, Color(heat, _rng.randf(), 0.0, 0.0))

func _spawn_trail(pos: Vector3, vel: Vector3, s0: float, s1: float, life: float, col: Color) -> void:
	var slot: int = trails_head
	trails_head = (trails_head + 1) % MAX_TRAILS
	trails_spawned += 1

	var roll0: float = _rng.randf_range(0.0, TAU)
	var roll_speed: float = _rng.randf_range(-0.5, 0.5)
	var basis := Basis(vel, Vector3(s0, s1, max(life, 0.1)), Vector3(fx_time, roll0, roll_speed))
	var xform := Transform3D(basis, pos)

	var mm: MultiMesh = trails_mmi.multimesh
	mm.set_instance_transform(slot, xform)
	mm.set_instance_color(slot, col)
	mm.set_instance_custom_data(slot, Color(0.0, _rng.randf(), 0.0, 0.0))

# Steps a source along distance travelled. Leftover distance is preserved so puff density is uniform.
func _step_source(src: Dictionary, src_name: String, emit_pos: Vector3, spacing: float, is_smoke: bool, vel: Vector3, s0: float, s1: float, life: float, col: Color, heat: float = 0.0) -> void:
	if not src.has(src_name):
		src[src_name] = emit_pos
		return

	var last_p: Vector3 = src[src_name]
	var dist: float = last_p.distance_to(emit_pos)
	if dist >= spacing:
		if dist > spacing * 12.0:
			# Sudden jump or teleport: avoid massive spawn bursts
			src[src_name] = emit_pos
			return
		var dir: Vector3 = (emit_pos - last_p) / dist
		var steps: int = clampi(int(dist / spacing), 1, 6)
		for s_idx in range(1, steps + 1):
			var p_pos: Vector3 = last_p + dir * (spacing * float(s_idx))
			if is_smoke:
				_spawn_smoke(p_pos, vel, s0, s1, life, col, heat)
			else:
				_spawn_trail(p_pos, vel, s0, s1, life, col)
		src[src_name] = last_p + dir * (spacing * float(steps))

func _get_density_mult() -> float:
	if main != null and main.benchmark_mode:
		return 1.0 # Benchmark enforces Medium
	var density: String = "Medium"
	if controls != null:
		density = str(controls.get_value("fx_density", "Medium"))
	match density:
		"Low":
			return 2.0
		"High":
			return 0.7
		_:
			return 1.0

func update_fx(delta: float, camera: Camera3D, air_tfms: Dictionary) -> void:
	if ysflight_sim == null:
		if main != null and main.ysflight_sim != null:
			ysflight_sim = main.ysflight_sim
		else:
			return

	fx_time += delta
	smoke_material.set_shader_parameter("now", fx_time)
	trails_material.set_shader_parameter("now", fx_time)

	var spacing_mult: float = _get_density_mult()

	# Fetch aircraft and crash events from C++ simulation
	var fx_state: Dictionary = ysflight_sim.get_aircraft_fx_state()
	var aircraft: PackedFloat32Array = fx_state.get("aircraft", PackedFloat32Array())
	var crashes: PackedFloat32Array = fx_state.get("crashes", PackedFloat32Array())

	# --------------------------------------------------------------------------
	# 1. Ground Crashes: PackedFloat32Array stride 5: [x, y, z, on_water, radius]
	# --------------------------------------------------------------------------
	var num_crashes: int = crashes.size() / 5
	for c_idx in range(num_crashes):
		var base: int = c_idx * 5
		var cx: float = crashes[base]
		var cy: float = crashes[base + 1]
		var cz: float = crashes[base + 2]
		var on_water: float = crashes[base + 3]
		# NOTHING over water
		if on_water > 0.5:
			continue

		var crash_pos := Vector3(cx, cy, cz)

		# Initial burst: 10 large dark puffs (life 8 s, size 8 -> 30 m)
		for b_i in range(10):
			var b_jitter := Vector3(
				_rng.randf_range(-3.0, 3.0),
				_rng.randf_range(0.0, 2.0),
				_rng.randf_range(-3.0, 3.0)
			)
			var b_vel := Vector3(
				_rng.randf_range(-4.0, 4.0),
				_rng.randf_range(3.0, 8.0),
				_rng.randf_range(-4.0, 4.0)
			)
			_spawn_smoke(
				crash_pos + b_jitter,
				b_vel,
				8.0,
				30.0,
				8.0,
				Color(0.18, 0.17, 0.16, 0.8),
				0.0
			)

		# 6 fire puffs (heat 1.0)
		for f_i in range(6):
			var f_jitter := Vector3(
				_rng.randf_range(-1.5, 1.5),
				_rng.randf_range(0.0, 1.5),
				_rng.randf_range(-1.5, 1.5)
			)
			var f_vel := Vector3(
				_rng.randf_range(-2.0, 2.0),
				_rng.randf_range(2.0, 5.0),
				_rng.randf_range(-2.0, 2.0)
			)
			_spawn_smoke(
				crash_pos + f_jitter,
				f_vel,
				4.0,
				2.0,
				0.8,
				Color(1.0, 0.55, 0.15, 0.9),
				1.0
			)

		# Plume emitter: at most 8 active plume emitters (drop the oldest)
		while _active_plumes.size() >= MAX_PLUMES:
			_active_plumes.pop_front()
		_active_plumes.append({
			"pos": crash_pos,
			"age": 0.0,
			"timer": 0.0
		})

	# --------------------------------------------------------------------------
	# 2. Step Active Crash Plumes (Emit regardless of camera distance)
	# --------------------------------------------------------------------------
	var plume_interval: float = 0.25 * spacing_mult
	var surviving_plumes: Array = []
	for p in _active_plumes:
		var p_age: float = float(p["age"]) + delta
		if p_age >= 45.0:
			continue
		p["age"] = p_age
		var p_timer: float = float(p["timer"]) + delta
		var p_pos: Vector3 = p["pos"]

		# Limit max catch-up steps to bound CPU work if delta spikes
		p_timer = min(p_timer, plume_interval * 4.0)
		while p_timer >= plume_interval:
			p_timer -= plume_interval
			# Rising dark puff: velocity (0, 6, 0) plus small random horizontal drift, life 14 s, size 6 -> 40 m
			var drift := Vector3(
				_rng.randf_range(-1.2, 1.2),
				6.0,
				_rng.randf_range(-1.2, 1.2)
			)
			var puff_pos := p_pos + Vector3(
				_rng.randf_range(-1.0, 1.0),
				_rng.randf_range(0.0, 0.5),
				_rng.randf_range(-1.0, 1.0)
			)
			_spawn_smoke(
				puff_pos,
				drift,
				6.0,
				40.0,
				14.0,
				Color(0.14, 0.14, 0.14, 0.75),
				0.0
			)

			# During first 12 s, also a fire puff at the base (heat 0.8, life 0.8 s)
			if p_age <= 12.0:
				var fire_pos := p_pos + Vector3(
					_rng.randf_range(-0.6, 0.6),
					_rng.randf_range(0.0, 0.8),
					_rng.randf_range(-0.6, 0.6)
				)
				_spawn_smoke(
					fire_pos,
					Vector3(0.0, 1.5, 0.0),
					3.5,
					1.5,
					0.8,
					Color(1.0, 0.55, 0.15, 0.85),
					0.8
				)

		p["timer"] = p_timer
		surviving_plumes.append(p)
	_active_plumes = surviving_plumes

	# --------------------------------------------------------------------------
	# 3. Aircraft Effects: PackedFloat32Array stride 18:
	#    [0:key, 1..3:pos, 4..6:vel, 7:damage, 8:state, 9:vapor, 10..12:vap_tip,
	#     13:radius, 14..16:fwd, 17:unused]
	# --------------------------------------------------------------------------
	var cam_pos: Vector3 = camera.global_position if camera != null else Vector3.ZERO
	var seen_keys: Dictionary = {}
	var num_ac: int = aircraft.size() / 18

	for a_idx in range(num_ac):
		var base: int = a_idx * 18
		var key: int = int(aircraft[base])
		var pos := Vector3(aircraft[base + 1], aircraft[base + 2], aircraft[base + 3])
		var vel := Vector3(aircraft[base + 4], aircraft[base + 5], aircraft[base + 6])
		var damage: float = aircraft[base + 7]
		var state: int = int(aircraft[base + 8]) # 0 alive, 1 dying/falling
		var vapor: float = aircraft[base + 9]
		var vap_tip_local := Vector3(aircraft[base + 10], aircraft[base + 11], aircraft[base + 12])
		var radius: float = aircraft[base + 13]
		var forward := Vector3(aircraft[base + 14], aircraft[base + 15], aircraft[base + 16])

		seen_keys[key] = true

		# Distance culling: skip spawning for aircraft farther than 6 km from camera
		if cam_pos.distance_squared_to(pos) > MAX_SPAWN_DIST_SQ:
			if _last_sources.has(key):
				var s_map: Dictionary = _last_sources[key]
				for s_k in s_map.keys():
					s_map[s_k] = pos
			continue

		if not _last_sources.has(key):
			_last_sources[key] = {}
		var src: Dictionary = _last_sources[key]

		# A. Damage smoke: damage >= 0.35 and alive: smoke from aircraft position, spacing 20 m,
		# grey that gets darker with damage (grey 0.45 -> near black 0.12 at damage 1.0),
		# life 4 s + 4 s * damage, size 3 m -> 12 m, slight upward drift.
		if state == 0 and damage >= 0.35:
			var d_norm: float = clamp((damage - 0.35) / 0.65, 0.0, 1.0)
			var shade: float = lerpf(0.45, 0.12, d_norm)
			var dmg_life: float = 4.0 + 4.0 * damage
			_step_source(
				src,
				"dmg",
				pos,
				20.0 * spacing_mult,
				true,
				Vector3(0.0, 1.2, 0.0),
				3.0,
				12.0,
				dmg_life,
				Color(shade, shade, shade, 0.72),
				0.0
			)
		else:
			src.erase("dmg")

		# B. Dying (state 1, killed but still falling): thick black smoke spacing 10 m, life 10 s, size 4 -> 18 m,
		# PLUS fire: bright orange puffs with heat 1.0 spacing 5 m, life 0.6 s, size 3 -> 1 m (burning particles).
		if state == 1:
			_step_source(
				src,
				"dying_smoke",
				pos,
				6.0 * spacing_mult, # tuned after screenshot review: 10 m / 4-18 m / alpha 0.85 read as faint
				true,
				Vector3(0.0, 1.8, 0.0),
				6.0,
				22.0,
				10.0,
				Color(0.08, 0.08, 0.08, 1.0),
				0.0
			)
			_step_source(
				src,
				"dying_fire",
				pos,
				2.5 * spacing_mult, # tuned: 5 m spacing / 3 m puffs showed separate blobs, not a burning trail
				true,
				vel * 0.08,
				5.0,
				1.5,
				0.7,
				Color(1.0, 0.5, 0.1, 1.0),
				1.0
			)
		else:
			src.erase("dying_smoke")
			src.erase("dying_fire")

		# C. Wingtip vapour (vapor 1): two sources, right tip and mirrored left tip (x negated),
		# spacing 6 m, life 0.5 s, white alpha 0.35, size 1.5 -> 4 m.
		if vapor > 0.5:
			var tfm := Transform3D(Basis.IDENTITY, pos)
			if air_tfms.has(key):
				var ac_dict = air_tfms[key]
				if ac_dict is Dictionary and ac_dict.has("transform"):
					tfm = ac_dict["transform"]
			var tip_r: Vector3 = tfm * vap_tip_local
			var tip_l: Vector3 = tfm * Vector3(-vap_tip_local.x, vap_tip_local.y, vap_tip_local.z)
			var vap_spacing: float = 6.0 * spacing_mult
			_step_source(
				src,
				"vap_r",
				tip_r,
				vap_spacing,
				false,
				Vector3.ZERO,
				1.5,
				4.0,
				0.5,
				Color(1.0, 1.0, 1.0, 0.35)
			)
			_step_source(
				src,
				"vap_l",
				tip_l,
				vap_spacing,
				false,
				Vector3.ZERO,
				1.5,
				4.0,
				0.5,
				Color(1.0, 1.0, 1.0, 0.35)
			)
		else:
			src.erase("vap_r")
			src.erase("vap_l")

		# D. Contrails: alive and altitude (pos.y) above CONTRAIL_ALT_M (const 8000.0):
		# from the tail (pos - forward * radius * 0.9), spacing 30 m, life 20 s, white alpha 0.25, size 2 -> 14 m.
		if state == 0 and pos.y > CONTRAIL_ALT_M:
			var tail_pos: Vector3 = pos - forward * (radius * 0.9)
			_step_source(
				src,
				"contrail",
				tail_pos,
				30.0 * spacing_mult,
				false,
				Vector3.ZERO,
				2.0,
				14.0,
				20.0,
				Color(1.0, 1.0, 1.0, 0.25)
			)
		else:
			src.erase("contrail")

	# Clean up stale aircraft keys not seen this frame
	var stale_keys: Array = []
	for k in _last_sources.keys():
		if not seen_keys.has(k):
			stale_keys.append(k)
	for k in stale_keys:
		_last_sources.erase(k)

func perf_report() -> String:
	return "PERF aircraft_fx: smoke head %d (%d spawned) | trails head %d (%d spawned) | plumes %d" % [
		smoke_head, smoke_spawned, trails_head, trails_spawned, _active_plumes.size()
	]
