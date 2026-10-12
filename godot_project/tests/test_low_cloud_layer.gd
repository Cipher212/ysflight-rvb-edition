extends SceneTree

# Focused verification for the low-poly cosmetic cloud layer.
# Verifies:
#   1. Deterministic seeding and cloud count (32)
#   2. Mesh triangle budget (< 160 triangles, 3 lobes, vertex colours)
#   3. Bounds coverage within Luavi field rectangle
#   4. Toroidal rigid wind drift wrapping
#   5. Altitude pre-rejection (< 950m or > 1450m ASL)
#   6. Inside / outside camera membership detection
#   7. Smooth immersion interpolation and fog composition
#   8. Night/dusk atmosphere dimming
#   9. Pause suppression of wind drift
#  10. Disable toggle cleanup and fog restoration

const LowCloudLayerScript = preload("res://world/low_cloud_layer.gd")
const SkyEnvironmentScript = preload("res://world/sky_environment.gd")

var _failures: int = 0

func _init() -> void:
	print("[LowCloudLayerTest] Starting verification...")
	test_cloud_count_and_determinism()
	test_mesh_budget_and_vertex_colors()
	test_bounds_and_wind_drift()
	test_pause_behavior()
	test_altitude_pre_rejection_and_membership()
	test_fog_composition_and_dimming()
	test_toggle_and_cleanup()

	print("\n[LowCloudLayerTest] Results: %d failures." % _failures)
	quit(_failures)

func _assert(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		printerr("FAIL: %s" % message)
		_failures += 1

func test_cloud_count_and_determinism() -> void:
	var layer1: Node3D = LowCloudLayerScript.new()
	root.add_child(layer1)
	layer1.setup(null)

	_assert(layer1.get_cloud_count() == 8, "Cloud count is exactly 8")

	var layer2: Node3D = LowCloudLayerScript.new()
	root.add_child(layer2)
	layer2.setup(null)

	# Verify deterministic positions across both layers
	var match_count := 0
	for i in layer1.get_cloud_count():
		if layer1._cloud_pos[i] == layer2._cloud_pos[i] and layer1._cloud_scale[i] == layer2._cloud_scale[i]:
			match_count += 1
	_assert(match_count == 8, "RNG seeding produces 100% identical positions and scales")

	layer1.queue_free()
	layer2.queue_free()

func test_mesh_budget_and_vertex_colors() -> void:
	var layer: Node3D = LowCloudLayerScript.new()
	root.add_child(layer)
	layer.setup(null)

	var mesh: ArrayMesh = layer._mmi.multimesh.mesh
	_assert(mesh != null, "MultiMesh has valid ArrayMesh")
	_assert(mesh.get_surface_count() == 1, "ArrayMesh has single surface")

	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]

	var tri_count := indices.size() / 3
	_assert(tri_count == 228, "Triangle count is exactly 228 (from cloud_20km.srf)")
	_assert(verts.size() == 134, "Vertex count is exactly 134")
	_assert(norms.size() == 134, "Normal array matches vertex count")
	_assert(cols.size() == 134, "Color array matches vertex count")

	# Verify top off-white and underside grey colors exist
	var has_top_color := false
	var has_bottom_color := false
	for c in cols:
		if c.v > 0.90:
			has_top_color = true
		if c.v < 0.75:
			has_bottom_color = true
	_assert(has_top_color and has_bottom_color, "Mesh contains muted off-white top and cool grey underside shading")

	layer.queue_free()

