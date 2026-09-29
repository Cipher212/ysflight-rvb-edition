extends Label

# Debug text (setting "Show Debug / Perf Text", F11), top right under the FPS monitor: camera mode, CPU
# times and flight data. Text is only built while it is shown.

var controls: Node = null

func _init() -> void:
	name = "DebugOverlay"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_theme_color_override("font_color", Color(0.35, 1.0, 0.35))
	add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	add_theme_constant_override("outline_size", 4)
	add_theme_font_size_override("font_size", 15)
	size = Vector2(700.0, 0.0)
	visible = false

func update(camera_status: String, tel: Dictionary) -> void:
	visible = controls != null and bool(controls.get_value("show_debug_text", false))
	if not visible:
		return
	position = Vector2(get_viewport_rect().size.x - size.x - 10.0, 28.0)
	var gear: float = tel.get("gear", 1.0)
	text = ("CAM: %s\nCPU process %.2f ms | physics %.2f ms\nACFT: %s%s | SPD %d kt (M%.2f) | ALT %d ft | VSI %+d fpm\n" +
		"HDG %03d | PITCH %+.1f | BANK %+.1f | G %.1f\nTHR %d%%%s | FUEL %d%% | GEAR %s | FLAP %d%%\n" +
		"WPN %s x%d | GUN %d | FLR %d | CTRL %s") % [
		camera_status, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		tel.get("identifier", ""), "" if tel.get("is_alive", true) else " [DESTROYED]",
		int(round(tel.get("speed_kt", 0.0))), tel.get("mach", 0.0), int(round(tel.get("altitude_ft", 0.0))),
		int(round(tel.get("vsi_fpm", 0.0))), int(round(tel.get("heading_deg", 0.0))) % 360, tel.get("pitch_deg", 0.0),
		tel.get("bank_deg", 0.0), tel.get("g_force", 1.0), int(round(tel.get("throttle", 0.0) * 100.0)),
		" [AB]" if tel.get("afterburner", false) else "", int(round(tel.get("fuel_pct", 100.0))),
		"DOWN" if gear >= 0.99 else ("UP" if gear <= 0.01 else "MOVING"), int(round(tel.get("flaps", 0.0) * 100.0)),
		tel.get("weapon_name", ""), int(tel.get("ammo_count", 0)), int(tel.get("gun_ammo", 0)), int(tel.get("flare_count", 0)),
		controls.get_active_stick_device_name().to_upper()]
