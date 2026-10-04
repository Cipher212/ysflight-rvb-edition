extends Node3D

const PuffSystem := preload("res://fx/puff_system.gd")
const BlastGlow := preload("res://fx/blast_glow.gd")
const WaterSplashFX := preload("res://fx/water_splash_fx.gd")

# Bounded, inexpensive PS2-style sprite explosions using GPU-aged MultiMesh ring buffers.
# Differentiates incidents (gun impact, AAM, ground ordnance, entity crash, water plumes).
# Light pool removed (0 dynamic lights per frame). Black backgrounds add zero to the frame.

const SPARK_SHADER := preload("res://shaders/spark_streak.gdshader")
const FLASH_SHADER := preload("res://shaders/explosion_flash.gdshader")

# Textures (256x256 grayscale explosion puff sprites)
const TEX_EXP01 := preload("res://misc/explosion01.png")
const TEX_EXP02 := preload("res://misc/explosion02.png")
const TEX_EXP03 := preload("res://misc/explosion03.png")
const TEX_EXP04 := preload("res://misc/explosion04.png")
const TEX_EXP05 := preload("res://misc/explosion05.png")

# Ring buffer capacities
const MAX_SPARKS := 384
const MAX_FLASHES := 48

# Incident categories (matching C++ FS_EXPLOSION_INCIDENT enum)
const INCIDENT_UNKNOWN := 0
const INCIDENT_GUN_IMPACT := 1
const INCIDENT_AIR_TO_AIR_MISSILE := 2
const INCIDENT_GROUND_ORDNANCE := 3
const INCIDENT_ENTITY_DESTRUCTION_OR_CRASH := 4
const INCIDENT_CONTINUING_WRECK_FIRE := 5

# YSCE weapon types (matching fsdef.h FSWEAPONTYPE)
const FSWEAPON_GUN := 0
const FSWEAPON_AIM9 := 1
const FSWEAPON_AGM65 := 2
const FSWEAPON_BOMB := 3
const FSWEAPON_ROCKET := 4
const FSWEAPON_FLARE := 5
const FSWEAPON_AIM120 := 6
const FSWEAPON_BOMB250 := 7
const FSWEAPON_BOMB500HD := 9
const FSWEAPON_AIM9X := 10
const FSWEAPON_FUELTANK := 12

const EXP_WATER_PLUME := 1

# Profile tuning constants
# 1. Gun impact: tiny brief spark flash, 0 screen glow, 0 dynamic light
const GUN_FLASH_SIZE_MIN := 0.6
const GUN_FLASH_SIZE_MAX := 1.8
const GUN_FLASH_LIFE := 0.09
const GUN_SPARK_COUNT := 2
const GUN_SPARK_SPEED := 14.0
const GUN_PUFF_LIFE := 0.35

# 2. Air-to-air missile (AAM): fragmentation flash, shrapnel streaks, brief gray smoke
const AAM_FLASH_SIZE_MIN := 8.0
const AAM_FLASH_SIZE_MAX := 22.0
const AAM_FLASH_LIFE := 0.22
const AAM_SPARK_COUNT := 12
const AAM_SPARK_SPEED := 45.0
const AAM_PUFF_COUNT := 4
const AAM_PUFF_LIFE := 1.2

# 3. Ground ordnance - Rocket / AGM: modest fireball, moderate smoke
const ROCKET_FLASH_SIZE_MIN := 6.0
const ROCKET_FLASH_SIZE_MAX := 16.0
const ROCKET_FLASH_LIFE := 0.26
const ROCKET_SPARK_COUNT := 6
const ROCKET_PUFF_COUNT := 3
const ROCKET_PUFF_LIFE := 1.6

# 4. Ground ordnance - Bomb / Heavy ordnance: large fireball, dark smoke
const BOMB_FLASH_SIZE_MIN := 18.0
const BOMB_FLASH_SIZE_MAX := 42.0
const BOMB_FLASH_LIFE := 0.38
const BOMB_SPARK_COUNT := 16
const BOMB_PUFF_COUNT := 8
const BOMB_PUFF_LIFE := 2.4

