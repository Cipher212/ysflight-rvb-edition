extends Node3D

# F-16 experiment: one shared 2D viewport, one opaque mesh draw, no per-aircraft screens.
# main.gd supplies the already-fetched telemetry and interpolated player transform.
const CanvasScript := preload("res://ui/cockpit/mfd_canvas.gd")
const GEOMETRY_PATH := "res://ui/cockpit/f16_screens.json"
const REFRESH_SECONDS := 0.1
const PREWARM_FRAMES := 30

var _controls: Node = null
var _enabled := true
var _geometry: Dictionary = {}
var _viewport: SubViewport = null
var _canvas: Control = null
var _mesh: MeshInstance3D = null
var _remaining := 0.0
var _lock := false
var _missile := false
var _camera: Camera3D = null
var _initial_telemetry: Dictionary = {}
var _prewarm: MeshInstance3D = null
var _prewarm_left := 0

func setup(controls: Node, camera: Camera3D, telemetry: Dictionary) -> void:
	_controls = controls
	_camera = camera
	_initial_telemetry = telemetry
	_geometry = JSON.parse_string(FileAccess.get_file_as_string(GEOMETRY_PATH))
	_controls.changed.connect(_on_setting_changed)
	_on_setting_changed("cockpit_mfd")
	visible = false

func _on_setting_changed(key: String) -> void:
	if key == "cockpit_mfd" or key.is_empty():
		_enabled = bool(_controls.get_value("cockpit_mfd", true))
		_remaining = 0.0
		if _enabled and str(_initial_telemetry.get("identifier", "")) == str(_geometry.get("identifier", "")) and _mesh == null:
			_create_display()
			_warm_material()
		if not _enabled:
			visible = false
			if _viewport != null:
				_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

func update_display(delta: float, player_tfm: Transform3D, tel: Dictionary, player_cockpit: bool, airplanes: Dictionary = {}, grounds: Dictionary = {}) -> void:
	if _prewarm != null:
		_prewarm_left -= 1
		if _prewarm_left <= 0:
			_prewarm.queue_free()
			_prewarm = null
	var active := _enabled and player_cockpit and bool(tel.get("is_alive", false)) and str(tel.get("identifier", "")) == str(_geometry.get("identifier", ""))
	var was_visible := visible
	if visible != active:
		visible = active
	if not active:
		if _viewport != null and _prewarm == null:
			_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	if _mesh == null:
		_create_display()
	# Rewritten from MotionInterp each frame: no persistent world positions to rebase.
	if global_transform != player_tfm:
		global_transform = player_tfm
	_remaining -= delta
	var locked := bool(tel.get("is_locked_by_enemy", false))
	var missile := bool(tel.get("is_missile_chasing", false))
	if _remaining > 0.0 and was_visible and locked == _lock and missile == _missile:
		return
	_remaining = REFRESH_SECONDS
	_lock = locked
	_missile = missile
	
	var target = airplanes.get(int(tel.get("locked_air_target_key", -1)), {})
	if target.is_empty():
		target = grounds.get(int(tel.get("locked_ground_target_key", -1)), {})
		
	if _canvas.set_telemetry(tel, player_tfm, target) or not was_visible:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _create_display() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "MFDAtlas"
	_viewport.size = Vector2i(512, 256)
	_viewport.disable_3d = true
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_canvas = CanvasScript.new()
	_canvas.size = Vector2(512, 256)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(_canvas)
	var verts := PackedVector3Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	# Offset 1mm toward tail (+Z in Godot) to prevent clipping with cockpit panel
	const TAIL_OFFSET_Z := 0.001
	for screen: Dictionary in _geometry.screens:
		var base := verts.size()
		for point: Array in screen.vertices:
			verts.append(Vector3(point[0], point[1], point[2] + TAIL_OFFSET_Z))
		for point: Array in screen.uv:
			uv.append(Vector2(point[0], point[1]))
		for index: int in screen.indices:
			indices.append(base + index)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var shader := preload("res://shaders/crt_mfd.gdshader")
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("screen_texture", _viewport.get_texture())
	material.set_shader_parameter("scanline_count", 256.0)
	material.set_shader_parameter("scanline_intensity", 0.4)
	material.set_shader_parameter("bloom_intensity", 0.5)
	material.set_shader_parameter("curvature", 1.2)
	mesh.surface_set_material(0, material)
	_mesh = MeshInstance3D.new()
	_mesh.name = "ScreenSurfaces"
	_mesh.mesh = mesh
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)

func _warm_material() -> void:
	# Same technique as C++ VisualSync::build_prewarm: a zero-area triangle compiles
	# the exact material/vertex format during startup, without putting a mark on screen.
	_canvas.set_telemetry(_initial_telemetry, Transform3D.IDENTITY, {})
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _mesh.mesh.surface_get_material(0))
	mesh.custom_aabb = AABB(Vector3(-1, -1, -2), Vector3(2, 2, 2))
	_prewarm = MeshInstance3D.new()
	_prewarm.name = "MFDMaterialPrewarm"
	_prewarm.mesh = mesh
	_prewarm.position.z = -1.0
	_prewarm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_camera.add_child(_prewarm)
	_prewarm_left = PREWARM_FRAMES

func _exit_tree() -> void:
	if is_instance_valid(_prewarm):
		_prewarm.queue_free()
