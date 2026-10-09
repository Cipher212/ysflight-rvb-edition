extends Node3D

# Low-poly 3-in-1 dynamic water splash crown (central spout, jagged crown, surface foam annulus).
# GPU-aged MultiMesh ring buffer with fixed 8 slots for heavy impacts (AAM, rockets, bombs, crashes).
# Mesh geometry: exactly 64 vertices, 64 triangles, 1 surface.

const SPLASH_SHADER := preload("res://shaders/water_splash.gdshader")

const MAX_SPLASHES := 8
const DEAD_TRANSFORM := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3(-1000.0, 0.0, 0.0)), Vector3.ZERO)

# Named tuning limits
const MAX_SPLASH_RADIUS := 35.0
const MAX_SPLASH_HEIGHT := 65.0
const MAX_SPLASH_LIFE := 2.5

var quality: int = 1

var _time: float = 0.0
var _multimesh: MultiMesh = null
var _mmi: MultiMeshInstance3D = null # at -render_origin: instances are absolute (fx/puff_system.gd)
var _material: ShaderMaterial = null
var _mesh: ArrayMesh = null
var _head: int = 0
var _initialized: bool = false

# Slot tracking for deterministic reuse
var _slot_spawn_time: PackedFloat32Array = PackedFloat32Array()
var _slot_life: PackedFloat32Array = PackedFloat32Array()
var _slot_active: Array[bool] = []
var _slot_pos: PackedVector3Array = PackedVector3Array()
var _slot_base_r: PackedFloat32Array = PackedFloat32Array()
var _slot_top_r: PackedFloat32Array = PackedFloat32Array()
var _slot_height: PackedFloat32Array = PackedFloat32Array()

func _ready() -> void:
	_ensure_init()

func _ensure_init() -> void:
	if _initialized:
		return
	_initialized = true

	_slot_spawn_time.resize(MAX_SPLASHES)
	_slot_life.resize(MAX_SPLASHES)
	_slot_active.resize(MAX_SPLASHES)
	_slot_pos.resize(MAX_SPLASHES)
	_slot_base_r.resize(MAX_SPLASHES)
	_slot_top_r.resize(MAX_SPLASHES)
	_slot_height.resize(MAX_SPLASHES)
	for i in MAX_SPLASHES:
		_slot_spawn_time[i] = -1000.0
		_slot_life[i] = 1.0
		_slot_active[i] = false
		_slot_pos[i] = Vector3.ZERO
		_slot_base_r[i] = 0.0
		_slot_top_r[i] = 0.0
		_slot_height[i] = 0.0

	_material = ShaderMaterial.new()
	_material.shader = SPLASH_SHADER

	_mesh = _build_mesh()
	_mesh.surface_set_material(0, _material)

	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	_multimesh.mesh = _mesh
	_multimesh.instance_count = MAX_SPLASHES
	for i in MAX_SPLASHES:
		_multimesh.set_instance_transform(i, DEAD_TRANSFORM)
		_multimesh.set_instance_color(i, Color(0.0, 0.0, 0.0, 0.0))
	_multimesh.visible_instance_count = MAX_SPLASHES

	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "WaterSplashMultiMesh"
	_mmi.multimesh = _multimesh
	# Conservative flight-volume bounds covering map area without arbitrary 1e7
	_mmi.custom_aabb = AABB(Vector3(-60000.0, -100.0, -60000.0), Vector3(120000.0, 20000.0, 120000.0))
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mmi)

func reset() -> void:
	_ensure_init()
	_head = 0
	for i in MAX_SPLASHES:
		_slot_spawn_time[i] = -1000.0
		_slot_life[i] = 1.0
		_slot_active[i] = false
		_slot_pos[i] = Vector3.ZERO
		_slot_base_r[i] = 0.0
		_slot_top_r[i] = 0.0
		_slot_height[i] = 0.0
		_multimesh.set_instance_transform(i, DEAD_TRANSFORM)
		_multimesh.set_instance_color(i, Color(0.0, 0.0, 0.0, 0.0))