# 5. Entity destruction / Crash: substantial initial blast, fiery puffs, heavy smoke
const CRASH_FLASH_SIZE_MIN := 24.0
const CRASH_FLASH_SIZE_MAX := 60.0
const CRASH_FLASH_LIFE := 0.45
const CRASH_SPARK_COUNT := 20
const CRASH_PUFF_COUNT := 10
const CRASH_PUFF_LIFE := 3.0

# 6. Sizing multipliers & limits
const HEAVY_BOMB_VISUAL_SCALE := 1.5
const MAX_FLASH_END_WIDTH_NORMAL := 144.0
const MAX_FLASH_END_WIDTH_LOW := 70.0

var puffs: PuffSystem = null
var blast_glow: BlastGlow = null
var quality: int = 1

var _time: float = 0.0
var _spark_mm: MultiMesh = null
var _flash_mm: MultiMesh = null
var _spark_mat: ShaderMaterial = null
var _flash_mat: ShaderMaterial = null
var _atlas_tex: ImageTexture = null
var _water_splash: WaterSplashFX = null
var _spark_head: int = 0
var _flash_head: int = 0
var _last_flash_size0: float = 0.0
var _last_flash_size1: float = 0.0
var _seen_uids: Dictionary = {}
var _rng := RandomNumberGenerator.new()

var _initialized: bool = false

func setup(p_puffs: PuffSystem, p_blast_glow: BlastGlow) -> void:
	puffs = p_puffs
	blast_glow = p_blast_glow
	_ensure_init()

func _ready() -> void:
	_ensure_init()

func _ensure_init() -> void:
	if _initialized:
		return
	_initialized = true
	_rng.randomize()
	_spark_mat = _material(SPARK_SHADER)
	var dead_spark := Transform3D(Basis(Vector3.ZERO, Vector3(1.0, 0.1, -1000.0), Vector3.ZERO), Vector3.ZERO)
	_spark_mm = _ring_multimesh("Sparks", _crossed_fin_mesh(0.18, _spark_mat), MAX_SPARKS, dead_spark)

	_flash_mat = _material(FLASH_SHADER)
	_build_atlas()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = _flash_mat
	var dead_flash := Transform3D(Basis(Vector3.ZERO, Vector3(0.0, 0.0, 0.1), Vector3(-1000.0, 0.0, 0.0)), Vector3.ZERO)
	_flash_mm = _ring_multimesh("Flashes", quad, MAX_FLASHES, dead_flash)

	if _water_splash == null:
		_water_splash = WaterSplashFX.new()
		_water_splash.name = "WaterSplashFX"
		add_child(_water_splash)
	_water_splash.set_quality(quality)

func set_quality(p_quality: int) -> void:
	quality = p_quality
	if _water_splash != null:
		_water_splash.set_quality(p_quality)

func reset() -> void:
	_ensure_init()
	_seen_uids.clear()
	if _water_splash != null:
		_water_splash.reset()
	if _flash_mm != null:
		var dead_flash := Transform3D(Basis(Vector3.ZERO, Vector3(0.0, 0.0, 0.1), Vector3(-1000.0, 0.0, 0.0)), Vector3.ZERO)
		for i in MAX_FLASHES:
			_flash_mm.set_instance_transform(i, dead_flash)
			_flash_mm.set_instance_color(i, Color(0.0, 0.0, 0.0, 0.0))
		_flash_head = 0
	if _spark_mm != null:
		var dead_spark := Transform3D(Basis(Vector3.ZERO, Vector3(1.0, 0.1, -1000.0), Vector3.ZERO), Vector3.ZERO)
		for i in MAX_SPARKS:
			_spark_mm.set_instance_transform(i, dead_spark)
			_spark_mm.set_instance_color(i, Color(0.0, 0.0, 0.0, 0.0))
		_spark_head = 0

