extends Control

# ==============================================================================
# YSFlight Godot Port - Helmet-Mounted Combat HUD
# ==============================================================================
# Designed after planning/HUD.png and YSFlight's helmet-mounted vector HUD.
#
# Performance target: Potato laptops at 1080p, 60 FPS (budget < 0.5 ms per frame).
# Single Control drawing everything in _draw():
#   - Pre-cached font and colors
#   - Conformal horizon pitch ladder matching 3D world horizon
#   - Velocity vector (flight-path marker)
#   - Boresight cross
#   - Dynamic airspeed and altitude tapes
#   - Vertical speed scale ("VS:" +/-)
#   - Weapon list (selected >>NAME:count<<, others indented)
#   - Mach, G-force (amber >=9G, red >=11G), fuel bar + flashing low-fuel warning
#   - Throttle bar (with amber afterburner)
#   - Miniature attitude indicator
#   - Systems status (gear, brake, flaps, spoiler) with declutter
#   - Target container boxes, missile lock diamond, off-screen target edge arrows
#   - Lead computing gun pipper
#   - Missile / Lock threat warnings
#
# Modes:
#   - Cockpit View (cam_mode == 1): Full HUD with pitch ladder, boresight, FPM, bank arc.
#   - Exterior View (cam_mode != 1): Decluttered HUD (tapes, fuel/throttle, weapons, warnings, targets).
#   - Dead (is_alive == false): Blank screen.
# ==============================================================================

const BANK_TICKS: Array[float] = [0.0, 10.0, 20.0, 30.0, 45.0, 60.0, -10.0, -20.0, -30.0, -45.0, -60.0]

var controls: Node = null
var camera: Camera3D = null
var player_transform: Transform3D = Transform3D.IDENTITY
var cam_mode: int = 1
var telemetry: Dictionary = {}
var airplane_transforms: Dictionary = {}
var ground_transforms: Dictionary = {}

var _font: Font = null
var _fuel_low_triggered: bool = false
var _fuel_banner_timer: float = 0.0
var _drew_last_frame := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = ThemeDB.fallback_font

func setup(p_controls: Node) -> void:
	controls = p_controls
	controls.changed.connect(_on_setting_changed)
	_on_setting_changed("hide_hud")

func _on_setting_changed(key: String) -> void:
	if key == "hide_hud" or key.is_empty():
		visible = not bool(controls.get_value("hide_hud", false))
		if visible:
			queue_redraw()

func update_hud(
	delta: float,
	p_cam: Camera3D,
	p_player_tfm: Transform3D,
	p_cam_mode: int,
	p_telemetry: Dictionary,
	p_air_tfms: Dictionary,
	p_gnd_tfms: Dictionary
) -> void:
	camera = p_cam
	player_transform = p_player_tfm
	cam_mode = p_cam_mode
	telemetry = p_telemetry
	airplane_transforms = p_air_tfms
	ground_transforms = p_gnd_tfms

	# Fuel low warning logic: one-time centered "FUEL LOW" banner for 4 s (re-arm > 25%)
	var fuel_pct: float = float(telemetry.get("fuel_pct", 100.0))
	if fuel_pct < 20.0:
		if not _fuel_low_triggered:
			_fuel_low_triggered = true
			_fuel_banner_timer = 4.0
	elif fuel_pct > 25.0:
		_fuel_low_triggered = false

	if _fuel_banner_timer > 0.0:
		_fuel_banner_timer = maxf(0.0, _fuel_banner_timer - delta)

	# Cockpit view (1) and look-down view (9) draw HUD; redraw once more after leaving to clear canvas
	var is_hud_view: bool = visible and (cam_mode == 1 or cam_mode == 9)
	if is_hud_view or _drew_last_frame:
		queue_redraw()
	_drew_last_frame = is_hud_view

