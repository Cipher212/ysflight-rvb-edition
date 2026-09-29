extends Label

# Small frame-rate / latency readout, top right (setting "Show FPS / Latency", HUD section). Refreshed 4x
# per second:  FPS | average frame time | worst frame in the last second | GPU time | estimated input lag.
# Input lag estimate = one physics tick (inputs are read at the next 60 Hz tick, and the picture shows the
# sim up to one tick late because of motion interpolation) + CPU frame time + GPU time, + one refresh when
# V-Sync is on. It is an estimate for spotting problems, not a measurement of the display.

const REFRESH_S := 0.25

var controls: Node = null

var _window_frames: int = 0
var _window_time: float = 0.0
var _worst_ms: float = 0.0
var _worst_hold: float = 0.0
var _last_usec: int = 0

func _init() -> void:
	name = "FpsMonitor"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_theme_color_override("font_color", Color(0.9, 0.95, 0.9, 0.9))
	add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.8))
	add_theme_constant_override("outline_size", 3)
	add_theme_font_size_override("font_size", 14)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	position = Vector2(get_viewport_rect().size.x - 620.0, 6.0)
	size = Vector2(610.0, 20.0)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

func _process(delta: float) -> void:
	visible = controls == null or bool(controls.get_value("show_fps_monitor", true))
	var now := Time.get_ticks_usec()
	var frame_ms: float = (now - _last_usec) / 1000.0 if _last_usec > 0 else delta * 1000.0
	_last_usec = now
	_window_frames += 1
	_window_time += delta
	_worst_hold += delta
	if _worst_hold > 1.0: # worst frame of roughly the last second
		_worst_hold = 0.0
		_worst_ms = 0.0
	_worst_ms = maxf(_worst_ms, frame_ms)
	if _window_time < REFRESH_S or not visible:
		return
	var avg_ms: float = _window_time * 1000.0 / _window_frames
	var rid := get_viewport().get_viewport_rid()
	var gpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(rid)
	var tick_ms: float = 1000.0 / Engine.physics_ticks_per_second
	var lag_ms: float = tick_ms + avg_ms + gpu_ms
	if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
		lag_ms += 1000.0 / maxf(DisplayServer.screen_get_refresh_rate(), 30.0)
	text = "%d FPS | %.1f ms | worst %.1f ms | GPU %.1f ms | input lag ~%d ms" % [
		roundi(_window_frames / _window_time), avg_ms, _worst_ms, gpu_ms, roundi(lag_ms)]
	position.x = get_viewport_rect().size.x - size.x - 10.0
	_window_frames = 0
	_window_time = 0.0
