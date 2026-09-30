extends Node3D

const PuffSystem := preload("res://fx/puff_system.gd")
const BlastGlow := preload("res://fx/blast_glow.gd")

# Explosions from get_active_explosions(): a flash (core + star + shock ring), spark streaks, a short light
# and smoke puffs; nearby blasts also glow on screen (fx/blast_glow.gd). Flashes and sparks are GPU-aged
# ring buffers like the puffs: written once at spawn, no per-frame CPU work. Water hits (YS
# FSEXPLOSION_WATERPLUME) get a white spray instead.

const SPARK_SHADER := preload("res://shaders/spark_streak.gdshader")
const FLASH_SHADER := preload("res://shaders/explosion_flash.gdshader")
const MAX_SPARKS := 384
const MAX_FLASHES := 48
const LIGHT_COUNT := 4
const EXP_WATER_PLUME := 1

var puffs: PuffSystem = null
var blast_glow: BlastGlow = null
var quality: int = 1

var _time: float = 0.0
var _spark_mm: MultiMesh = null
var _flash_mm: MultiMesh = null
var _spark_mat: ShaderMaterial = null
var _flash_mat: ShaderMaterial = null
var _spark_head: int = 0
var _flash_head: int = 0
var _lights: Array[OmniLight3D] = []
var _light_age: PackedFloat32Array = PackedFloat32Array()
var _light_peak: PackedFloat32Array = PackedFloat32Array()
var _seen_uids: Dictionary = {}
var _rng := RandomNumberGenerator.new()

func setup(p_puffs: PuffSystem, p_blast_glow: BlastGlow) -> void:
	puffs = p_puffs
	blast_glow = p_blast_glow

func _ready() -> void:
	_rng.randomize()
	# Dead until spawned: life 0.1 s, spawn time far in the past (packing as in the shaders)
	_spark_mat = _material(SPARK_SHADER)
	var dead_spark := Transform3D(Basis(Vector3.ZERO, Vector3(1.0, 0.1, -1000.0), Vector3.ZERO), Vector3.ZERO)
	_spark_mm = _ring_multimesh("Sparks", _crossed_fin_mesh(0.18, _spark_mat), MAX_SPARKS, dead_spark)
	_flash_mat = _material(FLASH_SHADER)
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = _flash_mat
	var dead_flash := Transform3D(Basis(Vector3.ZERO, Vector3(0.0, 0.0, 0.1), Vector3(-1000.0, 0.0, 0.0)), Vector3.ZERO)
	_flash_mm = _ring_multimesh("Flashes", quad, MAX_FLASHES, dead_flash)
	for i in LIGHT_COUNT:
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.68, 0.28)
		light.shadow_enabled = false
		light.visible = false
		add_child(light)
		_lights.append(light)
	_light_age.resize(LIGHT_COUNT)
	_light_peak.resize(LIGHT_COUNT)

func update(delta: float, explosions: Array) -> void:
	_time += delta
	_spark_mat.set_shader_parameter("now", _time)
	_flash_mat.set_shader_parameter("now", _time)
	var current := {}
	for e in explosions:
		var uid: int = e["uid"]
		current[uid] = true
		if not _seen_uids.has(uid):
			_trigger(e["pos"], float(e["radius"]), int(e["exp_type"]))
	_seen_uids = current
	_step_lights(delta)