# The render origin moved (fx/explosion_fx.gd): _slot_pos is render space, the instances absolute.
func set_render_origin(origin: Vector3, delta: Vector3) -> void:
	_ensure_init()
	_mmi.position = -origin
	for i in MAX_SPLASHES:
		_slot_pos[i] -= delta

func get_active_count() -> int:
	_ensure_init()
	var count: int = 0
	for i in MAX_SPLASHES:
		if _slot_active[i]:
			count += 1
	return count

func has_recent_splash_near(pos: Vector3, max_dist: float = 30.0, max_age: float = 0.5) -> bool:
	_ensure_init()
	var dist_sq := max_dist * max_dist
	for i in MAX_SPLASHES:
		if _slot_active[i]:
			var age: float = _time - _slot_spawn_time[i]
			if age >= -0.05 and age <= max_age:
				if _slot_pos[i].distance_squared_to(pos) <= dist_sq:
					return true
	return false

func set_quality(p_quality: int) -> void:
	_ensure_init()
	quality = p_quality
	if quality <= 0:
		# Low quality: suppress already-active instances to save bandwidth
		for i in MAX_SPLASHES:
			if _slot_active[i]:
				var age: float = _time - _slot_spawn_time[i]
				if age >= _slot_life[i] * 0.5:
					_multimesh.set_instance_transform(i, DEAD_TRANSFORM)
					_slot_active[i] = false

func update(delta: float) -> void:
	_ensure_init()
	_time += delta
	_material.set_shader_parameter("now", _time)
	# Update active status for bookkeeping
	for i in MAX_SPLASHES:
		if _slot_active[i]:
			var age: float = _time - _slot_spawn_time[i]
			if age >= _slot_life[i]:
				_slot_active[i] = false

# Spawns a heavy water splash crown.
# Input coordinates must provide the actual water-contact height (pos.y).
func spawn(pos: Vector3, base_rad: float, top_rad: float, height: float, life: float, alpha: float = 1.0) -> void:
	_ensure_init()

	# Clamp parameters against named maximum bounds
	var clamped_base: float = clampf(base_rad, 2.0, MAX_SPLASH_RADIUS * 0.7)
	var clamped_top: float = clampf(top_rad, 3.0, MAX_SPLASH_RADIUS)
	var clamped_h: float = clampf(height, 5.0, MAX_SPLASH_HEIGHT)
	var clamped_life: float = clampf(life, 0.4, MAX_SPLASH_LIFE)

	# Low FX quality: scale down dimension coverage to reduce fill-rate
	if quality <= 0:
		clamped_base *= 0.75
		clamped_top *= 0.75
		clamped_h *= 0.75

	# Deterministic slot allocation:
	# 1. Search for an inactive/expired slot
	var slot := -1
	for i in MAX_SPLASHES:
		var check_idx := (_head + i) % MAX_SPLASHES
		if not _slot_active[check_idx] or (_time - _slot_spawn_time[check_idx] >= _slot_life[check_idx]):
			slot = check_idx
			break
	# 2. If all slots active, evict oldest slot
	if slot < 0:
		var oldest_idx := 0
		var max_age := -1.0
		for i in MAX_SPLASHES:
			var age: float = _time - _slot_spawn_time[i]
			if age > max_age:
				max_age = age
				oldest_idx = i
		slot = oldest_idx

	_head = (slot + 1) % MAX_SPLASHES
	_slot_spawn_time[slot] = _time
	_slot_life[slot] = clamped_life
	_slot_active[slot] = true
	_slot_pos[slot] = pos
	_slot_base_r[slot] = clamped_base
	_slot_top_r[slot] = clamped_top
	_slot_height[slot] = clamped_h

	# Instance packing (see shaders/water_splash.gdshader):
	#   Basis.x = (0, 0, 0)
	#   Basis.y = (base_rad, top_rad, height)
	#   Basis.z = (spawn_time, lifetime, surface_y)
	#   Origin = absolute world position at water contact level
	var t := Transform3D(
		Basis(
			Vector3.ZERO,
			Vector3(clamped_base, clamped_top, clamped_h),
			Vector3(_time, clamped_life, pos.y)
		),
		pos - _mmi.position
	)
	_multimesh.set_instance_transform(slot, t)
	_multimesh.set_instance_color(slot, Color(1.0, 1.0, 1.0, alpha))

