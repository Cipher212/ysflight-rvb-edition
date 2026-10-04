extends Node3D

# Low-poly cosmetic cloud layer over Luavi.
# Restrained PS2 / YSFlight style: sparse, slow-drifting, opaque flattened cumulus clouds.
# Generates a single shared ArrayMesh (< 160 triangles, 1 continuous surface, flat base with
# billowing top dome) with vertex colours (off-white top, grey underside) and a single MultiMeshInstance3D.
# Wind offset is maintained as a single shared vector and passed to the shader.
# Evaluates camera immersion at ~10 Hz with altitude pre-rejection and smoothly fades scene fog.

const CLOUD_COUNT := 8
const FIELD_MIN := Vector2(-24000.0, -24000.0)
const FIELD_MAX := Vector2(24000.0, 24000.0)
const FIELD_SIZE := Vector2(48000.0, 48000.0)

const ALTITUDE_MIN_CHECK := 400.0
const ALTITUDE_MAX_CHECK := 3500.0

# 30.0 knots base wind velocity (15.433 m/s) heading northeast
const WIND_VELOCITY := Vector3(12.3467, 0.0, 9.2600)

const SAMPLE_INTERVAL_S := 0.1 # 10 Hz rate-limited membership sampling
const IMMERSION_IN_SPEED := 2.5 # ~0.4s to enter cloud
const IMMERSION_OUT_SPEED := 1.8 # ~0.55s to leave cloud

var _sky_env: Node = null
var _mmi: MultiMeshInstance3D = null
var _mm: MultiMesh = null
var _cloud_mat: ShaderMaterial = null

var _clouds_enabled: bool = true
var _wind_offset := Vector3.ZERO
var _sample_timer: float = 0.0

var _target_immersion: float = 0.0
var _current_immersion: float = 0.0
var _last_sent_immersion: float = 0.0

# Per-cloud initial state
var _cloud_pos: Array[Vector3] = []
var _cloud_scale: Array[Vector3] = []
var _cloud_rot_y: PackedFloat32Array = PackedFloat32Array()
var _cloud_speed_mult: PackedFloat32Array = PackedFloat32Array()
var _cloud_bounding_radius: PackedFloat32Array = PackedFloat32Array()
var _cloud_half_height: PackedFloat32Array = PackedFloat32Array()

func setup(sky_env: Node) -> void:
	name = "LowCloudLayer"
	_sky_env = sky_env

	_cloud_mat = ShaderMaterial.new()
	_cloud_mat.shader = preload("res://shaders/low_cloud.gdshader")
	_cloud_mat.set_shader_parameter("field_min", FIELD_MIN)
	_cloud_mat.set_shader_parameter("field_size", FIELD_SIZE)
	_cloud_mat.set_shader_parameter("wind_offset", _wind_offset)

	var mesh: ArrayMesh = _build_cloud_mesh()

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = false
	_mm.use_custom_data = true
	_mm.mesh = mesh
	_mm.instance_count = CLOUD_COUNT

	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "CloudsMultiMesh"
	_mmi.multimesh = _mm
	_mmi.material_override = _cloud_mat
	_mmi.custom_aabb = AABB(Vector3(-32000.0, 400.0, -32000.0), Vector3(64000.0, 3000.0, 64000.0))
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mmi.visible = _clouds_enabled
	add_child(_mmi)

	_generate_clouds(1984)

func set_clouds_enabled(enabled: bool) -> void:
	_clouds_enabled = enabled
	if _mmi != null:
		_mmi.visible = enabled
	if not _clouds_enabled:
		_target_immersion = 0.0
		_current_immersion = 0.0
		_last_sent_immersion = 0.0
		if _sky_env != null and _sky_env.has_method("set_cloud_immersion"):
			_sky_env.set_cloud_immersion(0.0)

func is_clouds_enabled() -> bool:
	return _clouds_enabled

