extends Control
class_name ControlsOverlay

# ==============================================================================
# YSFlight Godot Port - Controls HUD Overlay
# ==============================================================================
# Draws:
# 1. Mouse-stick neutral ring and deflection cross (when mouse stick active in cockpit/exterior).
# 2. Input overlay bars (Pitch, Roll, Rudder, Throttle/Afterburner, Device).
# ==============================================================================

var main: Node = null
var controls: Node = null

const HUD_GREEN := Color(0.35, 1.0, 0.35, 0.9)
const HUD_FAINT_GREEN := Color(0.35, 1.0, 0.35, 0.3)
const AB_ORANGE := Color(1.0, 0.6, 0.1, 0.95)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func setup(p_main: Node, p_controls: Node) -> void:
	main = p_main
	controls = p_controls

var _drew_last_frame := false

# Redraw only while something is shown (plus one frame to clear it)
func _process(_delta: float) -> void:
	var shown: bool = controls != null and main != null and (_stick_indicator_shown() or bool(controls.get_value("show_input_overlay", false)))
	if shown or _drew_last_frame:
		queue_redraw()
	_drew_last_frame = shown

func _stick_indicator_shown() -> bool:
	return bool(controls.get_value("show_stick_indicator", true)) and not bool(main.get("ai_player_mode")) \
		and controls.get_active_stick_device_name() == "Mouse" and main.camera_rig.mode == 1

func _draw() -> void:
	if controls == null or main == null:
		return

	var vp_rect := get_viewport_rect()

	# --- 1. Mouse Stick Indicator ---
	if _stick_indicator_shown(): # cockpit only (it sat on top of the jet in F2)
		var centre: Vector2 = vp_rect.size * 0.5
		var scale_factor: float = max(0.45 * vp_rect.size.y, 1.0)
		var mpos: Vector2 = get_viewport().get_mouse_position()
		var diff: Vector2 = mpos - centre

		var clamped_x: float = clamp(diff.x, -scale_factor, scale_factor)
		var clamped_y: float = clamp(diff.y, -scale_factor, scale_factor)
		var stick_pos: Vector2 = centre + Vector2(clamped_x, clamped_y)

		# Neutral center circle
		draw_arc(centre, 6.0, 0.0, TAU, 32, HUD_GREEN, 1.5, true)

		# Subtle line from neutral to stick position
		draw_line(centre, stick_pos, HUD_FAINT_GREEN, 1.0, true)

		# Stick deflection crosshair (+)
		var cross_len: float = 6.0
		draw_line(stick_pos + Vector2(-cross_len, 0.0), stick_pos + Vector2(cross_len, 0.0), HUD_GREEN, 1.5, true)
		draw_line(stick_pos + Vector2(0.0, -cross_len), stick_pos + Vector2(0.0, cross_len), HUD_GREEN, 1.5, true)

	# --- 2. Input Overlay ---
	if bool(controls.get_value("show_input_overlay", false)):
		var box_w := 205.0
		var box_h := 135.0
		var box_x := 20.0
		var box_y := vp_rect.size.y - box_h - 20.0

		# Background box & outline
		draw_rect(Rect2(box_x, box_y, box_w, box_h), Color(0.0, 0.0, 0.0, 0.7), true)
		draw_rect(Rect2(box_x, box_y, box_w, box_h), HUD_FAINT_GREEN, false, 1.0)

		var font: Font = ThemeDB.fallback_font
		var font_size: int = 12

		var dev_name: String = controls.get_active_stick_device_name()
		draw_string(font, Vector2(box_x + 8.0, box_y + 18.0), "STICK: " + dev_name.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, HUD_GREEN)

		var state: Dictionary = controls.get_flight_controls_state()
		var p: float = float(state.get("pitch", 0.0))
		var r: float = float(state.get("roll", 0.0))
		var y: float = float(state.get("rudder", 0.0))
		var thr: float = float(state.get("throttle", 0.0))
		var ab: bool = bool(state.get("afterburner", false))

		var bar_x: float = box_x + 65.0
		var bar_w: float = 125.0
		var bar_h: float = 8.0

		_draw_center_bar(font, "PITCH", p, box_x + 8.0, bar_x, box_y + 36.0, bar_w, bar_h)
		_draw_center_bar(font, "ROLL", r, box_x + 8.0, bar_x, box_y + 58.0, bar_w, bar_h)
		_draw_center_bar(font, "RUDDER", y, box_x + 8.0, bar_x, box_y + 80.0, bar_w, bar_h)
		_draw_throttle_bar(font, thr, ab, box_x + 8.0, bar_x, box_y + 102.0, bar_w, bar_h)

func _draw_center_bar(font: Font, label: String, val: float, lx: float, bx: float, by: float, bw: float, bh: float) -> void:
	draw_string(font, Vector2(lx, by + bh), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, HUD_GREEN)
	# Bar background
	draw_rect(Rect2(bx, by, bw, bh), Color(0.12, 0.18, 0.12, 0.8), true)
	draw_rect(Rect2(bx, by, bw, bh), HUD_FAINT_GREEN, false, 1.0)

	# Center zero tick
	var mid_x: float = bx + bw * 0.5
	draw_line(Vector2(mid_x, by - 2.0), Vector2(mid_x, by + bh + 2.0), Color(0.7, 0.7, 0.7, 0.8), 1.0)

	# Bar fill
	var c_val: float = clamp(val, -1.0, 1.0)
	var half_w: float = bw * 0.5
	if c_val > 0.0:
		draw_rect(Rect2(mid_x, by, c_val * half_w, bh), HUD_GREEN, true)
	elif c_val < 0.0:
		draw_rect(Rect2(mid_x + c_val * half_w, by, -c_val * half_w, bh), HUD_GREEN, true)

func _draw_throttle_bar(font: Font, thr: float, ab: bool, lx: float, bx: float, by: float, bw: float, bh: float) -> void:
	var label: String = "THR %d%%%s" % [int(round(thr * 100.0)), " [AB]" if ab else ""]
	var col := AB_ORANGE if ab else HUD_GREEN
	draw_string(font, Vector2(lx, by + bh), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)

	# Bar background
	draw_rect(Rect2(bx, by, bw, bh), Color(0.12, 0.18, 0.12, 0.8), true)
	draw_rect(Rect2(bx, by, bw, bh), HUD_FAINT_GREEN, false, 1.0)

	# Bar fill
	var fill_w: float = clamp(thr, 0.0, 1.0) * bw
	draw_rect(Rect2(bx, by, fill_w, bh), col, true)
