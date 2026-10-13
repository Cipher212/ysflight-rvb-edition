extends Control

# F-16 HUD symbology mapped to the HUD glass screen area from f16hud.srf.
const GREEN := Color(0.25, 1.0, 0.3, 0.82)
const WIDTH := 1.0
const M_TO_NM := 1.0 / 1852.0
var hud: Control
var _font := ThemeDB.fallback_font
var _scale := 1.0
var _lines := PackedVector2Array()
var draw_us := 0

func _draw() -> void:
	if hud.hud_size.x <= 1.0 or hud.hud_size.y <= 1.0:
		return
	var start := Time.get_ticks_usec()
	_scale = hud.optical_scale()
	_lines.clear()
	_flight()
	_weapons()
	if not _lines.is_empty():
		draw_multiline(_lines, GREEN, maxf(1.0, WIDTH * _scale), true)
	draw_us = Time.get_ticks_usec() - start

func _line(a: Vector2, b: Vector2) -> void:
	_lines.append(a)
	_lines.append(b)

func _text_screen(p: Vector2, text: String, centered: bool = true, size_mul: float = 1.0) -> void:
	if not Geometry2D.is_point_in_polygon(p, hud.aperture): return
	var size := maxi(8, int(round(10.5 * _scale * size_mul)))
	var width := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, Vector2(p.x - width * 0.5 if centered else p.x, p.y), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, GREEN)

func _circle(p: Vector2, r: float) -> void:
	draw_arc(p, r * _scale, 0.0, TAU, 24, GREEN, maxf(1.0, WIDTH * _scale), true)