func update(delta: float, explosions: Array) -> void:
	_ensure_init()
	_time += delta
	_spark_mat.set_shader_parameter("now", _time)
	_flash_mat.set_shader_parameter("now", _time)
	if _water_splash != null:
		_water_splash.update(delta)

	var current := {}
	for e in explosions:
		var uid: int = e["uid"]
		current[uid] = true
		if not _seen_uids.has(uid):
			var inc_type := int(e.get("incident_type", INCIDENT_UNKNOWN))
			var wpn_type := int(e.get("weapon_type", -1))
			_trigger(e["pos"], float(e["radius"]), int(e["exp_type"]), inc_type, wpn_type)
	_seen_uids = current

func _trigger(pos: Vector3, radius: float, exp_type: int, incident_type: int = INCIDENT_UNKNOWN, weapon_type: int = -1) -> void:
	# 1. Continuing wreck fire: suppressed from triggering catastrophic explosions
	if incident_type == INCIDENT_CONTINUING_WRECK_FIRE:
		return

	var n_scale: float = 0.5 if quality <= 0 else 1.0

	# 2. Water Plumes (spray, not fireball)
	if exp_type == EXP_WATER_PLUME:
		_trigger_water(pos, radius, incident_type, weapon_type, n_scale)
		return

	# 3. Differentiated Land/Air profiles
	match incident_type:
		INCIDENT_GUN_IMPACT:
			_trigger_gun(pos, radius, n_scale)
		INCIDENT_AIR_TO_AIR_MISSILE:
			_trigger_aam(pos, radius, n_scale)
		INCIDENT_GROUND_ORDNANCE:
			_trigger_ground_ordnance(pos, radius, weapon_type, n_scale)
		INCIDENT_ENTITY_DESTRUCTION_OR_CRASH:
			_trigger_destruction(pos, radius, n_scale)
		_:
			_trigger_fallback(pos, radius, n_scale)

func _trigger_gun(pos: Vector3, radius: float, n_scale: float) -> void:
	var s := clampf(radius * 0.35, GUN_FLASH_SIZE_MIN, GUN_FLASH_SIZE_MAX)
	_spawn_flash(pos, s * 0.5, s * 1.5, GUN_FLASH_LIFE, Color(1.0, 0.95, 0.72, 0.95))
	var spark_count := int(GUN_SPARK_COUNT * n_scale)
	for i in spark_count:
		var dir := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(0.1, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
		_spawn_spark(pos, dir * GUN_SPARK_SPEED, 0.25, 0.15, Color(1.0, 0.85, 0.3, 0.9))
	if puffs != null and quality > 0:
		puffs.spawn(pos, Vector3(0.0, 1.2, 0.0), s * 0.4, s * 1.2, GUN_PUFF_LIFE, Color(0.48, 0.46, 0.44, 0.45), 0.2)

func _trigger_aam(pos: Vector3, radius: float, n_scale: float) -> void:
	var s := clampf(radius * 0.85, AAM_FLASH_SIZE_MIN, AAM_FLASH_SIZE_MAX)
	_spawn_flash(pos, s * 0.4, s * 1.6, AAM_FLASH_LIFE, Color(1.0, 0.92, 0.70, 0.98))
	_spawn_flash(pos, s * 0.25, s * 1.1, AAM_FLASH_LIFE * 0.75, Color(1.0, 0.98, 0.90, 0.95))
	if blast_glow != null and blast_glow.enabled:
		blast_glow.add(pos, s * 0.7)
	var spark_count := int(AAM_SPARK_COUNT * n_scale)
	for i in spark_count:
		var dir := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
		_spawn_spark(pos + dir * (s * 0.05), dir * (AAM_SPARK_SPEED * _rng.randf_range(0.8, 1.3)), s * 0.25, 0.35, Color(1.0, 0.88, 0.4, 0.98))
	if puffs != null:
		var puff_count := int(AAM_PUFF_COUNT * n_scale)
		for i in puff_count:
			var off := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)).normalized() * (s * 0.2)
			var vel := off * 1.5
			puffs.spawn(pos + off, vel, s * 0.3, s * 1.1, AAM_PUFF_LIFE, Color(0.62, 0.62, 0.65, 0.6), 0.5)

