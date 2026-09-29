extends Control
class_name RadarScope

# ==============================================================================
# YSFlight Godot Port - Tactical Heading-Up Radar Scope
# ==============================================================================
# Replaces stock YSFlight's large square radar window with a compact, high-contrast,
# combat-readable circular tactical scope positioned in the lower-right corner.
#
# Key Features:
#   - Heading-Up Orientation: The player's aircraft is always centered pointing UP (forward).
#     Contacts are mapped in the player's horizontal frame (right = +X, forward = -Y on screen).
#     A dynamic North ("N") marker rotates around the outer rim (-heading).
#   - Target Classification & Colors:
#     * Enemy aircraft: Red (1.0, 0.3, 0.25)
#     * Friendly aircraft: Cyan (0.35, 0.8, 1.0)
#     * Scope reticle & text: HUD color theme (Green, Amber, Cyan, White)
#     * Ground objects: 3 px square (red outline for enemy, dim cyan for friendly)
#     * Missiles: Threat missiles (chasing player) flash red at 4 Hz with a threat axis line;
#       player-fired missiles appear as dim HUD-colored dots; other missiles are decluttered.
#   - Aspect & Altitude Cues:
#     * Chevron/triangle blips rotated by relative heading show target flight direction at a glance.
#     * Altitude difference tag (+/- above/below player) when |alt| > 300 m, with km readout > 1 km.
#     * Locked target indicated by a tracking square box.
#   - Threat Arrows:
#     * Up to 3 nearest off-screen or behind-the-camera enemy aircraft within 10 km have
#       directional red chevrons at the screen edge (inset 40 px) with distance readouts.
#   - Visibility & Filtering:
#     * Visibility rules (radar cone vs omni, range limit, alive status) are computed in C++
#       via ysflight_sim.get_radar_contacts(range_m).
#   - Performance:
#     * Single Control drawing in _draw() with zero per-frame node allocations.
#     * Measured inside HUD update budget (< 0.2 ms per frame).
# ==============================================================================

var controls: Node = null
var ysflight_sim: YSFlightSimulation = null
var camera: Camera3D = null
var player_transform: Transform3D = Transform3D.IDENTITY
var cam_mode: int = 1
var telemetry: Dictionary = {}
var airplane_transforms: Dictionary = {}

var _font: Font = null
var _radar_data: Dictionary = {}
var _should_draw: bool = false
var _radar_range: float = 20000.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = ThemeDB.fallback_font

func setup(p_controls: Node) -> void:
	controls = p_controls
	if controls != null and "ysflight_sim" in controls and controls.ysflight_sim != null:
		ysflight_sim = controls.ysflight_sim

func update_radar(
	p_camera: Camera3D,
	p_player_transform: Transform3D,
	p_telemetry: Dictionary,
	p_air_tfms: Dictionary,
	p_cam_mode: int
) -> void:
	camera = p_camera
	player_transform = p_player_transform
	telemetry = p_telemetry
	airplane_transforms = p_air_tfms
	cam_mode = p_cam_mode

	# Drawn ONLY in cockpit view (cam_mode == 1) and when player is alive
	var is_alive: bool = bool(telemetry.get("is_alive", true))
	if cam_mode != 1 or not is_alive:
		_should_draw = false
		_radar_data.clear()
		queue_redraw()
		return

	# Resolve simulation node if not cached
	if ysflight_sim == null:
		if controls != null and "ysflight_sim" in controls and controls.ysflight_sim != null:
			ysflight_sim = controls.ysflight_sim
		elif get_parent() != null and get_parent().get_parent() != null and "ysflight_sim" in get_parent().get_parent():
			ysflight_sim = get_parent().get_parent().ysflight_sim

	# Fetch radar range (default 20 km if missing or 0)
	_radar_range = float(telemetry.get("radar_range", 20000.0))
	if _radar_range <= 0.0:
		_radar_range = 20000.0

	# Query C++ radar contacts once per frame when drawn
	if ysflight_sim != null and ysflight_sim.has_method("get_radar_contacts"):
		_radar_data = ysflight_sim.get_radar_contacts(_radar_range)
	else:
		_radar_data.clear()

	_should_draw = true
	queue_redraw()

