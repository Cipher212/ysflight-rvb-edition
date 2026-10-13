extends Control

# Left MFD (Aircraft Systems, Defenses & Complete SMS) is 0..256.
# Right MFD (Tactical Radar, WEZ, RWR & Navigation Scope) is 256..512.
const BG_COLOR := Color(0.012, 0.04, 0.012)
const GREEN := Color(0.22, 1.0, 0.08)
const DIM_GREEN := Color(0.14, 0.55, 0.06)
const AMBER := Color(1.0, 0.75, 0.2)
const RED := Color(1.0, 0.18, 0.18)
const CYAN := Color(0.3, 0.85, 1.0)
const FONT_SIZE := 17
const FONT_SMALL := 13
const FONT_TINY := 11
const CELL := 256.0
const NM_TO_M := 1852.0
const M_TO_FT := 3.28084
const FONT := preload("res://ui/fonts/ACES07_Regular.ttf")

var values: Dictionary = {}
var redraw_count := 0
var tgt_pos := Vector3.ZERO
var player_tfm := Transform3D.IDENTITY

func set_telemetry(
	tel: Dictionary,
	tfm: Transform3D,
	target: Dictionary,
	radar_data: Dictionary = {},
	filter_mode: int = 0,
	towers: PackedVector3Array = PackedVector3Array()
) -> bool:
	player_tfm = tfm
	tgt_pos = target.get("pos", Vector3.ZERO)
	var next := display_values(tel, target, radar_data, filter_mode, towers)
	if next == values:
		return false
	values = next
	redraw_count += 1
	queue_redraw()
	return true