func _trigger_ground_ordnance(pos: Vector3, radius: float, weapon_type: int, n_scale: float) -> void:
	if weapon_type == FSWEAPON_ROCKET or weapon_type == FSWEAPON_AGM65:
		var s := clampf(radius * 0.7, ROCKET_FLASH_SIZE_MIN, ROCKET_FLASH_SIZE_MAX)
		_spawn_flash(pos, s * 0.4, s * 1.5, ROCKET_FLASH_LIFE, Color(1.0, 0.82, 0.35, 0.96))
		if blast_glow != null and blast_glow.enabled:
			blast_glow.add(pos, s * 0.6)
		var spark_count := int(ROCKET_SPARK_COUNT * n_scale)
		for i in spark_count:
			var dir := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(0.1, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
			_spawn_spark(pos, dir * _rng.randf_range(s * 1.5, s * 3.0), s * 0.2, 0.4, Color(1.0, 0.75, 0.2, 0.95))
		if puffs != null:
			var puff_count := int(ROCKET_PUFF_COUNT * n_scale)
			for i in puff_count:
				var off := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(0.0, 0.8), _rng.randf_range(-1.0, 1.0)).normalized() * (s * 0.2)
				var vel := off * 1.2 + Vector3(0.0, 4.0, 0.0)
				puffs.spawn(pos + off, vel, s * 0.3, s * 1.3, ROCKET_PUFF_LIFE, Color(0.25, 0.24, 0.23, 0.75), 0.8)
	else:
		# Bomb / Fueltank / Heavy ordnance
		var base_s := clampf(radius, BOMB_FLASH_SIZE_MIN, BOMB_FLASH_SIZE_MAX)

		# Explicit whitelist for 1.5x visual enlargement (FSWEAPON_BOMB, FSWEAPON_BOMB500HD)
		var is_whitelisted_heavy := (weapon_type == FSWEAPON_BOMB or weapon_type == FSWEAPON_BOMB500HD)
		var scale_mult: float = HEAVY_BOMB_VISUAL_SCALE if is_whitelisted_heavy else 1.0
		var s: float = base_s * scale_mult

		# Clamp FINAL visual dimensions against named limits (144m normal, 70m low)
		var max_end_width: float = MAX_FLASH_END_WIDTH_LOW if quality <= 0 else MAX_FLASH_END_WIDTH_NORMAL
		var end_size_1: float = minf(s * 2.2, max_end_width)
		var end_size_2: float = minf(s * 1.6, max_end_width * 0.75)

		_spawn_flash(pos, s * 0.45, end_size_1, BOMB_FLASH_LIFE, Color(1.0, 0.75, 0.25, 0.98))
		_spawn_flash(pos, s * 0.32, end_size_2, BOMB_FLASH_LIFE * 0.8, Color(1.0, 0.90, 0.60, 0.95))

		# Particles, lifetime, and screen glow NOT enlarged alongside flash
		if blast_glow != null and blast_glow.enabled:
			blast_glow.add(pos, base_s)
		var spark_count := int(BOMB_SPARK_COUNT * n_scale)
		for i in spark_count:
			var dir := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.1, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
			_spawn_spark(pos + dir * (base_s * 0.08), dir * _rng.randf_range(base_s * 1.5, base_s * 3.5), base_s * 0.3, 0.55, Color(1.0, 0.7, 0.15, 0.98))
		if puffs != null:
			var puff_count := int(BOMB_PUFF_COUNT * n_scale)
			for i in puff_count:
				var off := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(0.0, 0.9), _rng.randf_range(-1.0, 1.0)).normalized() * (base_s * 0.3)
				var vel := off * 1.5 + Vector3(0.0, _rng.randf_range(4.0, 10.0), 0.0)
				puffs.spawn(pos + off, vel, base_s * 0.35, base_s * 1.5, BOMB_PUFF_LIFE, Color(0.18, 0.17, 0.16, 0.8), 1.0)