func _draw() -> void:
	if not _should_draw or camera == null or telemetry.is_empty():
		return

	if _font == null:
		_font = ThemeDB.fallback_font

	var vp_size: Vector2 = size
	if vp_size.x <= 10.0 or vp_size.y <= 10.0:
		vp_size = get_viewport_rect().size
	if vp_size.x <= 10.0 or vp_size.y <= 10.0:
		vp_size = Vector2(1920.0, 1080.0)

	var vp_rect := Rect2(Vector2.ZERO, vp_size)

	# Read settings
	var hud_scale: float = 1.0
	var radar_size: float = 1.0
	var color_name: String = "Green"
	var show_ground: bool = true
	var show_threat_arrows: bool = true

	if controls != null:
		hud_scale = float(controls.get_value("hud_scale", 1.0))
		radar_size = float(controls.get_value("radar_size", 1.0))
		color_name = str(controls.get_value("hud_color", "Green"))
		show_ground = bool(controls.get_value("radar_show_ground", true))
		show_threat_arrows = bool(controls.get_value("radar_threat_arrows", true))

	# HUD line color matching hud.gd
	var hud_col: Color = Color(0.35, 1.0, 0.45)
	match color_name:
		"Amber":
			hud_col = Color(1.0, 0.75, 0.2)
		"Cyan":
			hud_col = Color(0.2, 0.9, 1.0)
		"White":
			hud_col = Color(0.95, 0.95, 0.95)
		_:
			hud_col = Color(0.35, 1.0, 0.45)

	# Overall UI scale factor: (vp_height / 1080) * radar_size * hud_scale
	var s: float = (vp_size.y / 1080.0) * radar_size * hud_scale
	if s < 0.1:
		s = 1.0

	var line_w: float = maxf(1.0, 1.5 * s)
	var radius: float = 95.0 * s
	var centre: Vector2 = Vector2(vp_size.x - 125.0 * s, vp_size.y - 125.0 * s)
	var player_iff: int = int(telemetry.get("iff", 0))

	# --------------------------------------------------------------------------
	# 1. Background Disc & Range Rings
	# --------------------------------------------------------------------------
	# Very faint dark disc behind scope (black, alpha 0.25) for readability
	draw_circle(centre, radius, Color(0.0, 0.0, 0.0, 0.25))

	# Outer ring (full radar range) and inner ring (half range)
	draw_arc(centre, radius, 0.0, TAU, 48, hud_col, line_w)
	draw_arc(centre, radius * 0.5, 0.0, TAU, 36, hud_col, line_w)

	# --------------------------------------------------------------------------
	# 2. Heading-Up North ("N") Indicator on Outer Rim
	# --------------------------------------------------------------------------
	var heading_deg: float = float(telemetry.get("heading_deg", 0.0))
	var north_rad: float = -PI * 0.5 - deg_to_rad(heading_deg)
	var north_dir := Vector2(cos(north_rad), sin(north_rad))

	# Tick mark on rim pointing inward
	draw_line(centre + north_dir * (radius - 4.0 * s), centre + north_dir * radius, hud_col, line_w)

	# "N" character positioned just inside the rim
	var font_sz_n: int = maxi(9, int(round(11.0 * s)))
	var n_pos := centre + north_dir * (radius - 10.0 * s)
	var n_size := _font.get_string_size("N", HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_n)
	draw_string(_font, n_pos - Vector2(n_size.x * 0.5, -n_size.y * 0.35), "N", HORIZONTAL_ALIGNMENT_CENTER, -1, font_sz_n, hud_col)

	# --------------------------------------------------------------------------
	# 3. Radar Range Label (Lower-Left of Ring)
	# --------------------------------------------------------------------------
	var range_text: String = ""
	if _radar_range >= 1000.0:
		var km_val: float = _radar_range / 1000.0
		if fmod(km_val, 1.0) == 0.0:
			range_text = "%d km" % int(km_val)
		else:
			range_text = "%.1f km" % km_val
	else:
		range_text = "%d m" % int(_radar_range)

	var font_sz_lbl: int = maxi(9, int(round(11.0 * s)))
	var lbl_pos := centre + Vector2(-radius * 0.85, radius * 0.95)
	draw_string(_font, lbl_pos, range_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_lbl, hud_col)

	# --------------------------------------------------------------------------
	# 4. Player Aircraft Symbol at Scope Centre (Heading Up)
	# --------------------------------------------------------------------------
	draw_line(centre + Vector2(0.0, -6.0 * s), centre + Vector2(0.0, 5.0 * s), hud_col, line_w)
	draw_line(centre + Vector2(-6.0 * s, 0.0), centre + Vector2(6.0 * s, 0.0), hud_col, line_w)
	draw_line(centre + Vector2(-3.0 * s, 4.0 * s), centre + Vector2(3.0 * s, 4.0 * s), hud_col, line_w)
	draw_circle(centre, 1.5 * s, hud_col)

	# --------------------------------------------------------------------------
	# 5. Ground Objects (if radar_show_ground enabled)
	# --------------------------------------------------------------------------
	if show_ground and _radar_data.has("ground"):
		var ground: PackedFloat32Array = _radar_data.get("ground", PackedFloat32Array())
		var g_count: int = ground.size()
		var gi: int = 0
		var g_sz: float = maxf(2.0, 3.0 * s)
		var g_lock_sz: float = maxf(4.5, 6.0 * s)
		var rad_sq: float = radius * radius
		var range_scale: float = radius / _radar_range

		while gi < g_count:
			var g_right: float = ground[gi + 1]
			var g_fwd: float = ground[gi + 2]
			var g_iff: int = int(ground[gi + 4])
			var g_locked: bool = ground[gi + 5] >= 0.5
			gi += 6

			var g_offset := Vector2(g_right, -g_fwd) * range_scale
			if g_offset.length_squared() > rad_sq:
				continue

			var g_blip := centre + g_offset
			var g_is_enemy: bool = (g_iff != player_iff)
			var g_col: Color = Color(1.0, 0.3, 0.25) if g_is_enemy else Color(0.25, 0.65, 0.8, 0.8)
			var cur_sz: float = g_lock_sz if g_locked else g_sz

			draw_rect(Rect2(g_blip.x - cur_sz * 0.5, g_blip.y - cur_sz * 0.5, cur_sz, cur_sz), g_col, false, line_w)

	# --------------------------------------------------------------------------
	# 6. Missiles (Chasing player flashing 4 Hz + threat line; Player fired dim dot)
	# --------------------------------------------------------------------------
	if _radar_data.has("missiles"):
		var missiles: PackedFloat32Array = _radar_data.get("missiles", PackedFloat32Array())
		var m_count: int = missiles.size()
		var mi: int = 0
		var flash_4hz: bool = (int(Time.get_ticks_msec() * 0.008) % 2) == 0
		var rad_sq: float = radius * radius
		var range_scale: float = radius / _radar_range

		while mi < m_count:
			var m_right: float = missiles[mi]
			var m_fwd: float = missiles[mi + 1]
			var m_flags: int = int(missiles[mi + 3])
			mi += 5

			var is_chasing: bool = (m_flags & 1) != 0
			var is_player_fired: bool = (m_flags & 2) != 0

			# Other missiles are not shown (declutter)
			if not is_chasing and not is_player_fired:
				continue

			var m_offset := Vector2(m_right, -m_fwd) * range_scale
			if m_offset.length_squared() > rad_sq:
				continue

			var m_pos := centre + m_offset

			if is_chasing:
				# Thin red line toward centre (threat axis)
				draw_line(m_pos, centre, Color(1.0, 0.2, 0.2, 0.7), line_w)
				# Flashing red dot at 4 Hz
				if flash_4hz:
					draw_circle(m_pos, maxf(2.5, 3.0 * s), Color(1.0, 0.15, 0.15))
			elif is_player_fired:
				# Small dim dot in HUD color
				var dim_col: Color = hud_col
				dim_col.a = 0.55
				draw_circle(m_pos, maxf(1.5, 2.0 * s), dim_col)

	# --------------------------------------------------------------------------
	# 7. Aircraft Contacts
	# --------------------------------------------------------------------------
	if _radar_data.has("contacts"):
		var contacts: PackedFloat32Array = _radar_data.get("contacts", PackedFloat32Array())
		var count: int = contacts.size()
		var i: int = 0
		var sym_sz: float = maxf(4.0, 5.0 * s)
		var rad_sq: float = radius * radius
		var range_scale: float = radius / _radar_range
		var alt_font_sz: int = maxi(8, int(round(9.0 * s)))

		while i < count:
			var right: float = contacts[i + 1]
			var fwd: float = contacts[i + 2]
			var alt: float = contacts[i + 3]
			var rel_hdg: float = contacts[i + 4]
			var iff: int = int(contacts[i + 5])
			var is_locked: bool = contacts[i + 6] >= 0.5
			i += 8

			var blip_offset := Vector2(right, -fwd) * range_scale
			if blip_offset.length_squared() > rad_sq:
				continue

			var blip_pos := centre + blip_offset
			var is_enemy: bool = (iff != player_iff)
			var contact_col: Color = Color(1.0, 0.3, 0.25) if is_enemy else Color(0.35, 0.8, 1.0)

			# Symbol: small directional chevron rotated by rel_heading
			var heading_screen: float = -PI * 0.5 + rel_hdg
			var fwd_dir := Vector2(cos(heading_screen), sin(heading_screen))
			var perp_dir := Vector2(-fwd_dir.y, fwd_dir.x)

			var tip := blip_pos + fwd_dir * sym_sz
			var left_wing := blip_pos - fwd_dir * (sym_sz * 0.6) + perp_dir * (sym_sz * 0.65)
			var center_notch := blip_pos - fwd_dir * (sym_sz * 0.2)
			var right_wing := blip_pos - fwd_dir * (sym_sz * 0.6) - perp_dir * (sym_sz * 0.65)

			draw_colored_polygon(PackedVector2Array([tip, left_wing, center_notch, right_wing]), contact_col)

			# Altitude cue: |alt| > 300 m draws "+" or "-", with km diff when > 1 km
			var abs_alt: float = absf(alt)
			if abs_alt > 300.0:
				var sign_ch: String = "+" if alt > 0.0 else "-"
				var alt_text: String = ""
				if abs_alt > 1000.0:
					alt_text = "%s%.1f" % [sign_ch, abs_alt / 1000.0]
				else:
					alt_text = sign_ch
				draw_string(_font, blip_pos + Vector2(sym_sz + 2.0 * s, 3.0 * s), alt_text, HORIZONTAL_ALIGNMENT_LEFT, -1, alt_font_sz, contact_col)

			# Locked target: small square around blip
			if is_locked:
				var sq_r: float = sym_sz + 3.0 * s
				draw_rect(Rect2(blip_pos.x - sq_r, blip_pos.y - sq_r, sq_r * 2.0, sq_r * 2.0), contact_col, false, line_w)

	# --------------------------------------------------------------------------
	# 8. Threat Arrows (Off-screen / behind enemy aircraft within 10 km)
	# --------------------------------------------------------------------------
	if show_threat_arrows and camera != null and not airplane_transforms.is_empty():
		_draw_threat_arrows(vp_size, vp_rect, s, line_w, player_iff)