func display_values(
	tel: Dictionary,
	target: Dictionary,
	radar_data: Dictionary,
	filter_mode: int,
	towers: PackedVector3Array
) -> Dictionary:
	var vel: Vector3 = tel.get("velocity", Vector3.ZERO)
	var aoa := 0.0
	if vel.length_squared() > 1.0:
		var local_v: Vector3 = player_tfm.basis.transposed() * vel
		aoa = -rad_to_deg(atan2(local_v.y, -local_v.z))

	var hdg: float = float(tel.get("heading_deg", 0.0))
	var player_iff: int = int(tel.get("iff", 0))
	var radar_range_m: float = float(tel.get("radar_range", 0.0))
	var radar_range_nm: float = float(tel.get("radar_range_nm", 0.0))
	if radar_range_m <= 0.0:
		radar_range_nm = 10.0
		radar_range_m = 10.0 * NM_TO_M

	var wtype: int = int(tel.get("weapon_type", -1))
	var wez_m: float = float(tel.get("agm_range", 0.0)) if wtype == 2 else float(tel.get("aam_range", 0.0))
	if wez_m <= 0.0:
		match wtype:
			0: wez_m = 1500.0
			4: wez_m = 3000.0
			3, 7, 9: wez_m = 2000.0

	var contacts: PackedFloat32Array = radar_data.get("contacts", PackedFloat32Array())
	var ground: PackedFloat32Array = radar_data.get("ground", PackedFloat32Array())
	var missiles: PackedFloat32Array = radar_data.get("missiles", PackedFloat32Array())

	# Count friendly vs enemy radar contacts and extract locked contact fallback
	var friendly_air := 1 if bool(tel.get("is_alive", true)) else 0
	var enemy_air := 0
	var locked_contact_aspect := "TRK"
	var locked_contact_dist_nm := -1.0
	var locked_contact_alt_ft := 0
	var ci := 0
	while ci < contacts.size():
		var c_right: float = contacts[ci + 1]
		var c_fwd: float = contacts[ci + 2]
		var c_alt: float = contacts[ci + 3]
		var c_rel_hdg: float = contacts[ci + 4]
		var c_iff: int = int(contacts[ci + 5])
		var c_locked: bool = contacts[ci + 6] >= 0.5
		ci += 8
		if c_iff == player_iff:
			friendly_air += 1
		else:
			enemy_air += 1
		if c_locked:
			locked_contact_dist_nm = Vector2(c_right, c_fwd).length() / NM_TO_M
			locked_contact_alt_ft = roundi((float(tel.get("altitude_m", 0.0)) + c_alt) * M_TO_FT / 100.0) * 100
			var abs_rel := absf(wrapf(c_rel_hdg, -PI, PI))
			locked_contact_aspect = "HOT" if abs_rel > 2.0 else ("CLD" if abs_rel < 1.1 else "FLK")

	# Nearest friendly base / tower (HOME) in player horizontal frame
	var home_valid := false
	var home_right := 0.0
	var home_fwd := 0.0
	var best_d2 := 1e18
	var gi := 0
	while gi < ground.size():
		var gr: float = ground[gi + 1]
		var gf: float = ground[gi + 2]
		var giff: int = int(ground[gi + 4])
		gi += 6
		if giff == player_iff:
			var d2 := gr * gr + gf * gf
			if d2 < best_d2:
				best_d2 = d2
				home_right = gr
				home_fwd = gf
				home_valid = true
	if not home_valid and not towers.is_empty():
		var fwd_3d := Vector3(-player_tfm.basis.z.x, 0.0, -player_tfm.basis.z.z)
		if fwd_3d.length_squared() < 1e-4:
			fwd_3d = Vector3(0.0, 0.0, -1.0)
		else:
			fwd_3d = fwd_3d.normalized()
		var right_3d := Vector3(-fwd_3d.z, 0.0, fwd_3d.x)
		for t_pos: Vector3 in towers:
			var diff := t_pos - player_tfm.origin
			var d2 := diff.x * diff.x + diff.z * diff.z
			if d2 < best_d2:
				best_d2 = d2
				home_right = diff.dot(right_3d)
				home_fwd = diff.dot(fwd_3d)
				home_valid = true

	var home_dist_nm := roundi(sqrt(best_d2) / NM_TO_M) if home_valid else 0
	var home_brg := posmod(roundi(hdg + rad_to_deg(atan2(home_right, home_fwd))), 360) if home_valid else 0

	var tgt_valid: bool = not target.is_empty() or locked_contact_dist_nm >= 0.0
	var tgt_dist_nm: float = (player_tfm.origin.distance_to(tgt_pos) / NM_TO_M) if not target.is_empty() else maxf(0.0, locked_contact_dist_nm)
	var tgt_alt_ft: int = (roundi((tgt_pos.y) * M_TO_FT / 100.0) * 100) if not target.is_empty() else locked_contact_alt_ft
	var tgt_aspect := locked_contact_aspect
	if not target.is_empty() and target.has("basis"):
		var t_basis: Basis = target["basis"]
		var t_fwd: Vector3 = -t_basis.z
		var to_player: Vector3 = (player_tfm.origin - tgt_pos).normalized()
		var dot_aspect: float = t_fwd.dot(to_player)
		tgt_aspect = "HOT" if dot_aspect > 0.5 else ("CLD" if dot_aspect < -0.5 else "FLK")

	return {
		"fuel": clampi(roundi(float(tel.get("fuel_pct", 0.0))), 0, 100),
		"health": clampi(roundi(float(tel.get("health_pct", 0.0))), 0, 100),
		"thr": clampi(roundi(float(tel.get("throttle", 0.0)) * 100.0), 0, 100),
		"ab": bool(tel.get("afterburner", false)),
		"gear": int(tel.get("gear", 0)),
		"flaps": clampi(roundi(float(tel.get("flaps", 0.0)) * (100.0 if float(tel.get("flaps", 0.0)) <= 1.0 else 1.0)), 0, 100),
		"brake": bool(tel.get("brake", false)),
		"spoiler": clampi(roundi(float(tel.get("spoiler", 0.0)) * 100.0), 0, 100),
		"wtype": wtype,
		"aim120": int(tel.get("aim120_count", 0)),
		"aim9": int(tel.get("aim9_count", 0)) + int(tel.get("aim9x_count", 0)),
		"aam": int(tel.get("aim9_count", 0)) + int(tel.get("aim9x_count", 0)) + int(tel.get("aim120_count", 0)),
		"agm": int(tel.get("agm65_count", 0)),
		"bomb": int(tel.get("bomb_count", 0)),
		"rocket": int(tel.get("rocket_count", 0)),
		"gun": int(tel.get("gun_ammo", 0)),
		"flare": int(tel.get("flare_count", 0)),
		"selected": str(tel.get("weapon_name", "NONE")),
		"lock": bool(tel.get("is_locked_by_enemy", false)),
		"missile": bool(tel.get("is_missile_chasing", false)),
		"heading": posmod(roundi(hdg), 360),
		"tas": roundi(float(tel.get("speed_kt", 0.0))),
		"ias": roundi(float(tel.get("ias_kt", 0.0))),
		"alt": roundi(float(tel.get("altitude_ft", 0.0)) / 10.0) * 10,
		"g": snappedf(float(tel.get("g_force", 1.0)), 0.1),
		"aoa": snappedf(clampf(aoa, -20.0, 45.0), 0.1),
		"player_iff": player_iff,
		"radar_range_m": roundi(radar_range_m),
		"radar_range_nm": snappedf(radar_range_nm, 0.5),
		"filter_mode": filter_mode,
		"wez_m": roundi(wez_m),
		"contacts": contacts,
		"ground": ground,
		"missiles": missiles,
		"friendly_air": friendly_air,
		"enemy_air": enemy_air,
		"home_valid": home_valid,
		"home_right": roundi(home_right),
		"home_fwd": roundi(home_fwd),
		"home_dist_nm": home_dist_nm,
		"home_brg": home_brg,
		"tgt_valid": tgt_valid,
		"tgt_name": str(target.get("name", "LOCK")),
		"tgt_dist": roundi(tgt_dist_nm),
		"tgt_dist_nm": snappedf(tgt_dist_nm, 0.1),
		"tgt_alt_ft": tgt_alt_ft,
		"tgt_aspect": tgt_aspect
	}

