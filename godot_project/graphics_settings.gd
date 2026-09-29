extends Node
class_name GraphicsSettings

# ==============================================================================
# YSFlight Godot Port - Graphics Settings Manager (graphics_settings.gd)
# ==============================================================================
# Applies 3D viewport rendering parameters, anti-aliasing, draw distance, and
# frame rate pacing:
#   - render_scale: 0.5..1.0 with Viewport FSR upscaling (< 1.0) or Bilinear (1.0).
#   - vsync: DisplayServer window V-Sync mode (avoids jittery Engine.max_fps).
#   - msaa: Viewport MSAA 3D mode (Off / 2x / 4x / 8x).
#   - fxaa: Viewport screen space FXAA toggle.
#   - draw_distance_km: Camera3D far plane in metres (20..120 km).
#   - fx_density: effects quality Low/Medium/High -> main.set_effects_quality (trail points, puff pools).
#   - graphics_preset: Synchronises Low/Medium/High presets or sets Custom on edit.
#
# BENCHMARK MODE:
#   In benchmark mode (main.benchmark_mode), saved settings are ignored and
#   Medium values are strictly enforced so runs remain comparable. V-Sync is
#   handled solely by the benchmark runner.
# ==============================================================================

var main: Node = null
var controls: Node = null
var _applying_preset: bool = false

func setup(p_main: Node, p_controls: Node) -> void:
	main = p_main
	controls = p_controls
	if controls != null:
		controls.changed.connect(_on_controls_changed)
	apply_all_settings()

func _on_controls_changed(key: String) -> void:
	if _applying_preset:
		return
	if main != null and main.benchmark_mode:
		return

	if key == "graphics_preset":
		var preset: String = str(controls.get_value("graphics_preset", "Medium"))
		if preset != "Custom":
			_apply_preset(preset)
	elif key in ["render_scale", "msaa", "fxaa", "draw_distance_km", "fx_density"]:
		_set_preset_custom()
		_apply_setting(key)
	elif key == "vsync":
		_apply_vsync()
	elif key.is_empty():
		apply_all_settings()

func _apply_preset(preset: String) -> void:
	if preset == "Custom" or controls == null:
		return

	_applying_preset = true
	match preset:
		"Low":
			controls.set_value("render_scale", 0.75)
			controls.set_value("msaa", "Off")
			controls.set_value("fxaa", false)
			controls.set_value("fx_density", "Low")
			controls.set_value("draw_distance_km", 40.0)
		"Medium":
			controls.set_value("render_scale", 1.0)
			controls.set_value("msaa", "Off")
			controls.set_value("fxaa", false)
			controls.set_value("fx_density", "Medium")
			controls.set_value("draw_distance_km", 80.0)
		"High":
			controls.set_value("render_scale", 1.0)
			controls.set_value("msaa", "4x")
			controls.set_value("fxaa", false)
			controls.set_value("fx_density", "High")
			controls.set_value("draw_distance_km", 80.0)
	_applying_preset = false

	apply_all_settings()
	controls.changed.emit("")

func _set_preset_custom() -> void:
	if controls == null:
		return
	var cur: String = str(controls.get_value("graphics_preset", "Medium"))
	if cur != "Custom":
		_applying_preset = true
		controls.set_value("graphics_preset", "Custom")
		_applying_preset = false
		controls.changed.emit("")

func apply_all_settings() -> void:
	if main != null and main.benchmark_mode:
		_apply_benchmark_defaults()
		return

	_apply_render_scale()
	_apply_vsync()
	_apply_msaa()
	_apply_fxaa()
	_apply_draw_distance()
	_apply_fx_quality()

func _apply_benchmark_defaults() -> void:
	# In benchmark mode, enforce Medium values and leave vsync to benchmark.gd
	var vp: Viewport = get_viewport()
	if vp != null:
		vp.scaling_3d_scale = 1.0
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	if main != null and main.camera != null:
		main.camera.far = 80000.0
	if main != null:
		main.set_effects_quality(1) # Medium

func _apply_setting(key: String) -> void:
	match key:
		"render_scale":
			_apply_render_scale()
		"msaa":
			_apply_msaa()
		"fxaa":
			_apply_fxaa()
		"draw_distance_km":
			_apply_draw_distance()
		"fx_density":
			_apply_fx_quality()

func _apply_render_scale() -> void:
	var vp: Viewport = get_viewport()
	if vp == null or controls == null:
		return
	var scale_val: float = float(controls.get_value("render_scale", 1.0))
	scale_val = clamp(scale_val, 0.5, 1.0)
	vp.scaling_3d_scale = scale_val
	if scale_val < 1.0:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	else:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR

func _apply_vsync() -> void:
	if main != null and main.benchmark_mode:
		return
	if controls == null:
		return
	var vsync_on: bool = bool(controls.get_value("vsync", true))
	# Cap the frame rate with vsync; Godot's Engine.max_fps limiter was measured to be jittery on Windows.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync_on else DisplayServer.VSYNC_DISABLED)

func _apply_msaa() -> void:
	var vp: Viewport = get_viewport()
	if vp == null or controls == null:
		return
	var msaa_str: String = str(controls.get_value("msaa", "Off"))
	match msaa_str:
		"2x":
			vp.msaa_3d = Viewport.MSAA_2X
		"4x":
			vp.msaa_3d = Viewport.MSAA_4X
		"8x":
			vp.msaa_3d = Viewport.MSAA_8X
		_:
			vp.msaa_3d = Viewport.MSAA_DISABLED

func _apply_fxaa() -> void:
	var vp: Viewport = get_viewport()
	if vp == null or controls == null:
		return
	var fxaa_on: bool = bool(controls.get_value("fxaa", false))
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if fxaa_on else Viewport.SCREEN_SPACE_AA_DISABLED

func _apply_draw_distance() -> void:
	if main == null or main.camera == null or controls == null:
		return
	var dist_km: float = float(controls.get_value("draw_distance_km", 80.0))
	main.camera.far = clamp(dist_km, 20.0, 120.0) * 1000.0

func _apply_fx_quality() -> void:
	if main == null or controls == null:
		return
	var names := ["Low", "Medium", "High"]
	main.set_effects_quality(maxi(names.find(str(controls.get_value("fx_density", "Medium"))), 0))