func reset_state() -> void:
	_wind_offset = Vector3.ZERO
	if _cloud_mat != null:
		_cloud_mat.set_shader_parameter("wind_offset", _wind_offset)
	_target_immersion = 0.0
	_current_immersion = 0.0
	_last_sent_immersion = 0.0
	if _sky_env != null and _sky_env.has_method("set_cloud_immersion"):
		_sky_env.set_cloud_immersion(0.0)

func update(delta: float, cam_pos: Vector3, is_paused: bool = false) -> void:
	if not _clouds_enabled:
		return

	# Advance wind drift when simulation is unpaused
	if not is_paused and delta > 0.0:
		_wind_offset += WIND_VELOCITY * delta
		_wind_offset.x = fposmod(_wind_offset.x, FIELD_SIZE.x)
		_wind_offset.z = fposmod(_wind_offset.z, FIELD_SIZE.y)
		if _cloud_mat != null:
			_cloud_mat.set_shader_parameter("wind_offset", _wind_offset)

	# Rate-limited membership sampling (~10 Hz)
	_sample_timer += delta
	if _sample_timer >= SAMPLE_INTERVAL_S:
		_sample_timer = 0.0
		_target_immersion = _sample_membership(cam_pos)

	# Smooth visual interpolation of immersion fog
	var speed: float = IMMERSION_IN_SPEED if _target_immersion > _current_immersion else IMMERSION_OUT_SPEED
	_current_immersion = move_toward(_current_immersion, _target_immersion, delta * speed)

	if absf(_current_immersion - _last_sent_immersion) > 0.001:
		_last_sent_immersion = _current_immersion
		if _sky_env != null and _sky_env.has_method("set_cloud_immersion"):
			_sky_env.set_cloud_immersion(_current_immersion)

# Evaluates whether the camera position is inside any cloud instance.
func _sample_membership(cam_pos: Vector3) -> float:
	# Altitude pre-rejection (1 float check saves distance calculations)
	if cam_pos.y < ALTITUDE_MIN_CHECK or cam_pos.y > ALTITUDE_MAX_CHECK:
		return 0.0

	for i in CLOUD_COUNT:
		var pos: Vector3 = _cloud_pos[i]
		var speed_mult: float = _cloud_speed_mult[i]
		var cur_cx: float = FIELD_MIN.x + fposmod(pos.x + _wind_offset.x * speed_mult - FIELD_MIN.x, FIELD_SIZE.x)
		var cur_cz: float = FIELD_MIN.y + fposmod(pos.z + _wind_offset.z * speed_mult - FIELD_MIN.y, FIELD_SIZE.y)
		var cur_cy: float = pos.y + _wind_offset.y

		# Shortest horizontal distance on toroidal boundary
		var dx: float = cam_pos.x - cur_cx
		var dz: float = cam_pos.z - cur_cz
		if dx > FIELD_SIZE.x * 0.5:
			dx -= FIELD_SIZE.x
		elif dx < -FIELD_SIZE.x * 0.5:
			dx += FIELD_SIZE.x
		if dz > FIELD_SIZE.y * 0.5:
			dz -= FIELD_SIZE.y
		elif dz < -FIELD_SIZE.y * 0.5:
			dz += FIELD_SIZE.y

		var max_r: float = _cloud_bounding_radius[i]
		if (dx * dx + dz * dz) > (max_r * max_r):
			continue

		var dy: float = cam_pos.y - cur_cy
		if absf(dy) > _cloud_half_height[i]:
			continue

		# Inside bounding cylinder: check normalized cloud volume in local space
		var rel := Vector3(dx, dy, dz).rotated(Vector3.UP, -_cloud_rot_y[i])
		var s: Vector3 = _cloud_scale[i]
		var model_pos := Vector3(rel.x / s.x, rel.y / s.y, rel.z / s.z)

		# Ellipsoidal distance test: <= 1.0 is inside Shell 0
		const NORM_Y := 0.1992
		const NORM_Z := 0.4906
		var ny: float = model_pos.y / NORM_Y
		var nz: float = model_pos.z / NORM_Z
		var d_sq: float = model_pos.x * model_pos.x + ny * ny + nz * nz
		if d_sq <= 1.0:
			return 1.0

	return 0.0