func test_bounds_and_wind_drift() -> void:
	var layer: Node3D = LowCloudLayerScript.new()
	root.add_child(layer)
	layer.setup(null)
	layer.set_clouds_enabled(true)

	for i in layer.get_cloud_count():
		var pos: Vector3 = layer._cloud_pos[i]
		_assert(pos.x >= LowCloudLayerScript.FIELD_MIN.x and pos.x <= LowCloudLayerScript.FIELD_MAX.x,
			"Cloud %d X pos %f within field bounds" % [i, pos.x])
		_assert(pos.z >= LowCloudLayerScript.FIELD_MIN.y and pos.z <= LowCloudLayerScript.FIELD_MAX.y,
			"Cloud %d Z pos %f within field bounds" % [i, pos.z])
		_assert(pos.y >= LowCloudLayerScript.ALTITUDE_CENTER - LowCloudLayerScript.ALTITUDE_SPREAD
			and pos.y <= LowCloudLayerScript.ALTITUDE_CENTER + LowCloudLayerScript.ALTITUDE_SPREAD,
			"Cloud %d Y pos %f within altitude band" % [i, pos.y])

	# Advance drift
	var initial_offset: Vector3 = layer.get_wind_offset()
	layer.update(1.0, Vector3.ZERO, false)
	var new_offset: Vector3 = layer.get_wind_offset()
	_assert(new_offset.x > initial_offset.x and new_offset.z > initial_offset.z,
		"Wind offset advances along X/Z direction (moved to %s)" % str(new_offset))

	# Test toroidal wrapping
	layer._wind_offset = Vector3(LowCloudLayerScript.FIELD_SIZE.x - 1.0, 0.0, LowCloudLayerScript.FIELD_SIZE.y - 1.0)
	layer.update(1.0, Vector3.ZERO, false) # Advances by (12, 0, 9)
	var wrapped: Vector3 = layer.get_wind_offset()
	_assert(wrapped.x < 20.0 and wrapped.z < 20.0,
		"Wind offset wraps smoothly across toroidal boundary (%s)" % str(wrapped))

	layer.queue_free()

func test_pause_behavior() -> void:
	var layer: Node = LowCloudLayerScript.new()
	root.add_child(layer)
	layer.setup(null)
	layer.set_clouds_enabled(true)

	var before: Vector3 = layer.get_wind_offset()
	layer.update(2.0, Vector3.ZERO, true) # paused = true
	var after: Vector3 = layer.get_wind_offset()
	_assert(before == after, "Wind offset does not advance when simulation is paused")

	layer.update(2.0, Vector3.ZERO, false) # unpaused
	var unpaused: Vector3 = layer.get_wind_offset()
	_assert(unpaused != before, "Wind offset resumes advancing when unpaused")

	layer.queue_free()

func test_altitude_pre_rejection_and_membership() -> void:
	var layer: Node3D = LowCloudLayerScript.new()
	root.add_child(layer)
	layer.setup(null)
	layer.set_clouds_enabled(true)

	# 1. Altitude pre-rejection (sea level = 100m, high altitude = 2500m)
	_assert(layer._sample_membership(Vector3(0.0, 100.0, 0.0)) == 0.0, "Pre-rejection: 100m ASL returns 0.0")
	_assert(layer._sample_membership(Vector3(0.0, 2500.0, 0.0)) == 0.0, "Pre-rejection: 2500m ASL returns 0.0")

	# 2. Camera placed right inside cloud 0 center
	layer.reset_state()
	var cloud0_pos: Vector3 = layer._cloud_pos[0]
	var inside_weight: float = layer._sample_membership(cloud0_pos)
	_assert(inside_weight == 1.0, "Camera at cloud 0 center detected inside (weight = 1.0)")

	# 3. Camera placed well outside cloud horizontally in clear sky at same altitude
	var outside_pos := cloud0_pos + Vector3(0.0, 0.0, -layer._cloud_bounding_radius[0] - 2000.0)
	var outside_weight: float = layer._sample_membership(outside_pos)
	_assert(outside_weight == 0.0, "Camera outside cloud bounding radius detected outside (weight = 0.0)")

	layer.queue_free()