func _draw() -> void:
	draw_rect(Rect2(0, 0, CELL * 2, CELL), BG_COLOR)
	if values.is_empty():
		return
	_draw_left_mfd(0.0)
	_draw_right_mfd(CELL)

func _draw_left_mfd(x: float) -> void:
	# 1. Top: Engine & Fuel with exact numeric percentages and Bingo color coding
	_line(x + 10, 22, "THR", GREEN, FONT_SMALL)
	draw_rect(Rect2(x + 48, 12, 142, 11), GREEN, false, 1.5)
	var thr_fill := 142.0 * (float(values.thr) / 100.0)
	draw_rect(Rect2(x + 48, 12, minf(thr_fill, 106.5), 11), GREEN)
	if values.ab:
		draw_rect(Rect2(x + 48 + 106.5, 12, maxf(0.0, thr_fill - 106.5), 11), RED)
		_line(x + 196, 22, "AB", RED, FONT_SMALL)
	else:
		_line(x + 196, 22, "%3d%%" % values.thr, GREEN, FONT_SMALL)

	var col_fuel: Color = GREEN if values.fuel > 25 else (RED if values.fuel <= 15 else AMBER)
	_line(x + 10, 40, "FUEL", col_fuel, FONT_SMALL)
	draw_rect(Rect2(x + 48, 30, 142, 11), col_fuel, false, 1.5)
	draw_rect(Rect2(x + 48, 30, 142.0 * (float(values.fuel) / 100.0), 11), col_fuel)
	_line(x + 196, 40, "%3d%%" % values.fuel, col_fuel, FONT_SMALL)

	draw_line(Vector2(x + 8, 48), Vector2(x + 248, 48), DIM_GREEN, 1.0)

	# 2. Middle Left: Airframe Configuration (Gear, Flaps %, Speedbrake vs Wheel Brake)
	var my := 66.0
	_line(x + 10, my, "GEAR", GREEN, FONT_SMALL)
	if values.gear > 0:
		draw_circle(Vector2(x + 64, my - 6), 3.5, GREEN)
		draw_circle(Vector2(x + 57, my + 2), 3.5, GREEN)
		draw_circle(Vector2(x + 71, my + 2), 3.5, GREEN)
		_line(x + 80, my, "DN", GREEN, FONT_SMALL)
	else:
		_line(x + 56, my, "UP", GREEN, FONT_SMALL)

	_line(x + 10, my + 24, "FLAP", GREEN, FONT_SMALL)
	if values.flaps > 0:
		draw_line(Vector2(x + 56, my + 17), Vector2(x + 72, my + 25), AMBER, 2.0)
		_line(x + 78, my + 24, "%d%%" % values.flaps, AMBER, FONT_SMALL)
	else:
		draw_line(Vector2(x + 56, my + 19), Vector2(x + 74, my + 19), GREEN, 2.0)
		_line(x + 80, my + 24, "UP", GREEN, FONT_SMALL)

	_line(x + 10, my + 48, "BRK", GREEN, FONT_SMALL)
	if values.spoiler > 5 and values.brake:
		_line(x + 56, my + 48, "SPD+WHL", AMBER, FONT_SMALL)
	elif values.spoiler > 5:
		_line(x + 56, my + 48, "SPD %d%%" % values.spoiler, AMBER, FONT_SMALL)
	elif values.brake:
		_line(x + 56, my + 48, "WHL ON", AMBER, FONT_SMALL)
	else:
		_line(x + 56, my + 48, "OFF", GREEN, FONT_SMALL)

	# 3. Middle Right: Airframe Health, Gun Rounds, Flare Count
	var col_hp: Color = GREEN if values.health > 40 else (RED if values.health < 20 else AMBER)
	_line(x + 132, my, "HP  %3d%%" % values.health, col_hp, FONT_SIZE)

	var col_gun: Color = RED if values.gun <= 0 else (AMBER if values.gun < 150 else GREEN)
	if values.wtype == 0:
		draw_rect(Rect2(x + 129, my + 10, 118, 18), GREEN, false, 1.5)
	_line(x + 132, my + 24, "GUN %4d" % values.gun, col_gun, FONT_SIZE)

	var col_flr: Color = RED if values.flare <= 0 else (AMBER if values.flare <= 6 else GREEN)
	_line(x + 132, my + 48, "FLR %4d" % values.flare, col_flr, FONT_SIZE)

	# 4. Bottom: Complete 5-Station Stores Management System (SMS)
	draw_line(Vector2(x + 8, 126), Vector2(x + 248, 126), GREEN, 1.5)
	_line(x + 10, 141, "STORES", GREEN, FONT_SMALL)
	_line(x + 84, 141, "SEL: " + values.selected, GREEN, FONT_SMALL)

	var sx := x + 10.0
	var sy := 163.0
	_store_item(sx, sy, "120", values.aim120, values.wtype == 6)
	_store_item(sx + 48, sy, "AIM9", values.aim9, values.wtype == 1 or values.wtype == 10)
	_store_item(sx + 96, sy, "AGM", values.agm, values.wtype == 2)
	_store_item(sx + 144, sy, "BMB", values.bomb, values.wtype in [3, 7, 9])
	_store_item(sx + 192, sy, "RKT", values.rocket, values.wtype == 4)

	var wez_nm: float = float(values.wez_m) / NM_TO_M
	if wez_nm > 0.0:
		_line(x + 10, 210, "WEZ %.1f NM" % wez_nm, GREEN, FONT_SMALL)
	if values.fuel <= 15:
		_line(x + 148, 210, "BINGO FUEL", RED, FONT_SMALL)