func _trigger(pos: Vector3, radius: float, exp_type: int) -> void:
	var s: float = clampf(radius, 12.0, 95.0)
	var n_scale: float = 0.5 if quality <= 0 else 1.0
	if exp_type == EXP_WATER_PLUME:
		# YS gives water plumes the aircraft's radius (~8 m); a jet hitting the sea throws much more spray
		s = maxf(radius * 3.0, 20.0)
		for i in int(10 * n_scale):
			var spread := Vector3(_rng.randf_range(-0.35, 0.35), _rng.randf_range(0.0, 0.25), _rng.randf_range(-0.35, 0.35)) * s
			var up := Vector3(spread.x * 0.6, _rng.randf_range(12.0, 28.0), spread.z * 0.6)
			puffs.spawn(pos + spread, up, s * 0.28, s * 0.95, _rng.randf_range(1.6, 2.6), Color(0.93, 0.94, 0.95, 0.65))
		return

	_spawn_flash(pos, s * 0.45, s * 2.35, 0.32, Color(1.0, 0.72, 0.25, 0.98))
	_spawn_flash(pos, s * 0.35, s * 1.75, 0.22, Color(1.0, 0.92, 0.65, 0.95))
	_start_light(pos, s)
	blast_glow.add(pos, s)
	for i in int(clampi(int(s * 0.5), 12, 24) * n_scale):
		var dir := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.35, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
		_spawn_spark(pos + dir * (s * 0.08), dir * _rng.randf_range(s * 1.6, s * 3.8), _rng.randf_range(s * 0.18, s * 0.42),
			_rng.randf_range(0.32, 0.68), Color(1.0, _rng.randf_range(0.55, 0.88), _rng.randf_range(0.15, 0.35), 0.98))
	# Fire core cooling into dark smoke, then a darker outer cloud
	for i in int(6 * n_scale):
		var off := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.4, 0.9), _rng.randf_range(-1.0, 1.0)).normalized() * _rng.randf_range(0.05, 0.35) * s
		var vel := off * _rng.randf_range(1.2, 2.2) + Vector3(0.0, _rng.randf_range(3.5, 8.5), 0.0)
		puffs.spawn(pos + off, vel, s * _rng.randf_range(0.3, 0.45), s * _rng.randf_range(1.0, 1.5), _rng.randf_range(1.4, 2.4),
			Color(0.2, 0.19, 0.18, 0.8), 1.25)
	var ring: int = int(8 * n_scale)
	for i in ring:
		var angle: float = TAU * float(i) / float(ring) + _rng.randf_range(-0.25, 0.25)
		var ring_dir := Vector3(cos(angle), _rng.randf_range(-0.2, 0.45), sin(angle)).normalized()
		var vel := ring_dir * (s * _rng.randf_range(0.35, 0.75)) + Vector3(0.0, _rng.randf_range(2.5, 6.5), 0.0)
		var shade: float = _rng.randf_range(0.1, 0.2)
		puffs.spawn(pos + ring_dir * (s * _rng.randf_range(0.15, 0.42)), vel, s * _rng.randf_range(0.35, 0.55),
			s * _rng.randf_range(1.2, 1.8), _rng.randf_range(2.2, 3.6), Color(shade, shade, shade, 0.75), 0.5)

# MODEL_MATRIX packing: see shaders/spark_streak.gdshader
func _spawn_spark(pos: Vector3, vel: Vector3, length: float, life: float, color: Color) -> void:
	_spark_mm.set_instance_transform(_spark_head, Transform3D(Basis(vel, Vector3(length, maxf(life, 0.08), _time), Vector3.ZERO), pos))
	_spark_mm.set_instance_color(_spark_head, color)
	_spark_head = (_spark_head + 1) % MAX_SPARKS

# MODEL_MATRIX packing: see shaders/explosion_flash.gdshader
func _spawn_flash(pos: Vector3, size0: float, size1: float, life: float, color: Color) -> void:
	var roll := _rng.randf_range(0.0, TAU)
	_flash_mm.set_instance_transform(_flash_head, Transform3D(Basis(Vector3.ZERO, Vector3(size0, size1, life), Vector3(_time, roll, 0.0)), pos))
	_flash_mm.set_instance_color(_flash_head, color)
	_flash_head = (_flash_head + 1) % MAX_FLASHES

func _start_light(pos: Vector3, s: float) -> void:
	var best := 0
	for i in LIGHT_COUNT: # a free light, else the oldest
		if not _lights[i].visible:
			best = i
			break
		if _light_age[i] > _light_age[best]:
			best = i
	var light := _lights[best]
	light.global_position = pos + Vector3(0.0, 2.0, 0.0)
	light.omni_range = clampf(s * 4.5, 60.0, 320.0)
	_light_age[best] = 0.0
	_light_peak[best] = clampf(s * 0.12, 2.5, 6.5)
	light.light_energy = _light_peak[best]
	light.visible = true

func _step_lights(delta: float) -> void:
	for i in LIGHT_COUNT:
		var light := _lights[i]
		if not light.visible:
			continue
		_light_age[i] += delta
		if _light_age[i] >= 0.24:
			light.visible = false
		else:
			light.light_energy = _light_peak[i] * pow(1.0 - _light_age[i] / 0.24, 2.2)

func _material(shader: Shader) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	return m

func _ring_multimesh(node_name: String, mesh: Mesh, count: int, dead: Transform3D) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	for i in count:
		mm.set_instance_transform(i, dead)
		mm.set_instance_color(i, Color(0.0, 0.0, 0.0, 0.0))
	mm.visible_instance_count = count
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.custom_aabb = AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mm

# Two perpendicular quads along Z (-0.5 .. 0.5), UV.y = 0 at the front tip.
func _crossed_fin_mesh(half_width: float, material: Material) -> ArrayMesh:
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	for side in [Vector3(0.0, half_width, 0.0), Vector3(half_width, 0.0, 0.0)]:
		var f := Vector3(0.0, 0.0, -0.5)
		var k := Vector3(0.0, 0.0, 0.5)
		v.append_array([side + f, -side + f, -side + k, side + f, -side + k, side + k])
		uv.append_array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, material)
	return mesh