func _draw() -> void:
	if camera == null or telemetry.is_empty():
		return
	if not bool(telemetry.get("is_alive", true)):
		return
	# User rule: the HUD is a helmet display and only exists in internal (cockpit, F1) and look-down views
	if cam_mode != 1 and cam_mode != 9:
		return

	if _font == null:
		_font = ThemeDB.fallback_font

	var vp_size: Vector2 = size
	if vp_size.x <= 10.0 or vp_size.y <= 10.0:
		vp_size = get_viewport_rect().size
	if vp_size.x <= 10.0 or vp_size.y <= 10.0:
		vp_size = Vector2(1920.0, 1080.0)

	var hud_scale: float = 1.0
	var color_name: String = "Green"
	if controls != null:
		hud_scale = float(controls.get_value("hud_scale", 1.0))
		color_name = str(controls.get_value("hud_color", "Green"))

	var base_col: Color = Color(0.35, 1.0, 0.45)
	match color_name:
		"Amber": base_col = Color(1.0, 0.75, 0.2)
		"Cyan": base_col = Color(0.2, 0.9, 1.0)
		"White": base_col = Color(0.95, 0.95, 0.95)
		_: base_col = Color(0.35, 1.0, 0.45)

	var s: float = (vp_size.y / 1080.0) * hud_scale
	if s < 0.1:
		s = 1.0
	var line_w: float = maxf(1.0, 1.5 * s)
	var font_sz: int = maxi(10, int(round(15.0 * s)))
	var half_w: float = vp_size.x * 0.5
	var half_h: float = vp_size.y * 0.5
	var vp_rect := Rect2(Vector2.ZERO, vp_size)

	var is_cockpit: bool = (cam_mode == 1 or cam_mode == 9)

	var player_pos: Vector3 = player_transform.origin
	var player_vel: Vector3 = telemetry.get("velocity", Vector3.ZERO)
	var cur_woc: int = int(telemetry.get("weapon_type", 0))

	# Pre-resolve locked target for heading tape azimuth caret and weapon cues
	var locked_air_key: int = int(telemetry.get("locked_air_target_key", -1))
	var locked_gnd_key: int = int(telemetry.get("locked_ground_target_key", -1))
	var locked_tgt: Dictionary = {}
	if cur_woc == 2 and locked_gnd_key >= 0 and ground_transforms.has(locked_gnd_key):
		locked_tgt = ground_transforms[locked_gnd_key]
	elif locked_air_key >= 0 and airplane_transforms.has(locked_air_key):
		locked_tgt = airplane_transforms[locked_air_key]

	# Compute boresight screen position (aircraft nose -Z)
	var b_sp: Vector2 = Vector2(half_w, half_h)
	var has_boresight: bool = false
	var nose_world: Vector3 = player_pos - player_transform.basis.z * 1000.0
	if not camera.is_position_behind(nose_world):
		b_sp = camera.unproject_position(nose_world)
		has_boresight = true

	# Compute Flight Path Marker (Velocity Vector) screen position
	var fpm_sp: Vector2 = b_sp
	var has_fpm: bool = false
	if player_vel.length() >= 20.0:
		var fpm_world: Vector3 = player_pos + player_vel.normalized() * 1000.0
		if not camera.is_position_behind(fpm_world):
			fpm_sp = camera.unproject_position(fpm_world)
			has_fpm = true

	# --------------------------------------------------------------------------
	# 1. Top Centre: Linear Heading Tape with Target Azimuth Caret
	# --------------------------------------------------------------------------
	if is_cockpit:
		var hdg_y: float = 58.0 * s
		var tape_half_w: float = 140.0 * s
		draw_line(Vector2(half_w - tape_half_w, hdg_y), Vector2(half_w + tape_half_w, hdg_y), base_col, line_w)

		# Center aircraft heading caret pointing up (^)
		draw_line(Vector2(half_w - 4.0 * s, hdg_y + 7.0 * s), Vector2(half_w, hdg_y), base_col, line_w)
		draw_line(Vector2(half_w + 4.0 * s, hdg_y + 7.0 * s), Vector2(half_w, hdg_y), base_col, line_w)

		# Boxed numeric heading readout above caret
		var cur_hdg: float = fmod(float(telemetry.get("heading_deg", 0.0)), 360.0)
		if cur_hdg < 0.0: cur_hdg += 360.0
		var cur_hdg_int: int = int(round(cur_hdg)) % 360
		var hdg_box_w: float = 34.0 * s
		var hdg_box_h: float = 16.0 * s
		draw_rect(Rect2(half_w - hdg_box_w * 0.5, hdg_y - 24.0 * s, hdg_box_w, hdg_box_h), base_col, false, line_w)
		draw_string(_font, Vector2(half_w - hdg_box_w * 0.5, hdg_y - 12.0 * s), "%03d" % cur_hdg_int, HORIZONTAL_ALIGNMENT_CENTER, hdg_box_w, maxi(8, font_sz - 2), base_col)

		# Ticks every 5 deg, labels every 10 deg (YS style: heading/10)
		var px_per_hdg_deg: float = (tape_half_w * 2.0) / 50.0
		var min_h: int = int(floor((cur_hdg - 25.0) / 5.0)) * 5
		var max_h: int = int(ceil((cur_hdg + 25.0) / 5.0)) * 5
		for h_tick in range(min_h, max_h + 1, 5):
			var diff: float = float(h_tick) - cur_hdg
			if absf(diff) > 25.0:
				continue
			var tx: float = half_w + diff * px_per_hdg_deg
			var is_10: bool = (h_tick % 10 == 0)
			var t_len: float = (8.0 if is_10 else 4.0) * s
			draw_line(Vector2(tx, hdg_y), Vector2(tx, hdg_y - t_len), base_col, line_w)
			if is_10:
				var norm_h: int = (h_tick % 360 + 360) % 360
				var ys_val: int = norm_h / 10
				if ys_val == 0:
					ys_val = 36
				if absf(tx - half_w) < 28.0 * s:
					continue # hidden under the boxed heading readout
				draw_string(_font, Vector2(tx - 12.0 * s, hdg_y - 10.0 * s), "%02d" % ys_val, HORIZONTAL_ALIGNMENT_CENTER, 24.0 * s, maxi(8, font_sz - 3), base_col)

		# Target Azimuth Caret (v) sliding along heading tape
		if locked_tgt.size() > 0 and bool(locked_tgt.get("is_alive", true)):
			var tgt_p: Vector3 = locked_tgt.get("pos", Vector3.ZERO)
			var local_tgt: Vector3 = player_transform.affine_inverse() * tgt_p
			var bearing_rad: float = atan2(local_tgt.x, -local_tgt.z)
			var rel_deg: float = rad_to_deg(bearing_rad)
			var caret_x: float = half_w + rel_deg * px_per_hdg_deg
			var clamped_x: float = clampf(caret_x, half_w - tape_half_w, half_w + tape_half_w)
			# Downward caret 'v'
			draw_line(Vector2(clamped_x - 4.0 * s, hdg_y - 6.0 * s), Vector2(clamped_x, hdg_y), base_col, line_w)
			draw_line(Vector2(clamped_x + 4.0 * s, hdg_y - 6.0 * s), Vector2(clamped_x, hdg_y), base_col, line_w)
			draw_line(Vector2(clamped_x - 4.0 * s, hdg_y - 6.0 * s), Vector2(clamped_x + 4.0 * s, hdg_y - 6.0 * s), base_col, line_w)
			draw_string(_font, Vector2(clamped_x - 8.0 * s, hdg_y - 8.0 * s), "T", HORIZONTAL_ALIGNMENT_CENTER, 16.0 * s, maxi(7, font_sz - 4), base_col)

	# --------------------------------------------------------------------------
	# 2. Centre: Pitch Ladder (Conformal to horizon, laterally aligned with FPM)
	# --------------------------------------------------------------------------
	if is_cockpit:
		var cam_fwd: Vector3 = -camera.global_transform.basis.z
		var cam_right: Vector3 = camera.global_transform.basis.x
		var cam_up: Vector3 = camera.global_transform.basis.y

		var cam_pitch_deg: float = rad_to_deg(asin(clampf(cam_fwd.y, -1.0, 1.0)))
		var up_screen := Vector2(cam_right.y, -cam_up.y)
		var theta_roll: float = atan2(up_screen.x, -up_screen.y)

		var ladder_up := Vector2(sin(theta_roll), -cos(theta_roll))
		var ladder_right := Vector2(cos(theta_roll), sin(theta_roll))

		var tan_half_fov: float = tan(deg_to_rad(camera.fov * 0.5))
		var focal_len: float = half_h / tan_half_fov

		# Laterally center the ladder on the Velocity Vector (FPM) with smooth clamping
		var fpm_lat_off: float = (fpm_sp - Vector2(half_w, half_h)).dot(ladder_right) if has_fpm else 0.0
		fpm_lat_off = clampf(fpm_lat_off, -80.0 * s, 80.0 * s)
		var ladder_center: Vector2 = Vector2(half_w, half_h) + ladder_right * fpm_lat_off

		var min_p: int = maxi(-90, int(floor((cam_pitch_deg - 25.0) / 5.0)) * 5)
		var max_p: int = mini(90, int(ceil((cam_pitch_deg + 25.0) / 5.0)) * 5)

		for p in range(min_p, max_p + 1, 5):
			var delta_p: float = float(p) - cam_pitch_deg
			if absf(delta_p) > 25.0:
				continue
			var d_px: float = focal_len * tan(deg_to_rad(delta_p))
			var rung_ctr: Vector2 = ladder_center + ladder_up * d_px

			if p == 0:
				# 0 deg horizon line: longer solid line with center gap
				draw_line(rung_ctr - ladder_right * (120.0 * s), rung_ctr - ladder_right * (35.0 * s), base_col, line_w)
				draw_line(rung_ctr + ladder_right * (35.0 * s), rung_ctr + ladder_right * (120.0 * s), base_col, line_w)
			elif p > 0:
				# Positive rungs: solid, bent slightly downward toward horizon
				var bend_v: Vector2 = -ladder_up * (3.0 * s)
				if p % 10 == 0:
					var p_in_l := rung_ctr - ladder_right * (34.0 * s)
					var p_out_l := rung_ctr - ladder_right * (75.0 * s) + bend_v
					var p_in_r := rung_ctr + ladder_right * (34.0 * s)
					var p_out_r := rung_ctr + ladder_right * (75.0 * s) + bend_v
					draw_line(p_out_l, p_in_l, base_col, line_w)
					draw_line(p_in_r, p_out_r, base_col, line_w)
					# Downward ticks pointing toward horizon (-ladder_up)
					var tick_v := -ladder_up * (5.0 * s)
					draw_line(p_in_l, p_in_l + tick_v, base_col, line_w)
					draw_line(p_in_r, p_in_r + tick_v, base_col, line_w)
					var lbl := "%d" % p
					draw_string(_font, p_out_l - ladder_right * (16.0 * s) - ladder_up * (4.0 * s), lbl, HORIZONTAL_ALIGNMENT_CENTER, 22.0 * s, maxi(8, font_sz - 3), base_col)
					draw_string(_font, p_out_r + ladder_right * (2.0 * s) - ladder_up * (4.0 * s), lbl, HORIZONTAL_ALIGNMENT_CENTER, 22.0 * s, maxi(8, font_sz - 3), base_col)
				else:
					var p_in_l := rung_ctr - ladder_right * (34.0 * s)
					var p_out_l := rung_ctr - ladder_right * (54.0 * s) + bend_v
					var p_in_r := rung_ctr + ladder_right * (34.0 * s)
					var p_out_r := rung_ctr + ladder_right * (54.0 * s) + bend_v
					draw_line(p_out_l, p_in_l, base_col, line_w)
					draw_line(p_in_r, p_out_r, base_col, line_w)
			else:
				# Negative rungs: dashed, bent slightly upward toward horizon
				var bend_v: Vector2 = ladder_up * (3.0 * s)
				if p % 10 == 0:
					var p_in_l := rung_ctr - ladder_right * (34.0 * s)
					var p_out_l := rung_ctr - ladder_right * (75.0 * s) + bend_v
					var p_in_r := rung_ctr + ladder_right * (34.0 * s)
					var p_out_r := rung_ctr + ladder_right * (75.0 * s) + bend_v
					# 3 dashes on left
					var d_step_l: Vector2 = (p_in_l - p_out_l) / 5.0
					draw_line(p_out_l, p_out_l + d_step_l, base_col, line_w)
					draw_line(p_out_l + d_step_l * 2.0, p_out_l + d_step_l * 3.0, base_col, line_w)
					draw_line(p_out_l + d_step_l * 4.0, p_in_l, base_col, line_w)
					# 3 dashes on right
					var d_step_r: Vector2 = (p_out_r - p_in_r) / 5.0
					draw_line(p_in_r, p_in_r + d_step_r, base_col, line_w)
					draw_line(p_in_r + d_step_r * 2.0, p_in_r + d_step_r * 3.0, base_col, line_w)
					draw_line(p_in_r + d_step_r * 4.0, p_out_r, base_col, line_w)
					# Upward ticks pointing toward horizon (+ladder_up)
					var tick_v := ladder_up * (5.0 * s)
					draw_line(p_in_l, p_in_l + tick_v, base_col, line_w)
					draw_line(p_in_r, p_in_r + tick_v, base_col, line_w)
					var lbl := "%d" % p
					draw_string(_font, p_out_l - ladder_right * (18.0 * s) - ladder_up * (4.0 * s), lbl, HORIZONTAL_ALIGNMENT_CENTER, 24.0 * s, maxi(8, font_sz - 3), base_col)
					draw_string(_font, p_out_r + ladder_right * (2.0 * s) - ladder_up * (4.0 * s), lbl, HORIZONTAL_ALIGNMENT_CENTER, 24.0 * s, maxi(8, font_sz - 3), base_col)
				else:
					var p_in_l := rung_ctr - ladder_right * (34.0 * s)
					var p_out_l := rung_ctr - ladder_right * (54.0 * s) + bend_v
					var p_in_r := rung_ctr + ladder_right * (34.0 * s)
					var p_out_r := rung_ctr + ladder_right * (54.0 * s) + bend_v
					var d_step_l: Vector2 = (p_in_l - p_out_l) / 3.0
					draw_line(p_out_l, p_out_l + d_step_l, base_col, line_w)
					draw_line(p_out_l + d_step_l * 2.0, p_in_l, base_col, line_w)
					var d_step_r: Vector2 = (p_out_r - p_in_r) / 3.0
					draw_line(p_in_r, p_in_r + d_step_r, base_col, line_w)
					draw_line(p_in_r + d_step_r * 2.0, p_out_r, base_col, line_w)

	# --------------------------------------------------------------------------
	# 3. Boresight / Gun Cross (Project aircraft nose -Z)
	# --------------------------------------------------------------------------
	if is_cockpit and has_boresight:
		draw_line(b_sp + Vector2(-10.0 * s, 0.0), b_sp + Vector2(-3.0 * s, 0.0), base_col, line_w)
		draw_line(b_sp + Vector2(3.0 * s, 0.0), b_sp + Vector2(10.0 * s, 0.0), base_col, line_w)
		draw_line(b_sp + Vector2(0.0, -10.0 * s), b_sp + Vector2(0.0, -3.0 * s), base_col, line_w)
		draw_line(b_sp + Vector2(0.0, 3.0 * s), b_sp + Vector2(0.0, 10.0 * s), base_col, line_w)
		draw_circle(b_sp, 1.5 * s, base_col)

	# --------------------------------------------------------------------------
	# 4. Flight-Path Marker (Velocity Vector)
	# --------------------------------------------------------------------------
	if is_cockpit and has_fpm:
		var f_r: float = 5.0 * s
		draw_arc(fpm_sp, f_r, 0.0, TAU, 16, base_col, line_w)
		draw_line(fpm_sp + Vector2(-f_r - 7.0 * s, 0.0), fpm_sp + Vector2(-f_r, 0.0), base_col, line_w)
		draw_line(fpm_sp + Vector2(f_r, 0.0), fpm_sp + Vector2(f_r + 7.0 * s, 0.0), base_col, line_w)
		draw_line(fpm_sp + Vector2(0.0, -f_r - 5.0 * s), fpm_sp + Vector2(0.0, -f_r), base_col, line_w)

	# AIM-9 Unlocked Boresight Seeker Reticle (Dashed 4-degree circle)
	var is_aim9: bool = (cur_woc == 1 or cur_woc == 10)
	var is_aim120: bool = (cur_woc == 6)
	if is_cockpit and is_aim9 and locked_tgt.size() == 0 and has_boresight:
		var r_bore: float = 20.0 * s
		for i in range(12):
			if i % 2 == 0:
				var a0: float = (float(i) / 12.0) * TAU
				var a1: float = (float(i + 1) / 12.0) * TAU
				draw_arc(b_sp, r_bore, a0, a1, 4, base_col, line_w)

	# --------------------------------------------------------------------------
	# 5. Airspeed Tape, Altitude Tape & Vertical Speed Scale
	# --------------------------------------------------------------------------
	# Left: Airspeed tape (knots)
	var x_spd: float = half_w - 240.0 * s
	var spd: float = float(telemetry.get("speed_kt", 0.0))
	var px_per_kt: float = 1.2 * s
	draw_line(Vector2(x_spd, half_h - 140.0 * s), Vector2(x_spd, half_h + 140.0 * s), base_col, line_w)

	var min_k: int = int(floor((spd - 110.0) / 20.0)) * 20
	var max_k: int = int(ceil((spd + 110.0) / 20.0)) * 20
	for k in range(min_k, max_k + 1, 20):
		if k < 0:
			continue
		var dy: float = (spd - float(k)) * px_per_kt
		var y_pos: float = half_h + dy
		if absf(y_pos - half_h) > 140.0 * s:
			continue
		var is_major: bool = (k % 40 == 0)
		var tick_len: float = (12.0 if is_major else 6.0) * s
		draw_line(Vector2(x_spd, y_pos), Vector2(x_spd + tick_len, y_pos), base_col, line_w)
		if is_major and absf(y_pos - half_h) > 16.0 * s: # hidden under the boxed speed readout
			draw_string(_font, Vector2(x_spd - 44.0 * s, y_pos + 5.0 * s), "%d" % k, HORIZONTAL_ALIGNMENT_RIGHT, 38.0 * s, maxi(8, font_sz - 1), base_col)

	# Boxed current airspeed
	draw_rect(Rect2(x_spd - 68.0 * s, half_h - 13.0 * s, 60.0 * s, 26.0 * s), base_col, false, line_w)
	draw_string(_font, Vector2(x_spd - 68.0 * s, half_h + 5.0 * s), "%d" % int(round(spd)), HORIZONTAL_ALIGNMENT_CENTER, 60.0 * s, font_sz, base_col)
	draw_line(Vector2(x_spd - 8.0 * s, half_h), Vector2(x_spd, half_h), base_col, line_w)

	# Right: Altitude tape (feet)
	var x_alt: float = half_w + 240.0 * s
	var alt: float = float(telemetry.get("altitude_ft", 0.0))
	var px_per_ft: float = 0.25 * s
	draw_line(Vector2(x_alt, half_h - 140.0 * s), Vector2(x_alt, half_h + 140.0 * s), base_col, line_w)

	var min_a: int = int(floor((alt - 500.0) / 100.0)) * 100
	var max_a: int = int(ceil((alt + 500.0) / 100.0)) * 100
	for a in range(min_a, max_a + 1, 100):
		var dy: float = (alt - float(a)) * px_per_ft
		var y_pos: float = half_h + dy
		if absf(y_pos - half_h) > 140.0 * s:
			continue
		var is_major: bool = (a % 500 == 0)
		var tick_len: float = (12.0 if is_major else 6.0) * s
		draw_line(Vector2(x_alt, y_pos), Vector2(x_alt - tick_len, y_pos), base_col, line_w)
		if is_major and absf(y_pos - half_h) > 16.0 * s: # hidden under the boxed altitude readout
			draw_string(_font, Vector2(x_alt + 16.0 * s, y_pos + 5.0 * s), "%d" % a, HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, font_sz - 1), base_col)

	# Boxed current altitude
	draw_rect(Rect2(x_alt + 8.0 * s, half_h - 13.0 * s, 68.0 * s, 26.0 * s), base_col, false, line_w)
	draw_string(_font, Vector2(x_alt + 8.0 * s, half_h + 5.0 * s), "%d" % int(round(alt)), HORIZONTAL_ALIGNMENT_CENTER, 68.0 * s, font_sz, base_col)
	draw_line(Vector2(x_alt, half_h), Vector2(x_alt + 8.0 * s, half_h), base_col, line_w)

	# Far Right: Vertical Speed scale ("VS" in hundreds of ft/min, clamp +/-20)
	var x_vs: float = half_w + 390.0 * s
	var l_vs: float = 100.0 * s
	draw_string(_font, Vector2(x_vs - 10.0 * s, half_h - 115.0 * s), "VS:", HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)
	draw_line(Vector2(x_vs, half_h - l_vs), Vector2(x_vs, half_h + l_vs), base_col, line_w)

	# Fixed scale ticks: +20, +10, 0, -10, -20
	draw_line(Vector2(x_vs - 8.0 * s, half_h - l_vs), Vector2(x_vs, half_h - l_vs), base_col, line_w)
	draw_line(Vector2(x_vs - 6.0 * s, half_h - l_vs * 0.5), Vector2(x_vs, half_h - l_vs * 0.5), base_col, line_w)
	draw_line(Vector2(x_vs - 10.0 * s, half_h), Vector2(x_vs, half_h), base_col, line_w)
	draw_string(_font, Vector2(x_vs + 4.0 * s, half_h + 5.0 * s), "0", HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, font_sz - 2), base_col)
	draw_line(Vector2(x_vs - 6.0 * s, half_h + l_vs * 0.5), Vector2(x_vs, half_h + l_vs * 0.5), base_col, line_w)
	draw_line(Vector2(x_vs - 8.0 * s, half_h + l_vs), Vector2(x_vs, half_h + l_vs), base_col, line_w)

	var vsi_fpm: float = float(telemetry.get("vsi_fpm", 0.0))
	var vs_val: float = clampf(vsi_fpm / 100.0, -20.0, 20.0)
	var vs_ptr_y: float = half_h - (vs_val / 20.0) * l_vs
	draw_line(Vector2(x_vs - 14.0 * s, vs_ptr_y), Vector2(x_vs - 2.0 * s, vs_ptr_y), base_col, line_w)
	var vs_int: int = int(round(vs_val))
	if vs_int != 0:
		draw_string(_font, Vector2(x_vs + 4.0 * s, vs_ptr_y + 5.0 * s), "%+d" % vs_int, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)

	# --------------------------------------------------------------------------
	# 6. Top Left: Weapon List
	# --------------------------------------------------------------------------
	var wpn_lines: Array[String] = []

	# GUN
	var gun_ammo: int = int(telemetry.get("gun_ammo", 0))
	if gun_ammo > 0:
		if cur_woc == 0:
			wpn_lines.append(">>GUN:%d<<" % gun_ammo)
		else:
			wpn_lines.append("  GUN:%d" % gun_ammo)

	# A-AAM (AIM-9 + AIM-9X)
	var a_aam_count: int = int(telemetry.get("aim9_count", 0)) + int(telemetry.get("aim9x_count", 0))
	if a_aam_count > 0:
		if cur_woc == 1 or cur_woc == 10:
			wpn_lines.append(">>A-AAM:%d (Short-Range)<<" % a_aam_count)
		else:
			wpn_lines.append("  A-AAM:%d (Short-Range)" % a_aam_count)

	# AAM (AIM-120)
	var aam_count: int = int(telemetry.get("aim120_count", 0))
	if aam_count > 0:
		if cur_woc == 6:
			wpn_lines.append(">>AAM:%d (Mid-Range)<<" % aam_count)
		else:
			wpn_lines.append("  AAM:%d (Mid-Range)" % aam_count)

	# AGM-65
	var agm_count: int = int(telemetry.get("agm65_count", 0))
	if agm_count > 0:
		if cur_woc == 2:
			wpn_lines.append(">>AGM:%d<<" % agm_count)
		else:
			wpn_lines.append("  AGM:%d" % agm_count)

	# BOMBS
	var bmb_count: int = int(telemetry.get("bomb_count", 0))
	if bmb_count > 0:
		if cur_woc == 3 or cur_woc == 7 or cur_woc == 9:
			wpn_lines.append(">>BOMB:%d<<" % bmb_count)
		else:
			wpn_lines.append("  BOMB:%d" % bmb_count)

	# ROCKETS
	var rkt_count: int = int(telemetry.get("rocket_count", 0))
	if rkt_count > 0:
		if cur_woc == 4:
			wpn_lines.append(">>RKT:%d<<" % rkt_count)
		else:
			wpn_lines.append("  RKT:%d" % rkt_count)

	# FLARES
	var flr_count: int = int(telemetry.get("flare_count", 0))
	if flr_count > 0:
		wpn_lines.append("  FLR:%d" % flr_count)

	var wy: float = 75.0 * s
	var wx: float = 60.0 * s
	var line_h: float = 18.0 * s
	for line_str in wpn_lines:
		draw_string(_font, Vector2(wx, wy), line_str, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)
		wy += line_h

	# --------------------------------------------------------------------------
	# 7. Bottom Left: Mach, G, Fuel Bar, Throttle Bar
	# --------------------------------------------------------------------------
	var mach: float = float(telemetry.get("mach", 0.0))
	var g_val: float = float(telemetry.get("g_force", 1.0))
	var g_col: Color = base_col
	if g_val >= 11.0:
		g_col = Color(1.0, 0.22, 0.22) # Red at/above 11G limit
	elif g_val >= 9.0:
		g_col = Color(1.0, 0.75, 0.2) # Amber from 9G

	var x_bl: float = 140.0 * s
	var y_bl: float = vp_size.y - 250.0 * s
	draw_string(_font, Vector2(x_bl, y_bl), "%.2fM" % mach, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)
	draw_string(_font, Vector2(x_bl, y_bl + 20.0 * s), "%.1fG" % g_val, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, g_col)

	# Fuel Bar
	var fuel_pct: float = float(telemetry.get("fuel_pct", 100.0))
	var is_fuel_low: bool = (fuel_pct < 20.0)
	var flash_bit_fuel: bool = (int(Time.get_ticks_msec() * 0.004) % 2) == 0
	var fuel_col: Color = (Color(1.0, 0.22, 0.22) if flash_bit_fuel else base_col) if is_fuel_low else base_col

	var x_fuel: float = x_bl + 30.0 * s
	var y_fuel: float = y_bl + 40.0 * s
	var h_bar: float = 65.0 * s
	draw_rect(Rect2(x_fuel, y_fuel, 16.0 * s, h_bar), fuel_col, false, line_w)
	var fill_fuel: float = clampf(fuel_pct / 100.0, 0.0, 1.0) * h_bar
	draw_rect(Rect2(x_fuel + 2.0 * s, y_fuel + h_bar - fill_fuel, 12.0 * s, fill_fuel), fuel_col, true)

	# Triangle marker next to fuel bar pointing left
	var m_y: float = y_fuel + h_bar - fill_fuel
	var tri_tip := Vector2(x_fuel + 18.0 * s, m_y)
	var tri_u := Vector2(x_fuel + 26.0 * s, m_y - 5.0 * s)
	var tri_d := Vector2(x_fuel + 26.0 * s, m_y + 5.0 * s)
	draw_colored_polygon(PackedVector2Array([tri_tip, tri_u, tri_d]), fuel_col)

	var fuel_str := "FUEL: %.1f%%" % fuel_pct
	draw_string(_font, Vector2(x_bl, y_fuel + h_bar + 20.0 * s), fuel_str, HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, font_sz - 1), fuel_col)

	# Throttle Bar
	var x_thr: float = x_fuel + 45.0 * s
	var thr: float = clampf(float(telemetry.get("throttle", 0.0)), 0.0, 1.0)
	var is_ab: bool = bool(telemetry.get("afterburner", false))
	var thr_col: Color = Color(1.0, 0.75, 0.2) if is_ab else base_col
	draw_rect(Rect2(x_thr, y_fuel, 12.0 * s, h_bar), base_col, false, line_w)
	var fill_thr: float = thr * h_bar
	draw_rect(Rect2(x_thr + 2.0 * s, y_fuel + h_bar - fill_thr, 8.0 * s, fill_thr), thr_col, true)

	# Notches on throttle bar (0%, 50%, 100%)
	draw_line(Vector2(x_thr + 14.0 * s, y_fuel), Vector2(x_thr + 24.0 * s, y_fuel), thr_col if is_ab else base_col, line_w)
	draw_line(Vector2(x_thr + 14.0 * s, y_fuel + h_bar * 0.5), Vector2(x_thr + 20.0 * s, y_fuel + h_bar * 0.5), base_col, line_w)
	draw_line(Vector2(x_thr + 14.0 * s, y_fuel + h_bar), Vector2(x_thr + 24.0 * s, y_fuel + h_bar), base_col, line_w)

	# Centered "FUEL LOW" banner for 4 s
	if _fuel_banner_timer > 0.0:
		var banner_col: Color = Color(1.0, 0.22, 0.22) if flash_bit_fuel else Color(1.0, 0.85, 0.2)
		draw_string(_font, Vector2(half_w - 90.0 * s, half_h - 100.0 * s), "FUEL LOW", HORIZONTAL_ALIGNMENT_CENTER, 180.0 * s, maxi(12, int(round(22.0 * s))), banner_col)

	# --------------------------------------------------------------------------
	# 8. Right Side: Systems Status Block (with Declutter)
	# --------------------------------------------------------------------------
	var gear_val: float = float(telemetry.get("gear", 1.0))
	var brake_val: float = float(telemetry.get("brake", 0.0))
	var flaps_val: float = float(telemetry.get("flaps", 0.0))
	var spoiler_val: float = float(telemetry.get("spoiler", 0.0))

	var is_clean: bool = (gear_val < 0.01 and brake_val <= 0.01 and flaps_val <= 0.001 and spoiler_val <= 0.001)
	if not is_clean:
		var ldg_str := "DWN" if gear_val >= 0.99 else ("UP" if gear_val <= 0.01 else "MOV")
		var brk_str := "ON" if brake_val > 0.01 else "OFF"
		var flp_int := int(round(flaps_val * 100.0))
		var spl_int := int(round(spoiler_val * 100.0))

		var rx: float = half_w + 390.0 * s
		var ry: float = half_h + 80.0 * s
		draw_string(_font, Vector2(rx, ry), "LDG:" + ldg_str, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)
		draw_string(_font, Vector2(rx, ry + 18.0 * s), "BRK:" + brk_str, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)
		draw_string(_font, Vector2(rx, ry + 36.0 * s), "FLP:%d%%" % flp_int, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)
		draw_string(_font, Vector2(rx, ry + 54.0 * s), "SPL:%d%%" % spl_int, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)

	# --------------------------------------------------------------------------
	# 9. Small Attitude Indicator on the Left
	# --------------------------------------------------------------------------
	var att_ctr := Vector2(120.0 * s, half_h)
	draw_arc(att_ctr, 3.5 * s, 0.0, TAU, 12, base_col, line_w)
	draw_line(att_ctr - Vector2(20.0 * s, 0.0), att_ctr - Vector2(5.0 * s, 0.0), base_col, line_w)
	draw_line(att_ctr + Vector2(5.0 * s, 0.0), att_ctr + Vector2(20.0 * s, 0.0), base_col, line_w)
	draw_line(att_ctr - Vector2(0.0, 3.5 * s), att_ctr - Vector2(0.0, 9.0 * s), base_col, line_w)

	var bank_rad_att: float = deg_to_rad(clampf(float(telemetry.get("bank_deg", 0.0)), -180.0, 180.0))
	var att_r: float = 28.0 * s
	draw_arc(att_ctr, att_r, PI * 0.5 - deg_to_rad(45.0) + bank_rad_att, PI * 0.5 + deg_to_rad(45.0) + bank_rad_att, 16, base_col, line_w)
	for ang_offset in [-45.0, 0.0, 45.0]:
		var a: float = PI * 0.5 + deg_to_rad(ang_offset) + bank_rad_att
		var d := Vector2(cos(a), sin(a))
		draw_line(att_ctr + d * att_r, att_ctr + d * (att_r + 5.0 * s), base_col, line_w)

	# --------------------------------------------------------------------------
	# 10. Targeting: Locked Target Box & Enemy Aircraft Corner Brackets
	# --------------------------------------------------------------------------
	var player_iff: int = int(telemetry.get("iff", 0))
	var is_guided: bool = (cur_woc == 1 or cur_woc == 10 or cur_woc == 6 or cur_woc == 2)
	var is_gun: bool = (cur_woc == 0)

	# Render Locked Target
	if locked_tgt.size() > 0 and bool(locked_tgt.get("is_alive", true)):
		var tgt_pos: Vector3 = locked_tgt.get("pos", Vector3.ZERO)
		var dist_m: float = player_pos.distance_to(tgt_pos)
		var dist_km: float = dist_m / 1000.0
		var is_behind: bool = camera.is_position_behind(tgt_pos)
		var sp: Vector2 = camera.unproject_position(tgt_pos) if not is_behind else Vector2.ZERO
		var margin: float = 40.0 * s
		var inner_rect: Rect2 = vp_rect.grow(-margin)
		var is_on_screen: bool = (not is_behind) and inner_rect.has_point(sp)

		if is_on_screen:
			# Flashing red lock cue for the target square
			var flash_lock: bool = (int(Time.get_ticks_msec() * 0.008) % 2) == 0
			var sq_col: Color = Color(1.0, 0.22, 0.22) if flash_lock else base_col

			# Square box around the locked target (flashes red when locked)
			var box_sz: float = 24.0 * s
			var box_rect: Rect2 = Rect2(sp.x - box_sz * 0.5, sp.y - box_sz * 0.5, box_sz, box_sz)
			draw_rect(box_rect, sq_col, false, line_w)

			if is_aim9:
				# Keep the circle! AIM-9 Uncaged Seeker Circle tracking the locked target
				var r_seek: float = 14.0 * s
				draw_arc(sp, r_seek, 0.0, TAU, 24, base_col, line_w)
				draw_circle(sp, 1.5 * s, base_col)
				draw_line(sp + Vector2(0.0, -r_seek), sp + Vector2(0.0, -r_seek - 3.0 * s), base_col, line_w)
				draw_line(sp + Vector2(0.0, r_seek), sp + Vector2(0.0, r_seek + 3.0 * s), base_col, line_w)
				draw_line(sp + Vector2(-r_seek, 0.0), sp + Vector2(-r_seek - 3.0 * s, 0.0), base_col, line_w)
				draw_line(sp + Vector2(r_seek, 0.0), sp + Vector2(r_seek + 3.0 * s, 0.0), base_col, line_w)
				draw_string(_font, Vector2(sp.x + box_sz * 0.5 + 5.0 * s, sp.y + 4.0 * s), "%.1fkm" % dist_km, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)
			elif is_aim120:
				# Radar lock diamond/circle inside the flashing square
				var r_tgt: float = 12.0 * s
				draw_arc(sp, r_tgt, 0.0, TAU, 20, base_col, line_w)
				var d_sz: float = 8.0 * s
				draw_line(sp + Vector2(0.0, -d_sz), sp + Vector2(d_sz, 0.0), base_col, line_w)
				draw_line(sp + Vector2(d_sz, 0.0), sp + Vector2(0.0, d_sz), base_col, line_w)
				draw_line(sp + Vector2(0.0, d_sz), sp + Vector2(-d_sz, 0.0), base_col, line_w)
				draw_line(sp + Vector2(-d_sz, 0.0), sp + Vector2(0.0, -d_sz), base_col, line_w)

				# Real Range and Closure Rate (Vc)
				var tgt_vel: Vector3 = locked_tgt.get("velocity", Vector3.ZERO)
				var los: Vector3 = (tgt_pos - player_pos).normalized()
				var closure_ms: float = (player_vel - tgt_vel).dot(los)
				var closure_kt: int = int(round(closure_ms * 1.94384))
				draw_string(_font, Vector2(sp.x + box_sz * 0.5 + 5.0 * s, sp.y - 1.0 * s), "%.1fkm" % dist_km, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)
				draw_string(_font, Vector2(sp.x + box_sz * 0.5 + 5.0 * s, sp.y + 13.0 * s), "VC:%+d" % closure_kt, HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, font_sz - 2), base_col)
			elif is_gun:
				# Gun Tracking: Circle inside the flashing square + range in meters
				var r_tgt: float = 12.0 * s
				draw_arc(sp, r_tgt, 0.0, TAU, 20, base_col, line_w)
				draw_string(_font, Vector2(sp.x + box_sz * 0.5 + 5.0 * s, sp.y + 4.0 * s), "%dm" % int(dist_m), HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)
			else:
				# Default guided weapon box (AGM, etc.) with inner lock circle
				var r_tgt: float = 12.0 * s
				draw_arc(sp, r_tgt, 0.0, TAU, 20, base_col, line_w)
				draw_string(_font, Vector2(sp.x + box_sz * 0.5 + 5.0 * s, sp.y + 4.0 * s), "%.1fkm" % dist_km, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, base_col)
		else:
			# Off-screen clamped target box with directional arrow at screen edge (flashes red when locked)
			var flash_lock: bool = (int(Time.get_ticks_msec() * 0.008) % 2) == 0
			var off_col: Color = Color(1.0, 0.22, 0.22) if flash_lock else base_col
			_draw_offscreen_arrow(camera, tgt_pos, dist_km, vp_rect, off_col, s, line_w, font_sz, is_guided)

	# Render other alive enemy aircraft:
	# - Within 8 km: regular corner brackets
	# - When AIM-120 selected (BVR mode, up to 40 km): BVR target boxes
	var max_detect_m: float = 40000.0 if is_aim120 else 8000.0
	for air_key in airplane_transforms.keys():
		if int(air_key) == locked_air_key:
			continue
		var st: Dictionary = airplane_transforms[air_key]
		if st.get("is_player", false) or not st.get("is_alive", true):
			continue
		if int(st.get("iff", -1)) == player_iff:
			continue

		var t_pos: Vector3 = st.get("pos", Vector3.ZERO)
		var d_m: float = player_pos.distance_to(t_pos)
		if d_m > max_detect_m or camera.is_position_behind(t_pos):
			continue

		var o_sp: Vector2 = camera.unproject_position(t_pos)
		if not vp_rect.has_point(o_sp):
			continue

		if d_m > 8000.0:
			# BVR Target Box (Dashed / segmented square with range tag)
			var bvr_sz: float = 22.0 * s
			var bvr_x: float = o_sp.x - bvr_sz * 0.5
			var bvr_y: float = o_sp.y - bvr_sz * 0.5
			var seg_len: float = 5.0 * s
			var bvr_col := Color(base_col.r, base_col.g, base_col.b, 0.75)
			# Top & bottom dashed lines
			draw_line(Vector2(bvr_x, bvr_y), Vector2(bvr_x + seg_len, bvr_y), bvr_col, line_w)
			draw_line(Vector2(bvr_x + bvr_sz - seg_len, bvr_y), Vector2(bvr_x + bvr_sz, bvr_y), bvr_col, line_w)
			draw_line(Vector2(bvr_x, bvr_y + bvr_sz), Vector2(bvr_x + seg_len, bvr_y + bvr_sz), bvr_col, line_w)
			draw_line(Vector2(bvr_x + bvr_sz - seg_len, bvr_y + bvr_sz), Vector2(bvr_x + bvr_sz, bvr_y + bvr_sz), bvr_col, line_w)
			# Left & right dashed lines
			draw_line(Vector2(bvr_x, bvr_y), Vector2(bvr_x, bvr_y + seg_len), bvr_col, line_w)
			draw_line(Vector2(bvr_x, bvr_y + bvr_sz - seg_len), Vector2(bvr_x, bvr_y + bvr_sz), bvr_col, line_w)
			draw_line(Vector2(bvr_x + bvr_sz, bvr_y), Vector2(bvr_x + bvr_sz, bvr_y + seg_len), bvr_col, line_w)
			draw_line(Vector2(bvr_x + bvr_sz, bvr_y + bvr_sz - seg_len), Vector2(bvr_x + bvr_sz, bvr_y + bvr_sz), bvr_col, line_w)
			# BVR range tag
			var bvr_tag: String = "%dKM" % int(round(d_m / 1000.0))
			var tag_sz: int = maxi(8, int(round(10.0 * s)))
			draw_string(_font, Vector2(bvr_x, bvr_y + bvr_sz + 11.0 * s), bvr_tag, HORIZONTAL_ALIGNMENT_CENTER, bvr_sz, tag_sz, bvr_col)
		else:
			# Small corner brackets (visual range)
			var b_sz: float = 20.0 * s
			var c_len: float = 6.0 * s
			var x0: float = o_sp.x - b_sz * 0.5
			var y0: float = o_sp.y - b_sz * 0.5
			var x1: float = o_sp.x + b_sz * 0.5
			var y1: float = o_sp.y + b_sz * 0.5

			draw_line(Vector2(x0, y0 + c_len), Vector2(x0, y0), base_col, line_w)
			draw_line(Vector2(x0, y0), Vector2(x0 + c_len, y0), base_col, line_w)
			draw_line(Vector2(x1 - c_len, y0), Vector2(x1, y0), base_col, line_w)
			draw_line(Vector2(x1, y0), Vector2(x1, y0 + c_len), base_col, line_w)
			draw_line(Vector2(x0, y1 - c_len), Vector2(x0, y1), base_col, line_w)
			draw_line(Vector2(x0, y1), Vector2(x0 + c_len, y1), base_col, line_w)
			draw_line(Vector2(x1 - c_len, y1), Vector2(x1, y1), base_col, line_w)
			draw_line(Vector2(x1, y1), Vector2(x1, y1 - c_len), base_col, line_w)

	# --------------------------------------------------------------------------
	# 11. Gun Pipper (Classic base YSFlight lead reticle)
	# --------------------------------------------------------------------------
	if cur_woc == 0 and bool(telemetry.get("has_gun_lead", false)):
		var lead_pos: Vector3 = telemetry.get("gun_lead_pos", Vector3.ZERO)
		if not camera.is_position_behind(lead_pos):
			var lead_sp: Vector2 = camera.unproject_position(lead_pos)
			if vp_rect.has_point(lead_sp):
				var r_lead: float = 14.0 * s
				draw_arc(lead_sp, r_lead, 0.0, TAU, 24, base_col, line_w)
				draw_circle(lead_sp, 2.0 * s, base_col)
				# 4 Cardinal tick marks extending outward
				draw_line(lead_sp + Vector2(0.0, -r_lead), lead_sp + Vector2(0.0, -r_lead - 4.0 * s), base_col, line_w)
				draw_line(lead_sp + Vector2(0.0, r_lead), lead_sp + Vector2(0.0, r_lead + 4.0 * s), base_col, line_w)
				draw_line(lead_sp + Vector2(-r_lead, 0.0), lead_sp + Vector2(-r_lead - 4.0 * s, 0.0), base_col, line_w)
				draw_line(lead_sp + Vector2(r_lead, 0.0), lead_sp + Vector2(r_lead + 4.0 * s, 0.0), base_col, line_w)
				# If within effective gun range (<= 1200m), show inner firing cue
				var dist_gun_m: float = player_pos.distance_to(lead_pos)
				if dist_gun_m <= 1200.0:
					draw_arc(lead_sp, 6.0 * s, 0.0, TAU, 12, base_col, line_w)

	# --------------------------------------------------------------------------
	# 11b. Bombsight Pipper (YSCE Classic Ballistics)
	# --------------------------------------------------------------------------
	var wpn_name: String = str(telemetry.get("weapon_name", "")).to_upper()
	var is_bomb: bool = (cur_woc in [3, 7, 9]) or wpn_name.begins_with("BOMB") or wpn_name.begins_with("B250") or wpn_name.begins_with("B500")
	if is_bomb or cam_mode == 9:
		var impact_pos := Vector3.ZERO
		if telemetry.has("bomb_impact_pos"):
			impact_pos = telemetry["bomb_impact_pos"]
		else:
			var vel: Vector3 = telemetry.get("velocity", Vector3.ZERO)
			var p_pos: Vector3 = player_transform.origin
			var agl: float = float(telemetry.get("agl_m", p_pos.y))
			var a: float = 0.5 * 9.80665
			var b: float = -vel.y
			var c: float = -maxf(agl, 1.0)
			var det: float = b * b - 4.0 * a * c
			if det >= 0.0:
				var t1: float = (-b + sqrt(det)) / (2.0 * a)
				var t2: float = (-b - sqrt(det)) / (2.0 * a)
				var t: float = t1 if t1 >= 0.0 else t2
				if t >= 0.0:
					var gnd_y: float = p_pos.y - agl
					impact_pos = Vector3(p_pos.x + vel.x * t, gnd_y, p_pos.z + vel.z * t)
		if impact_pos != Vector3.ZERO:
			var blast_rad: float = float(telemetry.get("bomb_blast_radius", 45.0))
			var in_range: bool = bool(telemetry.get("bomb_target_in_range", false))
			if not in_range:
				for g_k in ground_transforms.keys():
					var gd: Dictionary = ground_transforms[g_k]
					if bool(gd.get("is_alive", true)):
						var gp: Vector3 = gd.get("pos", Vector3.ZERO)
						if impact_pos.distance_to(gp) <= blast_rad:
							in_range = true
							break
			var p_col: Color = Color(1.0, 0.22, 0.22) if in_range else base_col
			if not camera.is_position_behind(impact_pos):
				var sp: Vector2 = camera.unproject_position(impact_pos)
				if vp_rect.has_point(sp):
					var r_px: float = 24.0 * s
					draw_arc(sp, r_px, 0.0, TAU, 24, p_col, line_w)
					draw_circle(sp, 2.5 * s, p_col)
					draw_line(sp - Vector2(r_px * 0.55, 0.0), sp + Vector2(r_px * 0.55, 0.0), p_col, line_w)
					draw_line(sp - Vector2(0.0, r_px * 0.55), sp + Vector2(0.0, r_px * 0.55), p_col, line_w)
					var bomb_font_sz: int = maxi(10, int(round(13.0 * s)))
					draw_string(_font, sp + Vector2(r_px + 4.0 * s, bomb_font_sz * 0.35), "BOMB", HORIZONTAL_ALIGNMENT_LEFT, -1, bomb_font_sz, p_col)
			else:
				var dist_km: float = player_transform.origin.distance_to(impact_pos) / 1000.0
				_draw_offscreen_arrow(camera, impact_pos, dist_km, vp_rect, p_col, s, line_w, maxi(9, int(round(11.0 * s))))

	# --------------------------------------------------------------------------
	# 12. Threat Warnings (Flashing 2 Hz under boresight)
	# --------------------------------------------------------------------------
	var flash_bit_warn: bool = (int(Time.get_ticks_msec() * 0.004) % 2) == 0
	var warn_y: float = half_h + 45.0 * s
	if bool(telemetry.get("is_missile_chasing", false)):
		if flash_bit_warn:
			draw_string(_font, Vector2(half_w - 50.0 * s, warn_y), "MISSILE", HORIZONTAL_ALIGNMENT_CENTER, 100.0 * s, maxi(12, int(round(20.0 * s))), Color(1.0, 0.22, 0.22))
	elif bool(telemetry.get("is_locked_by_enemy", false)):
		if flash_bit_warn:
			draw_string(_font, Vector2(half_w - 40.0 * s, warn_y), "LOCK", HORIZONTAL_ALIGNMENT_CENTER, 80.0 * s, maxi(10, int(round(16.0 * s))), Color(1.0, 0.75, 0.2))