func _trigger_destruction(pos: Vector3, radius: float, n_scale: float) -> void:
	var s := clampf(radius * 0.75, CRASH_FLASH_SIZE_MIN, CRASH_FLASH_SIZE_MAX)
	var max_end_width: float = MAX_FLASH_END_WIDTH_LOW if quality <= 0 else MAX_FLASH_END_WIDTH_NORMAL
	var end_size_1: float = minf(s * 2.4, max_end_width)
	var end_size_2: float = minf(s * 1.7, max_end_width * 0.75)

	_spawn_flash(pos, s * 0.5, end_size_1, CRASH_FLASH_LIFE, Color(1.0, 0.70, 0.22, 0.98))
	_spawn_flash(pos, s * 0.35, end_size_2, CRASH_FLASH_LIFE * 0.75, Color(1.0, 0.92, 0.65, 0.95))
	if blast_glow != null and blast_glow.enabled:
		blast_glow.add(pos, s)
	var spark_count := int(CRASH_SPARK_COUNT * n_scale)
	for i in spark_count:
		var dir := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.35, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
		_spawn_spark(pos + dir * (s * 0.08), dir * _rng.randf_range(s * 1.6, s * 3.8), s * 0.35, 0.65, Color(1.0, 0.65, 0.2, 0.98))
	if puffs != null:
		var puff_count := int(CRASH_PUFF_COUNT * n_scale)
		for i in puff_count:
			var off := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.2, 0.9), _rng.randf_range(-1.0, 1.0)).normalized() * (s * 0.35)
			var vel := off * _rng.randf_range(1.2, 2.2) + Vector3(0.0, _rng.randf_range(3.5, 8.5), 0.0)
			puffs.spawn(pos + off, vel, s * 0.35, s * 1.6, CRASH_PUFF_LIFE, Color(0.15, 0.14, 0.14, 0.8), 1.2)

func _trigger_water(pos: Vector3, radius: float, incident_type: int, weapon_type: int, n_scale: float) -> void:
	# 1. Gun impacts on water: small, short spray, NEVER touches the heavy splash pool
	if incident_type == INCIDENT_GUN_IMPACT or weapon_type == FSWEAPON_GUN:
		if puffs != null and quality > 0:
			var s := clampf(radius * 1.2, 2.5, 6.0)
			puffs.spawn(pos, Vector3(0.0, 2.5, 0.0), s * 0.4, s * 1.5, 0.45, Color(0.92, 0.95, 0.98, 0.55), 0.0)
		return

	# 2. Heavy impacts: use the 3-in-1 low-poly splash crown
	if _water_splash == null:
		return

	var base_r := 6.0
	var top_r := 12.0
	var height := 22.0
	var life := 1.2

	if weapon_type == FSWEAPON_ROCKET or weapon_type == FSWEAPON_AGM65:
		base_r = clampf(radius * 0.5, 4.0, 8.0)
		top_r = clampf(radius * 0.9, 7.0, 14.0)
		height = clampf(radius * 1.5, 14.0, 22.0)
		life = 1.0
	elif weapon_type == FSWEAPON_BOMB or weapon_type == FSWEAPON_BOMB500HD:
		# Heavy bomb in water: towering crown
		base_r = clampf(radius * 0.75, 12.0, 22.0)
		top_r = clampf(radius * 1.2, 18.0, 32.0)
		height = clampf(radius * 2.2, 38.0, 60.0)
		life = 2.0
	elif incident_type == INCIDENT_AIR_TO_AIR_MISSILE:
		base_r = clampf(radius * 0.6, 6.0, 11.0)
		top_r = clampf(radius * 1.0, 10.0, 18.0)
		height = clampf(radius * 1.6, 18.0, 28.0)
		life = 1.25
	elif incident_type == INCIDENT_ENTITY_DESTRUCTION_OR_CRASH:
		base_r = clampf(radius * 0.7, 14.0, 24.0)
		top_r = clampf(radius * 1.2, 22.0, 35.0)
		height = clampf(radius * 2.2, 42.0, 62.0)
		life = 2.2
	else:
		# Generic bomb / unknown heavy ordnance
		base_r = clampf(radius * 0.65, 8.0, 16.0)
		top_r = clampf(radius * 1.1, 14.0, 24.0)
		height = clampf(radius * 1.8, 26.0, 42.0)
		life = 1.6

	_water_splash.spawn(pos, base_r, top_r, height, life, 0.95)

	# Lightweight mist spray at base (max 2-3 puffs, suppressed on low quality)
	if puffs != null and quality > 0:
		var mist_count := clampi(int(3 * n_scale), 1, 3)
		for i in mist_count:
			var spread := Vector3(_rng.randf_range(-0.3, 0.3), _rng.randf_range(0.0, 0.2), _rng.randf_range(-0.3, 0.3)) * base_r
			var up := Vector3(spread.x * 0.4, _rng.randf_range(8.0, 18.0), spread.z * 0.4)
			puffs.spawn(pos + spread, up, base_r * 0.3, base_r * 0.9, life * 0.7, Color(0.93, 0.95, 0.98, 0.50), 0.0)