# Generates 3-in-1 low-poly mesh (Spout, Crown, Foam Annulus)
func _build_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	# 1. Central Spout: 8 radial segments (16 vertices, 16 triangles)
	var spout_segs := 8
	var spout_base_idx := verts.size()
	for i in spout_segs:
		var angle := TAU * float(i) / float(spout_segs)
		var x := cos(angle)
		var z := sin(angle)
		# Base vertex (y = 0.0)
		verts.append(Vector3(x * 0.4, 0.0, z * 0.4))
		uvs.append(Vector2(float(i) / float(spout_segs), 0.0))
		colors.append(Color(0.0, 0.0, 0.0, 1.0)) # comp=0.0 (Spout)

		# Top vertex (y = 1.0)
		verts.append(Vector3(x * 0.2, 1.0, z * 0.2))
		uvs.append(Vector2(float(i) / float(spout_segs), 1.0))
		colors.append(Color(0.0, 0.0, 0.0, 1.0))

	for i in spout_segs:
		var next_i := (i + 1) % spout_segs
		var b0 := spout_base_idx + i * 2
		var t0 := b0 + 1
		var b1 := spout_base_idx + next_i * 2
		var t1 := b1 + 1
		indices.append_array([b0, t0, b1, b1, t0, t1])

	# 2. Jagged Crown: 12 radial segments (24 vertices, 24 triangles)
	var crown_segs := 12
	var crown_base_idx := verts.size()
	for i in crown_segs:
		var angle := TAU * float(i) / float(crown_segs)
		var x := cos(angle)
		var z := sin(angle)
		var is_peak := (i % 2 == 0)
		var jag_val := 1.0 if is_peak else 0.0

		# Base vertex (y = 0.0)
		verts.append(Vector3(x * 0.6, 0.0, z * 0.6))
		uvs.append(Vector2(float(i) / float(crown_segs), 0.0))
		colors.append(Color(0.5, jag_val, 0.0, 1.0)) # comp=0.5 (Crown)

		# Top jagged vertex (y = 1.0)
		verts.append(Vector3(x * 1.0, 1.0, z * 1.0))
		uvs.append(Vector2(float(i) / float(crown_segs), 1.0))
		colors.append(Color(0.5, jag_val, 0.0, 1.0))

	for i in crown_segs:
		var next_i := (i + 1) % crown_segs
		var b0 := crown_base_idx + i * 2
		var t0 := b0 + 1
		var b1 := crown_base_idx + next_i * 2
		var t1 := b1 + 1
		indices.append_array([b0, t0, b1, b1, t0, t1])

	# 3. Surface Foam Annulus: 12 radial segments (24 vertices, 24 triangles)
	var ring_segs := 12
	var ring_base_idx := verts.size()
	for i in ring_segs:
		var angle := TAU * float(i) / float(ring_segs)
		var x := cos(angle)
		var z := sin(angle)

		# Inner ring vertex
		verts.append(Vector3(x * 0.6, 0.0, z * 0.6))
		uvs.append(Vector2(float(i) / float(ring_segs), 0.0))
		colors.append(Color(1.0, 0.0, 0.0, 1.0)) # comp=1.0 (Annulus)

		# Outer ring vertex
		verts.append(Vector3(x * 1.2, 0.0, z * 1.2))
		uvs.append(Vector2(float(i) / float(ring_segs), 1.0))
		colors.append(Color(1.0, 0.0, 0.0, 1.0))

	for i in ring_segs:
		var next_i := (i + 1) % ring_segs
		var in0 := ring_base_idx + i * 2
		var out0 := in0 + 1
		var in1 := ring_base_idx + next_i * 2
		var out1 := in1 + 1
		indices.append_array([in0, out0, in1, in1, out0, out1])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