func _draw_offscreen_arrow(
	cam: Camera3D,
	tgt_pos: Vector3,
	dist_km: float,
	vp_rect: Rect2,
	col: Color,
	s: float,
	line_w: float,
	font_sz: int,
	is_guided: bool = false
) -> void:
	var cam_tfm: Transform3D = cam.global_transform
	var local_tgt: Vector3 = cam_tfm.affine_inverse() * tgt_pos
	var dir_2d := Vector2(local_tgt.x, -local_tgt.y)
	if local_tgt.z > 0.0:
		dir_2d = -dir_2d
	if dir_2d.length_squared() < 0.001:
		dir_2d = Vector2.UP
	else:
		dir_2d = dir_2d.normalized()

	var center := vp_rect.size * 0.5
	var edge_margin: float = 55.0 * s
	var bounds_half := (vp_rect.size * 0.5) - Vector2(edge_margin, edge_margin)

	var t_x: float = absf(bounds_half.x / dir_2d.x) if absf(dir_2d.x) > 0.001 else 1e9
	var t_y: float = absf(bounds_half.y / dir_2d.y) if absf(dir_2d.y) > 0.001 else 1e9
	var t_hit: float = minf(t_x, t_y)
	var edge_pt: Vector2 = center + dir_2d * t_hit

	# 1. Clamped target box on the screen edge
	var box_sz: float = 24.0 * s
	var box_rect := Rect2(edge_pt.x - box_sz * 0.5, edge_pt.y - box_sz * 0.5, box_sz, box_sz)
	draw_rect(box_rect, col, false, line_w)

	# Lock diamond inside if guided weapon
	if is_guided:
		var d_sz: float = 7.0 * s
		draw_line(edge_pt + Vector2(0.0, -d_sz), edge_pt + Vector2(d_sz, 0.0), col, line_w)
		draw_line(edge_pt + Vector2(d_sz, 0.0), edge_pt + Vector2(0.0, d_sz), col, line_w)
		draw_line(edge_pt + Vector2(0.0, d_sz), edge_pt + Vector2(-d_sz, 0.0), col, line_w)
		draw_line(edge_pt + Vector2(-d_sz, 0.0), edge_pt + Vector2(0.0, -d_sz), col, line_w)

	# 2. Attached directional pointer pointing towards the off-screen target
	var arr_origin := edge_pt + dir_2d * (box_sz * 0.5 + 2.0 * s)
	var arr_sz: float = 10.0 * s
	var perp := Vector2(-dir_2d.y, dir_2d.x)
	var tip := arr_origin + dir_2d * arr_sz
	var base_l := arr_origin + perp * (arr_sz * 0.6)
	var base_r := arr_origin - perp * (arr_sz * 0.6)

	draw_line(tip, base_l, col, line_w)
	draw_line(base_l, base_r, col, line_w)
	draw_line(base_r, tip, col, line_w)

	# 3. Distance readout placed neatly inward from the box
	var txt := "%.1fkm" % dist_km
	var txt_offset := -dir_2d * (box_sz * 0.5 + 13.0 * s)
	var txt_pos := edge_pt + txt_offset - Vector2(30.0 * s, -4.0 * s)
	draw_string(_font, txt_pos, txt, HORIZONTAL_ALIGNMENT_CENTER, 60.0 * s, font_sz, col)