func _flight() -> void:
	var tel: Dictionary = hud.telemetry
	var hc: Vector2 = hud.hud_center
	var hs: Vector2 = hud.hud_size
	
	# 1. Top: Compass Tape positioned comfortably below the upper glass arch
	var hdg: float = float(tel.get("heading_deg", 0.0))
	var top_y: float = hud.screen_pos(0.5, 0.13).y
	var bottom_y: float = hud.screen_pos(0.5, 0.94).y
	_text_screen(Vector2(hc.x, top_y - 4.0 * _scale), "%03d" % (int(round(hdg)) % 360), true, 1.1)
	
	var px_per_hdg: float = hs.x * 0.065
	for offset in range(-4, 5):
		var degree := floorf(hdg) + offset
		var tx: float = hc.x + (degree - hdg) * px_per_hdg
		if absf(tx - hc.x) <= hs.x * 0.35:
			var t_len: float = 5.0 * _scale if int(degree) % 5 == 0 else 3.0 * _scale
			_line(Vector2(tx, top_y), Vector2(tx, top_y + t_len))
	# Heading index caret (^) pointing up at the tape
	_line(Vector2(hc.x - 3.5 * _scale, top_y + 8.0 * _scale), Vector2(hc.x, top_y + 3.0 * _scale))
	_line(Vector2(hc.x + 3.5 * _scale, top_y + 8.0 * _scale), Vector2(hc.x, top_y + 3.0 * _scale))

	# 2. Left Flight Data: Airspeed, Mach, G
	var lx: float = hud.screen_pos(0.14, 0.0).x
	_text_screen(Vector2(lx, hud.screen_pos(0.0, 0.32).y), "%03d" % int(round(float(tel.get("ias_kt", 0.0)))), false, 1.1)
	_text_screen(Vector2(lx, hud.screen_pos(0.0, 0.39).y), "IAS", false, 0.9)
	_text_screen(Vector2(lx, hud.screen_pos(0.0, 0.54).y), "M%.2f" % float(tel.get("mach", 0.0)), false, 0.95)
	_text_screen(Vector2(lx, hud.screen_pos(0.0, 0.62).y), "%+.1fG" % float(tel.get("g_force", 1.0)), false, 0.95)

	# 3. Right Flight Data: Altitude, AGL, VSI
	var rx: float = hud.screen_pos(0.86, 0.0).x
	_text_screen(Vector2(rx - 25.0 * _scale, hud.screen_pos(0.0, 0.32).y), "%d" % int(round(float(tel.get("altitude_ft", 0.0)))), false, 1.1)
	_text_screen(Vector2(rx - 15.0 * _scale, hud.screen_pos(0.0, 0.39).y), "FT", false, 0.9)
	_text_screen(Vector2(rx - 30.0 * _scale, hud.screen_pos(0.0, 0.54).y), "R%d" % int(round(float(tel.get("agl_m", 0.0)) * 3.28084)), false, 0.95)
	_text_screen(Vector2(rx - 30.0 * _scale, hud.screen_pos(0.0, 0.62).y), "%+.0f" % float(tel.get("vsi_fpm", 0.0)), false, 0.95)

	# 4. Center: Boresight Reference Cross (Waterline)
	var b_sp: Vector2 = hud.project_direction(-hud.aircraft.basis.z)
	if b_sp.x > -50000.0:
		_line(b_sp - Vector2(10.0, 0.0) * _scale, b_sp - Vector2(3.0, 0.0) * _scale)
		_line(b_sp + Vector2(3.0, 0.0) * _scale, b_sp + Vector2(10.0, 0.0) * _scale)
		_line(b_sp - Vector2(0.0, 10.0) * _scale, b_sp - Vector2(0.0, 3.0) * _scale)
		_line(b_sp + Vector2(0.0, 3.0) * _scale, b_sp + Vector2(0.0, 10.0) * _scale)
		draw_circle(b_sp, maxf(1.0, 1.5 * _scale), GREEN)

	# 5. Flight Path Marker (Velocity Vector)
	var cam_fwd: Vector3 = -hud.camera.global_transform.basis.z
	var cam_up: Vector3 = hud.camera.global_transform.basis.y
	var cam_right: Vector3 = hud.camera.global_transform.basis.x
	var cam_pitch_deg: float = rad_to_deg(asin(clampf(cam_fwd.y, -1.0, 1.0)))
	var up_screen := Vector2(cam_right.y, -cam_up.y)
	var theta_roll: float = atan2(up_screen.x, -up_screen.y)
	var ladder_up := Vector2(sin(theta_roll), -cos(theta_roll))
	var ladder_right := Vector2(cos(theta_roll), sin(theta_roll))

	var vel_raw: Vector3 = tel.get("velocity", Vector3.ZERO)
	var vel_speed: float = vel_raw.length()
	# In flight, use the true aerodynamic velocity vector (matching flight course and rocket trajectory).
	# When stopped or taxiing at very low speed, park at aircraft boresight.
	var fpm_dir: Vector3 = vel_raw.normalized() if vel_speed >= 10.0 else -hud.aircraft.basis.z
	var fpm_p: Vector2 = hud.project_direction(fpm_dir)
	var has_fpm: bool = (fpm_p.x > -50000.0)
	var caged_fpm := false
	var draw_fpm_p := fpm_p

	if has_fpm:
		if not Geometry2D.is_point_in_polygon(fpm_p, hud.aperture):
			caged_fpm = true
			var ray: Vector2 = (fpm_p - hc).normalized()
			var n: int = hud.aperture.size()
			for i in range(n):
				var p1: Vector2 = hud.aperture[i]
				var p2: Vector2 = hud.aperture[(i + 1) % n]
				var hit = Geometry2D.segment_intersects_segment(hc, hc + ray * 5000.0, p1, p2)
				if hit != null:
					draw_fpm_p = (hit as Vector2) - ray * (8.0 * _scale)
					break
		_circle(draw_fpm_p, 4.5)
		_line(draw_fpm_p - ladder_right * (10.0 * _scale), draw_fpm_p - ladder_right * (4.5 * _scale))
		_line(draw_fpm_p + ladder_right * (4.5 * _scale), draw_fpm_p + ladder_right * (10.0 * _scale))
		_line(draw_fpm_p + ladder_up * (4.5 * _scale), draw_fpm_p + ladder_up * (9.0 * _scale))
		if caged_fpm:
			var cx := 2.5 * _scale
			_line(draw_fpm_p - Vector2(cx, cx), draw_fpm_p + Vector2(cx, cx))
			_line(draw_fpm_p + Vector2(-cx, cx), draw_fpm_p + Vector2(cx, -cx))

	# 6. Pitch Ladder (Conformal to World Horizon, windowed between compass tape and bottom status)
	var focal_len: float = hud.focal_length()
	var ladder_center: Vector2 = b_sp if b_sp.x > -50000.0 else hud.optical_center()
	var ladder_min_y: float = top_y + 14.0 * _scale
	var ladder_max_y: float = bottom_y - 26.0 * _scale

	var start := int(floor(cam_pitch_deg / 5.0)) * 5
	for pitch in range(start - 15, start + 16, 5):
		if pitch < -85 or pitch > 85: continue
		var delta_p: float = float(pitch) - cam_pitch_deg
		if absf(delta_p) > 20.0: continue
		var d_px: float = focal_len * tan(deg_to_rad(delta_p))
		var rung_ctr: Vector2 = ladder_center + ladder_up * d_px
		if rung_ctr.y < ladder_min_y or rung_ctr.y > ladder_max_y:
			continue
		
		for side: float in [-1.0, 1.0]:
			var arm_len: float = (35.0 if pitch == 0 else 20.0) * _scale
			var gap: float = 12.0 * _scale
			var p_inner: Vector2 = rung_ctr + ladder_right * (gap * side)
			var p_outer: Vector2 = rung_ctr + ladder_right * ((gap + arm_len) * side)
			if pitch < 0:
				# Dashed negative rungs
				var step: Vector2 = (p_outer - p_inner) / 3.0
				_line(p_inner, p_inner + step * 0.6)
				_line(p_inner + step * 1.2, p_inner + step * 1.8)
				_line(p_inner + step * 2.4, p_outer)
			else:
				_line(p_inner, p_outer)
			if pitch != 0:
				var tick_dir: Vector2 = -ladder_up * (signf(pitch) * 4.0 * _scale)
				_line(p_outer, p_outer + tick_dir)
				_text_screen(p_outer + ladder_right * (7.0 * side * _scale) - ladder_up * 3.0, str(absi(pitch)), true, 0.8)


