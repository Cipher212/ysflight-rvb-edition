extends CanvasLayer

# In-event overlay (offline RvB event): event clock and team kills at the bottom-left corner, and the "press Esc again"
# hint. Listens to core/event_session.gd; draws nothing else (the flight HUD stays hud.gd).

const Kit := preload("res://ui/ui_kit.gd")
const HINT := "PRESS ESC AGAIN TO LEAVE YOUR JET"
const HINT_PENALTY := "PRESS ESC AGAIN TO LEAVE - COUNTS AS A DEATH (LAND AND STOP FIRST)"
const FIVE_MIN_SEC := 300.0
const ONE_MIN_SEC := 60.0
const SINGLE_FLASH_DURATION := 1.0
const FLASH_COLOR := Color(1.0, 0.25, 0.2)

var _clock: Label = null
var _blue: Label = null
var _red: Label = null
var _hint: Label = null
var _last := {}
var _prev_time_left: float = -1.0
var _flashed_5m: bool = false
var _flash_5m_left: float = 0.0
var _in_1m_warning: bool = false
var _pulse_time: float = 0.0
var _flash_active: bool = false

func setup(session: Node) -> void:
	name = "EventOverlay"
	layer = 20
	set_process(false)
	var root := Control.new()
	root.theme = Kit.THEME
	Kit.fit_to_window(root)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bar.offset_left = 18
	bar.offset_top = -18
	bar.offset_bottom = -18
	bar.grow_horizontal = Control.GROW_DIRECTION_END
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(bar)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 22)
	bar.add_child(h)
	_blue = Kit.label("0", "BlueChip")
	_clock = Kit.label("--:--", "BigNumber")
	_clock.add_theme_font_size_override("font_size", 34)
	_red = Kit.label("0", "RedChip")
	for c in [_blue, _clock, _red]:
		c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(c)

	_hint = Kit.label(HINT, "TagLabel")
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.offset_top = -120
	_hint.offset_bottom = -120 # grows up from here to its text height (else the pale box fills to the bottom)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint.visible = false
	root.add_child(_hint)

	session.state_updated.connect(_on_state)
	session.esc_hint.connect(_on_esc_hint)

# RvB rule: leaving is free only when landed and stopped (C++ EventMatch scores anything else as a death)
func _on_esc_hint(show: bool) -> void:
	_hint.text = HINT if bool(_last.get("player_parked", false)) else HINT_PENALTY
	_hint.visible = show

func _on_state(state: Dictionary) -> void:
	_last["player_parked"] = state.get("player_parked", false)
	var time_left: float = float(state.get("time_left", 0.0))
	var countdown: float = float(state.get("countdown", -1.0))
	# Only push changed text (setting Label.text relayouts)
	var clock := Kit.clock(time_left)
	if countdown >= 0.0:
		clock = "START %02d" % ceili(countdown)
		_prev_time_left = -1.0
		_flashed_5m = false
		_flash_5m_left = 0.0
		_in_1m_warning = false
	else:
		if time_left > FIVE_MIN_SEC + 5.0:
			_flashed_5m = false
		if not _flashed_5m:
			if (_prev_time_left > FIVE_MIN_SEC and time_left <= FIVE_MIN_SEC) or (_prev_time_left < 0.0 and absf(time_left - FIVE_MIN_SEC) <= 0.5):
				_flashed_5m = true
				_flash_5m_left = SINGLE_FLASH_DURATION
				_pulse_time = 0.0
		_in_1m_warning = time_left > 0.0 and time_left <= ONE_MIN_SEC
		_prev_time_left = time_left
	var should_process := _flash_5m_left > 0.0 or _in_1m_warning
	if should_process != is_processing():
		set_process(should_process)
		if not should_process:
			_set_clock_flash(false)

	if clock != _last.get("clock", ""):
		_clock.text = clock
		_last["clock"] = clock
	for k in [["blue_kills", _blue, "BLUE "], ["red_kills", _red, "RED "]]:
		var v: int = int(state.get(k[0], 0))
		if v != _last.get(k[0], -1):
			k[1].text = k[2] + str(v)
			_last[k[0]] = v

func _process(delta: float) -> void:
	if _clock == null:
		return
	if _flash_5m_left > 0.0:
		_flash_5m_left = maxf(0.0, _flash_5m_left - delta)
		_set_clock_flash(_flash_5m_left > 0.0)
		if _flash_5m_left <= 0.0 and not _in_1m_warning:
			set_process(false)
		return
	if _in_1m_warning:
		_pulse_time += delta
		var on: bool = fmod(_pulse_time * 2.5, 1.0) < 0.5
		_set_clock_flash(on)
	else:
		_set_clock_flash(false)
		set_process(false)

func _set_clock_flash(on: bool) -> void:
	if _flash_active == on or _clock == null:
		return
	_flash_active = on
	if on:
		_clock.add_theme_color_override("font_color", FLASH_COLOR)
	else:
		_clock.remove_theme_color_override("font_color")