func _generate_clouds(p_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed

	_cloud_pos.clear()
	_cloud_scale.clear()
	_cloud_rot_y.clear()
	_cloud_speed_mult.clear()
	_cloud_bounding_radius.clear()
	_cloud_half_height.clear()

	const COLS := 4
	const ROWS := 2
	const NORM_Y := 0.1992
	var cell_w: float = FIELD_SIZE.x / float(COLS)
	var cell_d: float = FIELD_SIZE.y / float(ROWS)

	# Tier allocation across the 8 cells (shuffled so low, mid, and high clouds are distributed across the map)
	const TIERS: Array[float] = [0.0, 0.6, 0.2, 0.9, 0.4, 1.0, 0.1, 0.8]
	const FT_TO_M := 0.3048

	for i in CLOUD_COUNT:
		var c: int = i % COLS
		var r: int = i / COLS
		# Grid spacing with jitter ensures massive cloud banks remain cleanly separated
		var cx: float = FIELD_MIN.x + (float(c) + 0.5 + rng.randf_range(-0.10, 0.10)) * cell_w
		var cz: float = FIELD_MIN.y + (float(r) + 0.5 + rng.randf_range(-0.10, 0.10)) * cell_d

		var t: float = clampf(TIERS[i] + rng.randf_range(-0.04, 0.04), 0.0, 1.0)

		# Altitude: starts from 3500 ft (smaller clouds) up to 5000+ ft (massive clouds)
		var alt_ft: float = lerpf(3500.0, 5400.0, t)
		var cy: float = alt_ft * FT_TO_M

		# Size variation: smaller stratus (~3000m) at 3500 ft, massive clouds (~6800m) at 5000+ ft
		var sx: float = lerpf(3000.0, 6800.0, t) + rng.randf_range(-150.0, 150.0)
		var sz: float = sx
		var sy: float = sx * 0.55
		var rot: float = rng.randf_range(0.0, TAU)

		# Speed: 45 knots (speed_mult = 1.50) for lower clouds, 30 knots (speed_mult = 1.00) for massive high clouds
		var speed_mult: float = lerpf(1.50, 1.00, t)

		_cloud_pos.append(Vector3(cx, cy, cz))
		_cloud_scale.append(Vector3(sx, sy, sz))
		_cloud_rot_y.append(rot)
		_cloud_speed_mult.append(speed_mult)

		var max_horiz: float = sx * 1.05
		_cloud_bounding_radius.append(max_horiz)
		_cloud_half_height.append(sy * NORM_Y * 1.05)

		var rot_basis := Basis(Vector3.UP, rot)
		var scale_basis := Basis().scaled(Vector3(sx, sy, sz))
		var tfm := Transform3D(rot_basis * scale_basis, Vector3(cx, cy, cz))
		_mm.set_instance_transform(i, tfm)
		_mm.set_instance_custom_data(i, Color(speed_mult, 0.0, 0.0, 0.0))

# Procedurally generates an ArrayMesh for the low-poly cloud.
# Constructs a single conjoined, watertight 2-manifold stratus mesh (50 vertices, 96 triangles)
# with a flattened underside, 40% thinner profile, 100% outward-facing Gouraud normals,
# and prominent pre-baked dark underside shading.
func _build_cloud_mesh() -> ArrayMesh:
	var segments := 12
	var rings := 4

	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var indices := PackedInt32Array()
	var norms := PackedVector3Array()

	var color_top := Color(1.0, 1.0, 1.0)
	var color_bottom := Color(0.30, 0.33, 0.39) # Deep storm-slate for flat stratus base

	var base_norm_y := 0.1992 # 40% thinner height (0.3320 * 0.60)
	var base_norm_z := 0.4906

	# 1. Vertices & Colors
	# Top pole (Index 0): Center of upper dome
	verts.append(Vector3(0.0, base_norm_y, 0.0))
	cols.append(color_top)

	# Intermediate rings (1 to rings)
	for r in range(1, rings + 1):
		var phi := PI * float(r) / float(rings + 1)
		var sin_phi := sin(phi)
		var cos_phi := cos(phi)

		# Flattened stratus profile: upper dome gently curves down, bottom hemisphere flattens out
		var vy: float
		var h_rad: float
		if cos_phi >= 0.0:
			vy = cos_phi * base_norm_y
			h_rad = sin_phi
		else:
			vy = -base_norm_y * (1.0 - pow(1.0 + cos_phi, 1.8))
			h_rad = sqrt(sin_phi)

		# Vertical height factor from 0.0 (top) to 1.0 (bottom base)
		var h_norm := clampf((base_norm_y - vy) / (2.0 * base_norm_y), 0.0, 1.0)
		var shade_factor := pow(h_norm, 1.3)
		var base_col := color_top.lerp(color_bottom, shade_factor)

		for s in range(segments):
			var theta := TAU * float(s) / float(segments)

			# Broad, rolling horizontal undulations for stratus layers
			var sin3 := sin(3.0 * theta)
			var lobe := 0.90 + 0.10 * sin3

			var vx := lobe * h_rad * cos(theta)
			var vz := lobe * h_rad * sin(theta) * base_norm_z
			verts.append(Vector3(vx, vy, vz))

			# Crevasse shading on the upper dome folds; flat underside remains uniformly dark
			var dip := maxf(0.0, -sin3)
			var darkening := dip * sin_phi * 0.35 if cos_phi >= 0.0 else 0.0
			var final_col := base_col * (1.0 - darkening)
			cols.append(final_col)

	# Bottom pole (Index: verts.size()): Center of flat bottom floor
	verts.append(Vector3(0.0, -base_norm_y, 0.0))
	cols.append(color_bottom)

	# 2. Indices (Watertight, 100% outward CCW winding)
	# Top pole fan
	for s in range(segments):
		var s_next := (s + 1) % segments
		indices.push_back(0)
		indices.push_back(1 + s_next)
		indices.push_back(1 + s)

	# Intermediate ring quads
	for r in range(1, rings):
		var r_start := 1 + (r - 1) * segments
		var r_next := 1 + r * segments
		for s in range(segments):
			var s_next := (s + 1) % segments
			var v0 := r_start + s
			var v1 := r_start + s_next
			var v2 := r_next + s_next
			var v3 := r_next + s
			# Quad split into 2 outward CCW triangles
			indices.push_back(v0)
			indices.push_back(v1)
			indices.push_back(v2)
			indices.push_back(v0)
			indices.push_back(v2)
			indices.push_back(v3)

	# Bottom pole fan
	var bottom_pole := verts.size() - 1
	var r_last := 1 + (rings - 1) * segments
	for s in range(segments):
		var s_next := (s + 1) % segments
		indices.push_back(r_last + s)
		indices.push_back(r_last + s_next)
		indices.push_back(bottom_pole)

	# 3. Calculate smooth Gouraud normals by accumulating face normals
	norms.resize(verts.size())
	for i in verts.size():
		norms[i] = Vector3.ZERO

	for t in range(0, indices.size(), 3):
		var i0 := indices[t]
		var i1 := indices[t + 1]
		var i2 := indices[t + 2]
		var fn := (verts[i1] - verts[i0]).cross(verts[i2] - verts[i0]).normalized()
		norms[i0] += fn
		norms[i1] += fn
		norms[i2] += fn

	for i in verts.size():
		norms[i] = norms[i].normalized()

	# 4. Construct ArrayMesh
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

func get_cloud_count() -> int:
	return CLOUD_COUNT

func get_wind_offset() -> Vector3:
	return _wind_offset

func get_current_immersion() -> float:
	return _current_immersion
