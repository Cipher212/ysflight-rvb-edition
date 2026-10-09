extends Control

# Left MFD (SMS) is 0 to 256. Right MFD (Tactical) is 256 to 512.
const BG_COLOR := Color(0.012, 0.04, 0.012)
const GREEN := Color(0.22, 1.0, 0.08)
const RED := Color(1.0, 0.15, 0.15)
const FONT_SIZE := 18
const FONT_SMALL := 13
const CELL := 256.0
const FONT := preload("res://ui/fonts/ACES07_Regular.ttf")

var values: Dictionary = {}
var redraw_count := 0
var tgt_pos := Vector3.ZERO
var player_tfm := Transform3D.IDENTITY

func set_telemetry(tel: Dictionary, tfm: Transform3D, target: Dictionary) -> bool:
	player_tfm = tfm
	tgt_pos = target.get("pos", Vector3.ZERO)
	var next := display_values(tel, target)
	if next == values:
		return false
	values = next
	redraw_count += 1
	queue_redraw()
	return true

func display_values(tel: Dictionary, target: Dictionary) -> Dictionary:
	var vel: Vector3 = tel.get("velocity", Vector3.ZERO)
	var aoa := 0.0
	if vel.length_squared() > 1.0:
		var local_v: Vector3 = player_tfm.basis.transposed() * vel
		aoa = -rad_to_deg(atan2(local_v.y, -local_v.z))

	return {
		"fuel": clampi(roundi(float(tel.get("fuel_pct", 0.0))), 0, 100),
		"health": clampi(roundi(float(tel.get("health_pct", 0.0))), 0, 100),
		"thr": clampi(roundi(float(tel.get("throttle", 0.0)) * 100.0), 0, 100),
		"ab": bool(tel.get("afterburner", false)),
		"gear": int(tel.get("gear", 0)),
		"flaps": int(tel.get("flaps", 0)),
		"brake": bool(tel.get("brake", false)),
		"aam": int(tel.get("aim9_count", 0)) + int(tel.get("aim9x_count", 0)) + int(tel.get("aim120_count", 0)),
		"agm": int(tel.get("agm65_count", 0)), "bomb": int(tel.get("bomb_count", 0)),
		"rocket": int(tel.get("rocket_count", 0)), "gun": int(tel.get("gun_ammo", 0)),
		"flare": int(tel.get("flare_count", 0)), "selected": str(tel.get("weapon_name", "NONE")),
		"lock": bool(tel.get("is_locked_by_enemy", false)),
		"missile": bool(tel.get("is_missile_chasing", false)),
		"heading": posmod(roundi(float(tel.get("heading_deg", 0.0))), 360),
		"tas": roundi(float(tel.get("speed_kt", 0.0))), "ias": roundi(float(tel.get("ias_kt", 0.0))),
		"alt": roundi(float(tel.get("altitude_ft", 0.0)) / 10.0) * 10,
		"g": float(tel.get("g_force", 1.0)),
		"aoa": clampf(aoa, -20.0, 45.0),
		"tgt_valid": not target.is_empty(),
		"tgt_name": str(target.get("name", "---")),
		"tgt_dist": roundi(player_tfm.origin.distance_to(tgt_pos) * 3.28084 / 6076.12) # NM
	}

func _draw() -> void:
	draw_rect(Rect2(0, 0, CELL * 2, CELL), BG_COLOR)
	if values.is_empty():
		return
	
	_draw_left_mfd(0)
	_draw_right_mfd(CELL)

func _draw_left_mfd(x: float) -> void:
	# Top: Engine & Fuel
	_line(x + 10, 24, "THR", GREEN, FONT_SMALL)
	var thr_rect = Rect2(x + 48, 14, 150, 11)
	draw_rect(thr_rect, GREEN, false, 1.5)
	var fill_width = 150.0 * (values.thr / 100.0)
	draw_rect(Rect2(x + 48, 14, minf(fill_width, 112.5), 11), GREEN)
	if values.ab:
		draw_rect(Rect2(x + 48 + 112.5, 14, fill_width - 112.5, 11), RED)
		_line(x + 206, 24, "AB", RED, FONT_SMALL)
	
	_line(x + 10, 44, "FUEL", GREEN, FONT_SMALL)
	var fuel_rect = Rect2(x + 48, 34, 180, 11)
	draw_rect(fuel_rect, GREEN, false, 1.5)
	draw_rect(Rect2(x + 48, 34, 180.0 * (values.fuel / 100.0), 11), GREEN)
	
	# Middle: Config & Percentages
	var my = 80.0
	_line(x + 10, my, "GEAR", GREEN, FONT_SMALL)
	if values.gear > 0:
		draw_circle(Vector2(x + 65, my - 5), 4, GREEN)
		draw_circle(Vector2(x + 57, my + 4), 4, GREEN)
		draw_circle(Vector2(x + 73, my + 4), 4, GREEN)
	else:
		_line(x + 58, my, "UP", GREEN, FONT_SMALL)
		
	_line(x + 10, my + 24, "FLAP", GREEN, FONT_SMALL)
	if values.flaps > 0:
		draw_line(Vector2(x + 58, my + 18), Vector2(x + 76, my + 28), GREEN, 2.5)
	else:
		draw_line(Vector2(x + 58, my + 18), Vector2(x + 76, my + 18), GREEN, 2.5)
		
	_line(x + 10, my + 48, "BRK", GREEN, FONT_SMALL)
	if values.brake:
		draw_rect(Rect2(x + 58, my + 37, 28, 13), GREEN, false, 1.5)
		_line(x + 61, my + 48, "ON", GREEN, FONT_SMALL)

	# Health & Engine Health as Percentages
	var col_hp: Color = GREEN if values.health > 40 else (RED if values.health < 20 else Color(1.0, 0.75, 0.2))
	_line(x + 130, my + 8, "HP  %3d%%" % values.health, col_hp, FONT_SIZE)
	_line(x + 130, my + 38, "ENG %3d%%" % values.health, col_hp, FONT_SIZE)

	# Bottom: Stores
	draw_line(Vector2(x + 10, 175), Vector2(x + 246, 175), GREEN, 1.5)
	_line(x + 15, 168, "STORES", GREEN, FONT_SMALL)
	_line(x + 110, 168, values.selected, GREEN, FONT_SMALL)
	
	var sx = x + 15
	var sy = 205
	_store_item(sx, sy, "A/A", values.aam, values.selected.begins_with("AIM"))
	_store_item(sx + 58, sy, "A/G", values.agm, values.selected.begins_with("AGM"))
	_store_item(sx + 116, sy, "BMB", values.bomb, values.selected.begins_with("BOMB"))
	_store_item(sx + 174, sy, "FLR", values.flare, false)