func _dashed_circle(p: Vector2, r: float, segments: int = 12) -> void:
	if not Geometry2D.is_point_in_polygon(p, hud.aperture): return
	var step := TAU / float(segments)
	for i in range(segments):
		var a0 := float(i) * step
		draw_arc(p, r * _scale, a0, a0 + step * 0.55, 3, GREEN, maxf(1.0, WIDTH * _scale), true)

func _weapons() -> void:
	var tel: Dictionary = hud.telemetry
	var wtype := int(tel.get("weapon_type", -1))
	var weapon := str(tel.get("weapon_name", "NONE"))
	var count := int(tel.get("ammo_count", 0))
	var gun_ammo := int(tel.get("gun_ammo", 0))
	var flares := int(tel.get("flare_count", 0))
	var hc: Vector2 = hud.hud_center
	var bottom_y: float = hud.screen_pos(0.5, 0.97).y

	# Bottom weapon bar: Always-on Gun (left), Selected Weapon (center), Flares (right)
	_text_screen(Vector2(hud.screen_pos(0.24, 0.97).x, bottom_y), "G:%d" % gun_ammo, true, 0.9)
	_text_screen(Vector2(hc.x, bottom_y), "%s %d" % [weapon, count], true, 1.05)
	_text_screen(Vector2(hud.screen_pos(0.76, 0.97).x, bottom_y), "F:%d" % flares, true, 0.9)

	var missile_chasing := bool(tel.get("is_missile_chasing", false))
	var locked_by_enemy := bool(tel.get("is_locked_by_enemy", false))
	var warning := ""
	if missile_chasing:
		var flash_on := (int(Time.get_ticks_msec() / 100) % 2) == 0
		warning = "!! MISSILE !!" if flash_on else "MISSILE"
	elif locked_by_enemy:
		warning = "SPIKE / LOCK"
	elif float(tel.get("fuel_pct", 100.0)) <= 15.0:
		warning = "BINGO FUEL"
	if not warning.is_empty():
		_text_screen(Vector2(hc.x, bottom_y - 14.0 * _scale), warning, true, 1.05)

	var has_target: bool = not hud.target.is_empty() and bool(hud.target.get("is_alive", true))
	var range_limit: float = float(tel.get("agm_range", 0.0)) if wtype == 2 else float(tel.get("aam_range", 0.0))

	# Un-locked Missile Seeker Acquisition Circle around boresight
	if not has_target and wtype in [1, 2, 6, 10] and count > 0:
		var b_sp: Vector2 = hud.project_direction(-hud.aircraft.basis.z)
		if b_sp.x > -50000.0:
			_dashed_circle(b_sp, 24.0 if wtype == 6 else 18.0, 12)

	# Target Box, Steering Arrow & Dynamic Launch Zone (DLZ) Scale
	if has_target:
		var pos: Vector3 = hud.target.get("pos", Vector3.ZERO)
		var distance: float = hud.aircraft.origin.distance_to(pos)
		var in_wez: bool = range_limit > 0.0 and count > 0 and distance <= range_limit

		if range_limit > 0.0:
			_draw_dlz(distance, range_limit, in_wez)

		if not hud.camera.is_position_behind(pos):
			var p: Vector2 = hud.camera.unproject_position(pos)
			if not Geometry2D.is_point_in_polygon(p, hud.aperture):
				var arrow: Vector2 = hud.screen_pos(0.5, 0.65)
				var direction: Vector2 = (p - hc).normalized()
				var side := direction.orthogonal()
				_line(arrow - direction * 5.0 * _scale, arrow + direction * 5.0 * _scale)
				_line(arrow + direction * 5.0 * _scale, arrow + (-direction * 1.0 + side * 4.0) * _scale)
				_line(arrow + direction * 5.0 * _scale, arrow + (-direction * 1.0 - side * 4.0) * _scale)
				_text_screen(arrow + Vector2(0.0, 12.0 * _scale), "%.1fNM" % (distance * M_TO_NM), true, 0.8)
			else:
				var radius := 8.0 * _scale
				draw_rect(Rect2(p - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), GREEN, false, maxf(1.0, WIDTH * _scale))
				if in_wez:
					_circle(p, 5.5)
					_text_screen(p - Vector2(0.0, radius + 5.0 * _scale), "SHOOT", true, 0.9)
				_text_screen(p + Vector2(0, radius + 10.0 * _scale), "%.1fNM" % (distance * M_TO_NM), true, 0.85)
		else:
			_text_screen(Vector2(hc.x, bottom_y - 26.0 * _scale), "TGT AFT %.1fNM" % (distance * M_TO_NM), true, 0.9)

	# Gun Pipper (Classic lead reticle matching default HUD)
	if wtype == 0 and bool(tel.get("has_gun_lead", false)):
		_gun_pipper(tel.get("gun_lead_pos", Vector3.ZERO))

	# Bombsight Pipper (YSCE Ballistics reticle matching default HUD)
	if bool(tel.get("cockpit_bomb_impact_valid", false)):
		_bomb_pipper(tel.get("cockpit_bomb_impact_pos", Vector3.ZERO))