func _store_item(x: float, y: float, label: String, count: int, selected: bool) -> void:
	var box := Rect2(x - 2, y - 15, 44, 44)
	if selected:
		var fill_col: Color = RED if count <= 0 else GREEN
		draw_rect(box, fill_col)
		_line(x + 2, y - 2, label, Color.BLACK, FONT_TINY)
		_line(x + (6 if count >= 10 else 12), y + 20, str(count), Color.BLACK, 19)
	else:
		var col: Color = DIM_GREEN if count <= 0 else GREEN
		draw_rect(box, col, false, 1.0)
		_line(x + 2, y - 2, label, col, FONT_TINY)
		_line(x + (6 if count >= 10 else 12), y + 20, str(count), col, 19)

func _draw_right_mfd(x: float) -> void:
	var cx := x + 128.0
	var cy := 104.0
	var radius := 74.0
	var centre := Vector2(cx, cy)
	var range_m: float = maxf(1.0, float(values.radar_range_m))
	var range_scale: float = radius / range_m
	var rad_sq: float = radius * radius

	# 1. Scope Background, Rings & Forward 120-deg Radar Gimbal Cone
	draw_circle(centre, radius, Color(0.2, 1.0, 0.1, 0.05))
	var cone_rad := deg_to_rad(60.0)
	var left_cone := Vector2(cos(-PI * 0.5 - cone_rad), sin(-PI * 0.5 - cone_rad))
	var right_cone := Vector2(cos(-PI * 0.5 + cone_rad), sin(-PI * 0.5 + cone_rad))
	draw_line(centre, centre + left_cone * radius, Color(0.22, 1.0, 0.08, 0.28), 1.0)
	draw_line(centre, centre + right_cone * radius, Color(0.22, 1.0, 0.08, 0.28), 1.0)

	draw_arc(centre, radius, 0.0, TAU, 40, GREEN, 1.2)
	draw_arc(centre, radius * 0.5, 0.0, TAU, 28, DIM_GREEN, 1.0)
	draw_line(Vector2(cx - radius, cy), Vector2(cx + radius, cy), Color(0.2, 1.0, 0.1, 0.2), 1.0)
	draw_line(Vector2(cx, cy - radius), Vector2(cx, cy + radius), Color(0.2, 1.0, 0.1, 0.2), 1.0)

	# 2. Dashed WEZ Ring for active weapon
	var wez_r: float = float(values.wez_m) * range_scale
	if wez_r > 6.0 and wez_r < radius:
		var steps := 16
		var step_a := TAU / float(steps)
		for d in range(steps):
			var a0 := float(d) * step_a
			draw_arc(centre, wez_r, a0, a0 + step_a * 0.5, 4, Color(0.22, 1.0, 0.08, 0.65), 1.2)

	# 3. Rotating North ("N") Marker & Home ("H") Rim Cue
	var north_rad := -PI * 0.5 - deg_to_rad(float(values.heading))
	var north_dir := Vector2(cos(north_rad), sin(north_rad))
	draw_line(centre + north_dir * (radius - 5.0), centre + north_dir * radius, GREEN, 1.5)
	_line(centre.x + north_dir.x * (radius - 12.0) - 4.0, centre.y + north_dir.y * (radius - 12.0) + 4.0, "N", GREEN, FONT_TINY)

	if values.home_valid:
		var h_vec := Vector2(float(values.home_right), -float(values.home_fwd))
		if h_vec.length_squared() > 1.0:
			var h_dir := h_vec.normalized()
			var h_pos := centre + h_dir * minf(radius - 3.0, h_vec.length() * range_scale)
			draw_rect(Rect2(h_pos.x - 3.0, h_pos.y - 3.0, 6.0, 6.0), CYAN, false, 1.2)

	# 4. Ground Contacts (Red = Enemy, Cyan = Friendly)
	var fmode: int = values.filter_mode
	var player_iff: int = values.player_iff
	if fmode == 0 or fmode == 2:
		var ground: PackedFloat32Array = values.ground
		var gi := 0
		while gi < ground.size():
			var gr: float = ground[gi + 1]
			var gf: float = ground[gi + 2]
			var giff: int = int(ground[gi + 4])
			var glocked: bool = ground[gi + 5] >= 0.5
			gi += 6
			var goff := Vector2(gr, -gf) * range_scale
			if goff.length_squared() > rad_sq:
				continue
			var gpos := centre + goff
			var gcol: Color = RED if giff != player_iff else CYAN
			var gsz: float = 6.0 if glocked else 3.5
			if glocked:
				draw_dashed_line(centre, gpos, GREEN, 1.0, 4.0)
			draw_rect(Rect2(gpos.x - gsz * 0.5, gpos.y - gsz * 0.5, gsz, gsz), gcol, false, 1.2)

	# 5. Missile Contacts & Incoming RWR Threat Bearing Lines
	var missiles: PackedFloat32Array = values.missiles
	var mi := 0
	while mi < missiles.size():
		var mr: float = missiles[mi]
		var mf: float = missiles[mi + 1]
		var mflags: int = int(missiles[mi + 3])
		mi += 5
		var is_chasing: bool = (mflags & 1) != 0
		var is_own: bool = (mflags & 2) != 0
		if not is_chasing and not is_own:
			continue
		var moff := Vector2(mr, -mf) * range_scale
		if moff.length_squared() > rad_sq:
			if is_chasing:
				moff = moff.normalized() * radius
			else:
				continue
		var mpos := centre + moff
		if is_chasing:
			draw_line(centre, mpos, RED, 1.8)
			draw_circle(mpos, 3.5, RED)
		elif is_own and fmode != 2:
			draw_circle(mpos, 2.2, GREEN)

	# 6. Air Contacts (Directional Chevrons + Altitude Tag + Lock Box)
	if fmode == 0 or fmode == 1:
		var contacts: PackedFloat32Array = values.contacts
		var ci := 0
		while ci < contacts.size():
			var cr: float = contacts[ci + 1]
			var cf: float = contacts[ci + 2]
			var calt: float = contacts[ci + 3]
			var crel_hdg: float = contacts[ci + 4]
			var ciff: int = int(contacts[ci + 5])
			var clocked: bool = contacts[ci + 6] >= 0.5
			ci += 8
			var coff := Vector2(cr, -cf) * range_scale
			if coff.length_squared() > rad_sq:
				continue
			var cpos := centre + coff
			var ccol: Color = RED if ciff != player_iff else CYAN
			if absf(calt) > 2000.0 and not clocked:
				ccol.a = 0.45
			if clocked:
				draw_dashed_line(centre, cpos, GREEN, 1.0, 4.0)
			var h_scr := -PI * 0.5 + crel_hdg
			var fwd_d := Vector2(cos(h_scr), sin(h_scr))
			var perp_d := Vector2(-fwd_d.y, fwd_d.x)
			var sz := 4.5
			draw_colored_polygon(PackedVector2Array([
				cpos + fwd_d * sz,
				cpos - fwd_d * (sz * 0.6) + perp_d * (sz * 0.65),
				cpos - fwd_d * (sz * 0.2),
				cpos - fwd_d * (sz * 0.6) - perp_d * (sz * 0.65)
			]), ccol)
			if absf(calt) > 300.0:
				_line(cpos.x + 5.0, cpos.y + 3.0, "+" if calt > 0.0 else "-", ccol, FONT_TINY)
			if clocked:
				draw_rect(Rect2(cpos.x - 6.5, cpos.y - 6.5, 13.0, 13.0), GREEN, false, 1.2)

	# Fallback locked target blip if radar_data was empty in unit test
	if values.tgt_valid and values.contacts.is_empty() and values.ground.is_empty():
		var local_pos := player_tfm.affine_inverse() * tgt_pos
		var tgt_dir := Vector2(local_pos.x, local_pos.z).normalized()
		var dist_scale := minf(1.0, player_tfm.origin.distance_to(tgt_pos) / range_m)
		var blip_pos := centre + tgt_dir * (dist_scale * radius)
		draw_dashed_line(centre, blip_pos, GREEN, 1.0, 4.0)
		draw_rect(Rect2(blip_pos.x - 4.0, blip_pos.y - 4.0, 8.0, 8.0), GREEN, false, 1.2)

	# 7. Center Aircraft Symbol
	draw_line(centre + Vector2(0.0, -5.0), centre + Vector2(0.0, 4.5), GREEN, 1.5)
	draw_line(centre + Vector2(-5.0, 0.0), centre + Vector2(5.0, 0.0), GREEN, 1.5)
	draw_line(centre + Vector2(-2.5, 3.5), centre + Vector2(2.5, 3.5), GREEN, 1.5)

	# 8. Four Corner Data Readouts (Non-redundant tactical & aero state)
	var rng_str: String = ("%dNM" % int(values.radar_range_nm)) if fmod(float(values.radar_range_nm), 1.0) == 0.0 else ("%.1fNM" % values.radar_range_nm)
	var mod_str: String = "AIR" if fmode == 1 else ("GND" if fmode == 2 else "ALL")
	_line(x + 8, 18, "RNG " + rng_str, GREEN, FONT_SMALL)
	_line(x + 8, 33, "MOD " + mod_str, AMBER if fmode != 0 else GREEN, FONT_SMALL)

	if values.tgt_valid:
		_line(x + 168, 18, values.tgt_name.left(7), GREEN, FONT_SMALL)
		_line(x + 168, 33, "%.1fNM %s" % [values.tgt_dist_nm, values.tgt_aspect], GREEN, FONT_SMALL)
		_line(x + 168, 48, "ALT %d" % values.tgt_alt_ft, GREEN, FONT_SMALL)
	else:
		_line(x + 168, 18, "NO LOCK", DIM_GREEN, FONT_SMALL)
		_line(x + 168, 33, "F:%d E:%d" % [values.friendly_air, values.enemy_air], GREEN, FONT_SMALL)

	if values.home_valid:
		_line(x + 8, 194, "HOME %dNM" % values.home_dist_nm, CYAN, FONT_SMALL)
		_line(x + 8, 209, "BRG  %03d" % values.home_brg, CYAN, FONT_SMALL)
	else:
		_line(x + 8, 194, "HDG %03d" % values.heading, GREEN, FONT_SMALL)
		_line(x + 8, 209, "%+.1f G" % values.g, GREEN, FONT_SMALL)

	_line(x + 166, 194, "AOA %+.1f" % values.aoa, AMBER if values.aoa > 15.0 else GREEN, FONT_SMALL)
	_line(x + 166, 209, "TAS %3dKT" % values.tas, GREEN, FONT_SMALL)

	# 9. RWR Threat Banner
	if values.missile or values.lock:
		var txt := "MSL LAUNCH" if values.missile else "SPIKE"
		var c := RED if values.missile else AMBER
		draw_rect(Rect2(x + 44, 160, 168, 20), c)
		_line(x + (56 if values.missile else 90), 175, txt, Color.BLACK, FONT_SIZE)

func _line(x: float, y: float, text: String, color: Color = GREEN, font_size: int = FONT_SIZE) -> void:
	draw_string(FONT, Vector2(x, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