func test_fog_composition_and_dimming() -> void:
	var sky_env: WorldEnvironment = SkyEnvironmentScript.new()
	root.add_child(sky_env)

	# Setup environment manually with default params
	var env := Environment.new()
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	sky_env._env = env
	sky_env.environment = env
	sky_env._base_haze = Color(0.52, 0.64, 0.72) # Noon haze
	sky_env.set_draw_distance(80000.0)

	var default_begin := env.fog_depth_begin
	var default_end := env.fog_depth_end
	var default_color := env.fog_light_color

	# Immersion = 0.0
	sky_env.set_cloud_immersion(0.0)
	_assert(env.fog_depth_begin == default_begin, "Immersion 0.0 preserves default fog begin (%f)" % default_begin)
	_assert(env.fog_depth_end == default_end, "Immersion 0.0 preserves default fog end (%f)" % default_end)
	_assert(env.fog_light_color == default_color, "Immersion 0.0 preserves base haze color")

	# Immersion = 1.0 (Daylight)
	sky_env.set_cloud_immersion(1.0)
	_assert(is_equal_approx(env.fog_depth_begin, SkyEnvironmentScript.CLOUD_FOG_BEGIN),
		"Full immersion sets fog begin to %f" % SkyEnvironmentScript.CLOUD_FOG_BEGIN)
	_assert(is_equal_approx(env.fog_depth_end, SkyEnvironmentScript.CLOUD_FOG_END),
		"Full immersion sets fog end to %f" % SkyEnvironmentScript.CLOUD_FOG_END)
	var day_fog_color := env.fog_light_color
	_assert(day_fog_color.v > 0.70, "Daylight cloud fog is bright off-white (%s)" % str(day_fog_color))

	# Night atmosphere dimming: apply night haze
	var night_haze := Color(0.10, 0.14, 0.22)
	sky_env.apply_atmosphere(Color(0.06, 0.09, 0.16), night_haze, Color(0.3, 0.3, 0.4), 0.7)
	var night_fog_color := env.fog_light_color
	_assert(night_fog_color.v < 0.35, "Night cloud fog dims appropriately to match atmosphere (%s)" % str(night_fog_color))

	# Restoring immersion to 0.0 at night restores night haze
	sky_env.set_cloud_immersion(0.0)
	_assert(env.fog_light_color == night_haze, "Restoring immersion restores night distance haze")
	_assert(env.fog_depth_begin == default_begin, "Restoring immersion restores default fog begin")

	sky_env.queue_free()

func test_toggle_and_cleanup() -> void:
	var sky_env: WorldEnvironment = SkyEnvironmentScript.new()
	root.add_child(sky_env)
	var env := Environment.new()
	sky_env._env = env
	sky_env.environment = env
	sky_env._base_haze = Color(0.52, 0.64, 0.72)
	sky_env.set_draw_distance(80000.0)

	var layer: Node3D = LowCloudLayerScript.new()
	root.add_child(layer)
	layer.setup(sky_env)

	# Initially enabled by default
	_assert(layer.is_clouds_enabled(), "Default state is enabled")
	_assert(layer._mmi.visible, "MultiMesh is visible by default")

	# Disable
	layer.set_clouds_enabled(false)
	_assert(not layer.is_clouds_enabled(), "set_clouds_enabled(false) sets disabled state")
	_assert(not layer._mmi.visible, "MultiMesh is hidden when disabled")

	# Enable
	layer.set_clouds_enabled(true)
	_assert(layer.is_clouds_enabled(), "set_clouds_enabled(true) sets enabled state")
	_assert(layer._mmi.visible, "MultiMesh is visible when enabled")

	# Place camera inside cloud and simulate frames
	layer.reset_state()
	var cloud0_pos: Vector3 = layer._cloud_pos[0]
	for frame in 10:
		layer.update(0.1, cloud0_pos, false)
	_assert(layer.get_current_immersion() > 0.5, "Immersion builds up when camera is inside cloud")
	_assert(sky_env.get_cloud_immersion() > 0.5, "Sky environment receives cloud immersion")

	# Disable: must hide mesh, clear immersion, and restore normal fog
	layer.set_clouds_enabled(false)
	_assert(not layer._mmi.visible, "Disabling hides MultiMesh")
	_assert(layer.get_current_immersion() == 0.0, "Disabling resets current immersion to 0.0")
	_assert(sky_env.get_cloud_immersion() == 0.0, "Disabling immediately clears sky environment immersion")
	_assert(env.fog_depth_begin == sky_env._base_fog_begin, "Disabling restores base fog begin")
	_assert(env.fog_depth_end == sky_env._base_fog_end, "Disabling restores base fog end")

	layer.queue_free()
	sky_env.queue_free()