func _draw_threat_arrows(
	vp_size: Vector2,
	vp_rect: Rect2,
	s: float,
	line_w: float,
	player_iff: int
) -> void:
	var cam_tfm: Transform3D = camera.global_transform
	var cam_pos: Vector3 = cam_tfm.origin
	var cam_fwd: Vector3 = -cam_tfm.basis.z
	var locked_air_key: int = int(telemetry.get("locked_air_target_key", -1))
	var candidates: Array[Dictionary] = []

	for k in airplane_transforms.keys():
		var k_int: int = int(k)
		if k_int == locked_air_key:
			continue # Skip locked target (the HUD already draws its arrow)

		var st: Dictionary = airplane_transforms[k]
		if st.get("is_player", false) or not bool(st.get("is_alive", true)):
			continue
		if int(st.get("iff", -1)) == player_iff:
			continue # Only enemies

		var tgt_pos: Vector3 = st.get("pos", Vector3.ZERO)
		var diff: Vector3 = tgt_pos - cam_pos
		var dist_m: float = diff.length()
		if dist_m > 10000.0 or dist_m < 1.0:
			continue

		var is_behind: bool = cam_fwd.dot(diff) < 0.0
		if not is_behind:
			var sp: Vector2 = camera.unproject_position(tgt_pos)
			if vp_rect.has_point(sp):
				continue # No arrows for on-screen contacts

		candidates.append({ "dist": dist_m, "pos": tgt_pos })

	if candidates.is_empty():
		return

	# Sort candidates by distance ascending
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["dist"] < b["dist"]
	)

	var max_arrows: int = mini(3, candidates.size())
	var arrow_sz: float = maxf(8.0, 10.0 * s)
	var font_sz_arr: int = maxi(10, int(round(12.0 * s)))
	var red_col := Color(1.0, 0.3, 0.25)
	var inset: float = 40.0 * (vp_size.y / 1080.0)
	var center := vp_size * 0.5
	var bounds_half := center - Vector2(inset, inset)

	for idx in range(max_arrows):
		var cand: Dictionary = candidates[idx]
		var tgt_pos: Vector3 = cand["pos"]
		var dist_km: float = cand["dist"] / 1000.0

		var local_tgt: Vector3 = cam_tfm.affine_inverse() * tgt_pos
		var dir_2d := Vector2(local_tgt.x, -local_tgt.y)

		# Behind camera = dot(camera forward, target - camera position) < 0: mirror direction
		if cam_fwd.dot(tgt_pos - cam_pos) < 0.0:
			dir_2d = -dir_2d

		if dir_2d.length_squared() < 0.001:
			dir_2d = Vector2.UP
		else:
			dir_2d = dir_2d.normalized()

		# Intersect with screen edge inset by 40 px
		var tx: float = absf(bounds_half.x / dir_2d.x) if absf(dir_2d.x) > 0.0001 else 1e9
		var ty: float = absf(bounds_half.y / dir_2d.y) if absf(dir_2d.y) > 0.0001 else 1e9
		var t_hit: float = minf(tx, ty)
		var edge_pt: Vector2 = center + dir_2d * t_hit

		# Draw small red chevron pointing toward target
		var perp := Vector2(-dir_2d.y, dir_2d.x)
		var tip := edge_pt + dir_2d * (arrow_sz * 0.5)
		var left_leg := edge_pt - dir_2d * (arrow_sz * 0.5) + perp * (arrow_sz * 0.6)
		var right_leg := edge_pt - dir_2d * (arrow_sz * 0.5) - perp * (arrow_sz * 0.6)

		draw_line(left_leg, tip, red_col, line_w)
		draw_line(right_leg, tip, red_col, line_w)

		# Draw range in km (1 decimal) next to chevron (offset inward)
		var km_text: String = "%.1f" % dist_km
		var text_center: Vector2 = edge_pt - dir_2d * (arrow_sz + 11.0 * s)
		var str_sz := _font.get_string_size(km_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_arr)
		draw_string(_font, text_center - Vector2(str_sz.x * 0.5, -str_sz.y * 0.35), km_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_sz_arr, red_col)