# Public entry point for aircraft crashes into water reported by telemetry tracker (e.g. shot-down / tumbling aircraft)
func trigger_water_crash(pos: Vector3, radius: float) -> void:
	_ensure_init()
	# Avoid duplicate splash if an explosion plume already spawned a splash here recently
	if _water_splash != null and _water_splash.has_recent_splash_near(pos, 30.0, 0.5):
		return
	var n_scale: float = 0.5 if quality <= 0 else 1.0
	_trigger_water(pos, radius, INCIDENT_ENTITY_DESTRUCTION_OR_CRASH, -1, n_scale)

func _trigger_fallback(pos: Vector3, radius: float, n_scale: float) -> void:
	if radius < 6.0:
		_trigger_gun(pos, radius, n_scale)
	elif radius < 25.0:
		_trigger_aam(pos, radius, n_scale)
	else:
		_trigger_destruction(pos, radius, n_scale)

# MODEL_MATRIX packing: see shaders/spark_streak.gdshader
func _spawn_spark(pos: Vector3, vel: Vector3, length: float, life: float, color: Color) -> void:
	_spark_mm.set_instance_transform(_spark_head, Transform3D(Basis(vel, Vector3(length, maxf(life, 0.08), _time), Vector3.ZERO), pos))
	_spark_mm.set_instance_color(_spark_head, color)
	_spark_head = (_spark_head + 1) % MAX_SPARKS

# MODEL_MATRIX packing: see shaders/explosion_flash.gdshader
func _spawn_flash(pos: Vector3, size0: float, size1: float, life: float, color: Color, frame: float = -1.0) -> void:
	_last_flash_size0 = size0
	_last_flash_size1 = size1
	var roll := _rng.randf_range(0.0, TAU)
	var f_idx: float = float(_rng.randi_range(0, 4)) if frame < 0.0 else frame
	_flash_mm.set_instance_transform(_flash_head, Transform3D(Basis(Vector3.ZERO, Vector3(size0, size1, life), Vector3(_time, roll, f_idx)), pos))
	_flash_mm.set_instance_color(_flash_head, color)
	_flash_head = (_flash_head + 1) % MAX_FLASHES

func _build_atlas() -> void:
	var atlas := Image.create(256 * 5, 256, false, Image.FORMAT_L8)
	var textures: Array[Texture2D] = [TEX_EXP01, TEX_EXP02, TEX_EXP03, TEX_EXP04, TEX_EXP05]
	for i in 5:
		var img := textures[i].get_image()
		if img != null:
			if img.get_format() != Image.FORMAT_L8:
				img.convert(Image.FORMAT_L8)
			atlas.blit_rect(img, Rect2i(0, 0, 256, 256), Vector2i(i * 256, 0))
	_atlas_tex = ImageTexture.create_from_image(atlas)
	_flash_mat.set_shader_parameter("explosion_atlas", _atlas_tex)

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
	# Conservative flight-volume bounds covering map area without arbitrary 1e7
	mmi.custom_aabb = AABB(Vector3(-60000.0, -100.0, -60000.0), Vector3(120000.0, 20000.0, 120000.0))
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
