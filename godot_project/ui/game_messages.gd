extends Control

# ==============================================================================
# YSFlight RvB Edition - Native Combat Event Feed
# ==============================================================================
# In-game native YSFlight game events / kill feed display.
# Polls C++ simulation game events at ~5 Hz, maintaining up to 6 visible
# messages expiring after 8 seconds. Rendered in ACES_07 font with green HUD style
# (no black outline). The killer and killed are colored by their respective teams.
# ==============================================================================

const ACES_FONT := preload("res://ui/fonts/ACES07_Regular.ttf")

const MAX_VISIBLE_MESSAGES := 6
const EXPIRE_SECONDS := 8.0
const POLL_INTERVAL := 0.2

const COLOR_BLUE_TEAM := "#4ea8ff"
const COLOR_RED_TEAM := "#ff4d4d"
const COLOR_NEUTRAL := "#d9dfee"
const COLOR_HUD_GREEN := "#59ff73"

var sim: YSFlightSimulation = null
var controls: Node = null

var _active_messages: Array[Dictionary] = []
var _last_sequence: int = 0
var _last_generation: int = -1
var _poll_timer: float = 0.0
var _label: RichTextLabel = null

func _ready() -> void:
	name = "GameMessages"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_label = RichTextLabel.new()
	_label.name = "MessageLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)

	_label.add_theme_font_override("normal_font", ACES_FONT)
	_label.add_theme_color_override("default_color", Color(0.35, 1.0, 0.45))
	_label.add_theme_constant_override("outline_size", 0)
	add_child(_label)

	_update_layout()
	get_viewport().size_changed.connect(_update_layout)

func setup(p_sim: YSFlightSimulation, p_controls: Node = null) -> void:
	sim = p_sim
	controls = p_controls
	if controls != null and controls.has_signal("changed"):
		controls.changed.connect(_on_controls_changed)
	_update_layout()

func _on_controls_changed(key: String) -> void:
	if key == "hud_scale" or key.is_empty():
		_update_layout()

func _update_layout() -> void:
	var vp_size := get_viewport_rect().size
	if vp_size.y <= 10.0:
		vp_size = Vector2(1920.0, 1080.0)

	var hud_scale: float = 1.0
	if controls != null and controls.has_method("get_value"):
		hud_scale = float(controls.get_value("hud_scale", 1.0))

	var s: float = (vp_size.y / 1080.0) * hud_scale
	if s < 0.1:
		s = 1.0

	# Left-aligned below the weapon inventory list (weapons start at wy=75, end ~wy=201)
	position = Vector2(roundf(60.0 * s), roundf(220.0 * s))
	size = Vector2(roundf(600.0 * s), roundf(220.0 * s))

	if _label != null:
		var font_sz: int = maxi(11, int(round(14.0 * s)))
		var line_sep: int = maxi(2, int(round(4.0 * s)))
		_label.add_theme_font_size_override("normal_font_size", font_sz)
		_label.add_theme_constant_override("outline_size", 0)
		_label.add_theme_constant_override("line_separation", line_sep)

func _process(delta: float) -> void:
	var changed := false

	# 1. Expire messages using frame delta
	for i in range(_active_messages.size() - 1, -1, -1):
		_active_messages[i]["time_left"] -= delta
		if _active_messages[i]["time_left"] <= 0.0:
			_active_messages.remove_at(i)
			changed = true

	# 2. Poll simulation events at bounded ~5 Hz interval
	_poll_timer += delta
	if _poll_timer >= POLL_INTERVAL:
		_poll_timer = 0.0
		if is_instance_valid(sim) and sim.has_method("get_game_events"):
			var resp: Dictionary = sim.get_game_events(_last_sequence)
			var gen: int = int(resp.get("generation", 0))

			# Clear messages on mission restart / reset
			if _last_generation != -1 and gen != _last_generation:
				_active_messages.clear()
				_last_sequence = 0
				changed = true
			_last_generation = gen

			var events: Array = resp.get("events", [])
			if not events.is_empty():
				for ev in events:
					var seq: int = int(ev.get("sequence", 0))
					if seq > _last_sequence:
						_last_sequence = seq
					var bbcode_line := _format_event_bbcode(ev)
					_active_messages.push_front({
						"sequence": seq,
						"time_left": EXPIRE_SECONDS,
						"bbcode": bbcode_line
					})
				if _active_messages.size() > MAX_VISIBLE_MESSAGES:
					_active_messages.resize(MAX_VISIBLE_MESSAGES)
				changed = true
			elif bool(resp.get("dropped", false)):
				_last_sequence = int(resp.get("latest_sequence", _last_sequence))

			_last_sequence = int(resp.get("latest_sequence", _last_sequence))

	if changed:
		_rebuild_text()

func _rebuild_text() -> void:
	if _label == null:
		return
	if _active_messages.is_empty():
		_label.text = ""
		return

	var lines := PackedStringArray()
	for item in _active_messages:
		lines.append(item.get("bbcode", ""))
	_label.text = "\n".join(lines)

func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")

func _get_iff_color(iff: int) -> String:
	match iff:
		0:
			return COLOR_BLUE_TEAM
		3:
			return COLOR_RED_TEAM
		_:
			return COLOR_NEUTRAL

func _format_event_bbcode(ev: Dictionary) -> String:
	var kind: String = str(ev.get("kind", ""))
	var victim: Dictionary = ev.get("victim", {})
	var victim_name := _escape_bbcode(str(victim.get("name", "Unknown")))
	var victim_col := _get_iff_color(int(victim.get("iff", -1)))

	match kind:
		"kill":
			var killer: Dictionary = ev.get("killer", {})
			var killer_name := _escape_bbcode(str(killer.get("name", "Unknown")))
			var killer_col := _get_iff_color(int(killer.get("iff", -1)))
			var weapon_str := _escape_bbcode(str(ev.get("weapon", "weapon")))
			return "[color=%s]%s[/color] [color=%s]destroyed[/color] [color=%s]%s[/color] [color=%s](%s)[/color]" % [
				killer_col, killer_name, COLOR_HUD_GREEN, victim_col, victim_name, COLOR_HUD_GREEN, weapon_str]

		"death":
			var cause_str := _escape_bbcode(str(ev.get("cause", "")))
			return "[color=%s]%s[/color] [color=%s]was destroyed (%s)[/color]" % [
				victim_col, victim_name, COLOR_HUD_GREEN, cause_str]

		"crash":
			var cause_str := _escape_bbcode(str(ev.get("cause", "")))
			return "[color=%s]%s[/color] [color=%s]crashed (%s)[/color]" % [
				victim_col, victim_name, COLOR_HUD_GREEN, cause_str]

		"leave":
			return "[color=%s]%s[/color] [color=%s]left the aircraft[/color]" % [
				victim_col, victim_name, COLOR_HUD_GREEN]

		"disconnect":
			var disc_name := _escape_bbcode(str(victim.get("name", "Participant")))
			return "[color=%s]%s[/color] [color=%s]disconnected[/color]" % [
				COLOR_NEUTRAL, disc_name, COLOR_HUD_GREEN]

		_:
			var raw_text := _escape_bbcode(str(ev.get("text", "")))
			return "[color=%s]%s[/color]" % [COLOR_HUD_GREEN, raw_text]
