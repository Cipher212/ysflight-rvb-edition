extends Control
class_name HUDTargetOverlay

# ==============================================================================
# YSFlight Godot Port - Placeholder 2D Combat HUD Overlay
# ==============================================================================
# Draws 2D screen-space combat indicators over the 3D viewport:
#   - Aircraft Boresight Crosshair (+)
#   - Target Container Boxes around Bandits (Green) and Allies (White)
#   - Guided Missile Lock-On Diamond + "LOCKED" / "LOCKED [SHOOT]" indicator
#     (Only active when AIM-9, AIM-9X, AIM-120, or AGM-65 is the selected weapon,
#      matching YSFlight's FsSimulation::SimDrawContainer behavior)
#   - Gun Lead Computing Sight (Red circle + lead line when GUN is selected)
#   - Enemy Radar Lock / Incoming Missile Warning Banner
#
# NOTE FOR FUTURE LLMs:
# See `logs/hud_instructions.md` for how to replace or expand this placeholder
# overlay into a full vector HUD (`hud.tscn` / `hud.gd`).
# ==============================================================================

const WPN_GUN: int = 0
const WPN_AIM9: int = 1
const WPN_AGM65: int = 2
const WPN_AIM120: int = 6
const WPN_AIM9X: int = 10

var camera: Camera3D = null
var player_tfm: Transform3D = Transform3D.IDENTITY
var telemetry: Dictionary = {}
var airplane_transforms: Dictionary = {}
var ground_transforms: Dictionary = {}
var show_boresight: bool = true

func _ready():
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func update_overlay(
	cam: Camera3D,
	p_tfm: Transform3D,
	tel: Dictionary,
	air_tfms: Dictionary,
	gnd_tfms: Dictionary,
	draw_boresight: bool
):
	camera = cam
	player_tfm = p_tfm
	telemetry = tel
	airplane_transforms = air_tfms
	ground_transforms = gnd_tfms
	show_boresight = draw_boresight
	queue_redraw()

