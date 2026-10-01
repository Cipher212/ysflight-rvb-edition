extends CanvasLayer

# In-event overlay (offline RvB event): event clock and team kills at the top centre, and the "press Esc again"
# hint. Listens to core/event_session.gd; draws nothing else (the flight HUD stays hud.gd).

const Kit := preload("res://ui/ui_kit.gd")
const HINT := "PRESS ESC AGAIN TO LEAVE YOUR JET"
const HINT_PENALTY := "PRESS ESC AGAIN TO LEAVE - COUNTS AS A DEATH (LAND AND STOP FIRST)"

var _clock: Label = null
var _blue: Label = null
var _red: Label = null
var _hint: Label = null
var _last := {}

func setup(session: Node) -> void:
	name = "EventOverlay"
	layer = 20
	var root := Control.new()
	root.theme = Kit.THEME
	Kit.fit_to_window(root)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bar.offset_top = 12
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
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
	# Only push changed text (setting Label.text relayouts)
	var clock := Kit.clock(float(state.get("time_left", 0.0)))
	if clock != _last.get("clock", ""):
		_clock.text = clock
		_last["clock"] = clock
	for k in [["blue_kills", _blue, "BLUE "], ["red_kills", _red, "RED "]]:
		var v: int = int(state.get(k[0], 0))
		if v != _last.get(k[0], -1):
			k[1].text = k[2] + str(v)
			_last[k[0]] = v