func _draw_dlz(distance: float, range_limit: float, in_wez: bool) -> void:
	# DLZ (Dynamic Launch Zone) vertical scale on inner-right side of the combiner glass
	var dlz_x: float = hud.screen_pos(0.69, 0.0).x
	var y_top: float = hud.screen_pos(0.0, 0.40).y
	var y_bot: float = hud.screen_pos(0.0, 0.56).y
	if not Geometry2D.is_point_in_polygon(Vector2(dlz_x, (y_top + y_bot) * 0.5), hud.aperture):
		return
	var h: float = y_bot - y_top
	var tick_w: float = 5.0 * _scale

	# Main vertical scale bar (0 to 1.25 * Rmax, with Rmax at 80% height and NEZ at 40% height)
	var y_rmax: float = y_bot - h * 0.80
	var y_nez: float = y_bot - h * 0.40
	_line(Vector2(dlz_x, y_top), Vector2(dlz_x, y_bot))
	_line(Vector2(dlz_x - tick_w, y_rmax), Vector2(dlz_x, y_rmax))
	_line(Vector2(dlz_x - tick_w, y_bot), Vector2(dlz_x, y_bot))
	# No-Escape Zone (NEZ) bracket
	_line(Vector2(dlz_x - tick_w * 0.7, y_nez), Vector2(dlz_x, y_nez))
	_line(Vector2(dlz_x - tick_w * 0.7, y_nez), Vector2(dlz_x - tick_w * 0.7, y_bot))

	# Target range caret (<) sliding along DLZ
	var frac: float = clampf(distance / (range_limit * 1.25), 0.0, 1.0)
	var caret_y: float = y_bot - h * frac
	var cw: float = 5.5 * _scale
	_line(Vector2(dlz_x + 1.0 * _scale, caret_y), Vector2(dlz_x + cw, caret_y - 3.5 * _scale))
	_line(Vector2(dlz_x + 1.0 * _scale, caret_y), Vector2(dlz_x + cw, caret_y + 3.5 * _scale))
	if in_wez:
		_text_screen(Vector2(dlz_x, y_bot + 10.0 * _scale), "IN RNG", true, 0.75)


func _gun_pipper(pos: Vector3) -> void:
	if hud.camera.is_position_behind(pos): return
	var p: Vector2 = hud.camera.unproject_position(pos)
	if not Geometry2D.is_point_in_polygon(p, hud.aperture): return
	var r: float = 8.0 * _scale
	_circle(p, r)
	draw_circle(p, maxf(1.0, 1.5 * _scale), GREEN)
	# 4 cardinal ticks
	_line(p + Vector2(0.0, -r), p + Vector2(0.0, -r - 3.5 * _scale))
	_line(p + Vector2(0.0, r), p + Vector2(0.0, r + 3.5 * _scale))
	_line(p + Vector2(-r, 0.0), p + Vector2(-r - 3.5 * _scale, 0.0))
	_line(p + Vector2(r, 0.0), p + Vector2(r + 3.5 * _scale, 0.0))
	var dist: float = hud.aircraft.origin.distance_to(pos)
	if dist <= 1200.0:
		_circle(p, 4.0 * _scale)

func _bomb_pipper(pos: Vector3) -> void:
	if hud.camera.is_position_behind(pos): return
	var p: Vector2 = hud.camera.unproject_position(pos)
	if not Geometry2D.is_point_in_polygon(p, hud.aperture): return
	var r: float = 12.0 * _scale
	_circle(p, r)
	draw_circle(p, maxf(1.0, 1.5 * _scale), GREEN)
	_line(p - Vector2(r * 0.55, 0.0), p + Vector2(r * 0.55, 0.0))
	_line(p - Vector2(0.0, r * 0.55), p + Vector2(0.0, r * 0.55))
	_text_screen(p + Vector2(r + 14.0 * _scale, 3.5 * _scale), "BOMB", false, 0.85)