func _draw():
	if camera == null or telemetry.is_empty():
		return

	var vp_rect := get_viewport_rect()
	var font: Font = ThemeDB.fallback_font
	var font_size: int = 15
	var time_sec: float = float(Time.get_ticks_msec()) * 0.001
	var flash_bit: bool = (int(time_sec * 4.0) % 2) == 0

	var player_pos: Vector3 = player_tfm.origin
	var player_iff: int = int(telemetry.get("iff", 0))
	var woc: int = int(telemetry.get("weapon_type", WPN_GUN))
	var locked_air_key: int = int(telemetry.get("locked_air_target_key", -1))
	var locked_gnd_key: int = int(telemetry.get("locked_ground_target_key", -1))
	var aam_range: float = float(telemetry.get("aam_range", 5000.0))
	var agm_range: float = float(telemetry.get("agm_range", 7500.0))

	var hud_green := Color(0.25, 1.0, 0.35, 0.88)
	var hud_ally := Color(0.88, 0.94, 1.0, 0.68)
	var hud_yellow := Color(1.0, 0.92, 0.20, 0.95)
	var hud_red := Color(1.0, 0.22, 0.22, 0.98)

	# --------------------------------------------------------------------------
	# 1. Boresight Crosshair (Projected along aircraft nose -Z axis)
	# --------------------------------------------------------------------------
	if show_boresight:
		var nose_world: Vector3 = player_pos - player_tfm.basis.z * 1200.0
		if not camera.is_position_behind(nose_world):
			var sp: Vector2 = camera.unproject_position(nose_world)
			if vp_rect.has_point(sp):
				draw_line(sp + Vector2(-14, 0), sp + Vector2(-4, 0), hud_green, 1.8)
				draw_line(sp + Vector2(4, 0), sp + Vector2(14, 0), hud_green, 1.8)
				draw_line(sp + Vector2(0, -14), sp + Vector2(0, -4), hud_green, 1.8)
				draw_line(sp + Vector2(0, 4), sp + Vector2(0, 14), hud_green, 1.8)
				draw_circle(sp, 1.5, hud_green)

	# --------------------------------------------------------------------------
	# 2. Air Target Container Boxes & Guided AAM Lock-On Box
	# --------------------------------------------------------------------------
	var is_aam_selected: bool = (woc == WPN_AIM9 or woc == WPN_AIM9X or woc == WPN_AIM120)

	for air_key in airplane_transforms.keys():
		var st: Dictionary = airplane_transforms[air_key]
		if st.get("is_player", false) or not st.get("is_alive", true):
			continue

		var tgt_pos: Vector3 = st.get("pos", Vector3.ZERO)
		var dist_m: float = player_pos.distance_to(tgt_pos)
		if dist_m > 15000.0 or camera.is_position_behind(tgt_pos):
			continue

		var sp: Vector2 = camera.unproject_position(tgt_pos)
		if not vp_rect.grow(60.0).has_point(sp):
			continue

		var is_enemy: bool = (int(st.get("iff", -1)) != player_iff)
		var box_col: Color = hud_green if is_enemy else hud_ally
		var half_sz: float = 16.0
		var rect := Rect2(sp - Vector2(half_sz, half_sz), Vector2(half_sz * 2.0, half_sz * 2.0))
		draw_rect(rect, box_col, false, 1.5)

		var id_str: String = st.get("identifier", "AIR")
		var caption: String = "[%s] %.1fkm" % [id_str, dist_m / 1000.0]
		if font != null:
			draw_string(font, sp + Vector2(-half_sz, -half_sz - 6.0), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, box_col)

		# Guided AAM Lock-On Diamond + "LOCKED" / "SHOOT" message
		if is_aam_selected and int(air_key) == locked_air_key:
			var in_shoot_zone: bool = (dist_m < aam_range * 0.5)
			var lock_col: Color = (hud_red if flash_bit else hud_green) if in_shoot_zone else hud_yellow
			var d_sz: float = 24.0
			var pts := PackedVector2Array([
				sp + Vector2(0.0, -d_sz),
				sp + Vector2(d_sz, 0.0),
				sp + Vector2(0.0, d_sz),
				sp + Vector2(-d_sz, 0.0),
				sp + Vector2(0.0, -d_sz)
			])
			draw_polyline(pts, lock_col, 2.4)
			var lock_txt: String = "LOCKED [SHOOT]" if in_shoot_zone else "LOCKED"
			if font != null:
				draw_string(font, sp + Vector2(-half_sz - 8.0, half_sz + 18.0), lock_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size + 1, lock_col)

	# --------------------------------------------------------------------------
	# 3. Ground Target Designators & AGM-65 Lock-On Box
	# --------------------------------------------------------------------------
	for gnd_key in ground_transforms.keys():
		var gst: Dictionary = ground_transforms[gnd_key]
		if not gst.get("is_alive", true) or gst.get("is_non_game_object", false):
			continue
		var is_enemy_gnd: bool = (int(gst.get("iff", -1)) != player_iff)
		if not is_enemy_gnd and int(gnd_key) != locked_gnd_key:
			continue

		var g_pos: Vector3 = gst.get("pos", Vector3.ZERO)
		var g_dist: float = player_pos.distance_to(g_pos)
		if g_dist > 7500.0 or camera.is_position_behind(g_pos):
			continue

		var g_sp: Vector2 = camera.unproject_position(g_pos)
		if not vp_rect.grow(60.0).has_point(g_sp):
			continue

		if g_dist <= 5000.0:
			draw_line(g_sp + Vector2(-7, 0), g_sp + Vector2(7, 0), hud_green, 1.4)
			draw_line(g_sp + Vector2(0, -7), g_sp + Vector2(0, 7), hud_green, 1.4)

		if woc == WPN_AGM65 and int(gnd_key) == locked_gnd_key:
			var in_agm_range: bool = (g_dist < agm_range)
			var agm_col: Color = (hud_red if flash_bit else hud_green) if in_agm_range else hud_yellow
			var d_sz: float = 22.0
			var pts := PackedVector2Array([
				g_sp + Vector2(0.0, -d_sz),
				g_sp + Vector2(d_sz, 0.0),
				g_sp + Vector2(0.0, d_sz),
				g_sp + Vector2(-d_sz, 0.0),
				g_sp + Vector2(0.0, -d_sz)
			])
			draw_polyline(pts, agm_col, 2.2)
			var agm_txt: String = "LOCKED [SHOOT]" if in_agm_range else "LOCKED"
			if font != null:
				draw_string(font, g_sp + Vector2(-24.0, d_sz + 16.0), agm_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size + 1, agm_col)

	# --------------------------------------------------------------------------
	# 4. Gun Lead Computing Sight (FsSimulation::SimCalculateGunAim)
	# --------------------------------------------------------------------------
	if woc == WPN_GUN and telemetry.get("has_gun_lead", false):
		var lead_pos: Vector3 = telemetry.get("gun_lead_pos", Vector3.ZERO)
		var tgt_pos: Vector3 = telemetry.get("gun_lead_target_pos", lead_pos)
		if not camera.is_position_behind(lead_pos):
			var lead_sp: Vector2 = camera.unproject_position(lead_pos)
			if not camera.is_position_behind(tgt_pos):
				var tgt_sp: Vector2 = camera.unproject_position(tgt_pos)
				draw_line(tgt_sp, lead_sp, Color(1.0, 0.3, 0.3, 0.65), 1.4)
			draw_arc(lead_sp, 14.0, 0.0, TAU, 24, hud_red, 2.0)
			draw_circle(lead_sp, 2.2, hud_red)

	# --------------------------------------------------------------------------
	# 5. Threat Warning Banner (Incoming Missile / Radar Lock)
	# --------------------------------------------------------------------------
	if font != null:
		var is_missile_chasing: bool = telemetry.get("is_missile_chasing", false)
		var is_locked_by_enemy: bool = telemetry.get("is_locked_by_enemy", false)
		var center_x: float = vp_rect.size.x * 0.5
		if is_missile_chasing:
			var warn_col: Color = hud_red if flash_bit else hud_yellow
			var msg := "!! MISSILE ALERT — EVADE / PRESS [F] FOR FLARES !!"
			draw_string(font, Vector2(center_x - 210.0, 42.0), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, warn_col)
		elif is_locked_by_enemy:
			var msg := "! WARNING: TRACKED BY ENEMY RADAR !"
			draw_string(font, Vector2(center_x - 155.0, 42.0), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, hud_yellow)