func _store_item(x: float, y: float, label: String, count: int, selected: bool) -> void:
	if selected:
		draw_rect(Rect2(x - 4, y - 16, 46, 42), GREEN)
		_line(x, y - 2, label, Color.BLACK, FONT_SMALL)
		_line(x + 8, y + 20, str(count), Color.BLACK, 22)
	else:
		_line(x, y - 2, label, GREEN, FONT_SMALL)
		_line(x + 8, y + 20, str(count), GREEN, 22)

func _draw_right_mfd(x: float) -> void:
	var cx = x + 128
	var cy = 125
	
	# Radar / TSD Background
	draw_circle(Vector2(cx, cy), 95, Color(0.2, 1.0, 0.1, 0.06))
	draw_arc(Vector2(cx, cy), 95, 0, TAU, 32, GREEN, 1.0)
	draw_arc(Vector2(cx, cy), 48, 0, TAU, 32, GREEN, 1.0)
	draw_line(Vector2(cx - 95, cy), Vector2(cx + 95, cy), Color(0.2, 1.0, 0.1, 0.25), 1.0)
	draw_line(Vector2(cx, cy - 95), Vector2(cx, cy + 95), Color(0.2, 1.0, 0.1, 0.25), 1.0)
	
	# Player symbol
	_line(cx - 5, cy + 5, "^", GREEN, 16)
	
	# Top-left Data
	_line(x + 10, 22, "HDG %03d" % values.heading, GREEN, FONT_SMALL)
	_line(x + 10, 38, "ALT %d" % values.alt, GREEN, FONT_SMALL)

	# Bottom-left: G & AoA
	_line(x + 10, 220, "%+.1f G" % values.g, GREEN, FONT_SMALL)
	_line(x + 10, 236, "AOA %+.1f" % values.aoa, GREEN, FONT_SMALL)

	# Bottom-right: TAS & IAS
	_line(x + 175, 220, "TAS %d" % values.tas, GREEN, FONT_SMALL)
	_line(x + 175, 236, "IAS %d" % values.ias, GREEN, FONT_SMALL)
	
	# Target Track Info (Top-right)
	if values.tgt_valid:
		_line(x + 175, 22, "TRK", GREEN, FONT_SMALL)
		_line(x + 175, 38, values.tgt_name.left(6), GREEN, FONT_SMALL)
		_line(x + 175, 54, "%d NM" % values.tgt_dist, GREEN, FONT_SMALL)
		
		var local_pos = player_tfm.affine_inverse() * tgt_pos
		var tgt_dir = Vector2(local_pos.x, local_pos.z).normalized()
		var dist_scale = min(1.0, (player_tfm.origin.distance_to(tgt_pos) / 20000.0))
		var blip_pos = Vector2(cx + tgt_dir.x * dist_scale * 95.0, cy + tgt_dir.y * dist_scale * 95.0)
		draw_rect(Rect2(blip_pos.x - 3, blip_pos.y - 3, 6, 6), GREEN)
		draw_line(blip_pos, blip_pos + Vector2(7, -7), GREEN, 1.0)

	# RWR Threat Banner
	if values.missile or values.lock:
		var txt = "MSL LAUNCH" if values.missile else "SPIKE"
		var c = RED if values.missile else Color(1.0, 0.85, 0.2)
		draw_rect(Rect2(x + 25, 185, 206, 26), c)
		_line(x + (50 if values.missile else 85), 204, txt, Color.BLACK, 18)

func _line(x: float, y: float, text: String, color: Color = GREEN, size: int = FONT_SIZE) -> void:
	draw_string(FONT, Vector2(x, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
