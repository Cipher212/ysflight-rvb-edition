extends CanvasLayer

# Mid-event spawn menu (offline RvB event): opens at the start, after Esc x2 and after being shot down.
# Aircraft (your team's; the role comes from the aircraft), start position, loadout; FLY / SETTINGS / END EVENT.
# The event keeps running behind it (core/event_session.gd never pauses). Remembers the last choice.

const Kit := preload("res://ui/ui_kit.gd")
const EventConfig := preload("res://core/event_config.gd")
const END_CONFIRM_S := 3.0

var session: Node = null
var _aircraft: Array = []     # catalog entries of the player's team
var _starts := PackedStringArray()
var _ac_opt: OptionButton = null
var _start_opt: OptionButton = null
var _load_opt: OptionButton = null
var _role: Label = null
var _status: Label = null
var _end_btn: Button = null
var _end_armed_until := 0.0

func setup(p_session: Node) -> void:
	name = "SpawnMenu"
	layer = 30
	session = p_session
	visible = false
	_aircraft = EventConfig.aircraft_for(session.catalog, session.player_team())
	_starts = session.start_positions()

	var root := Control.new()
	root.theme = Kit.THEME
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0.016, 0.024, 0.051, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var body := Kit.panel(center, "SPAWN  /  " + session.player_team().to_upper() + " FORCE", session.player_team())
	body.custom_minimum_size = Vector2(760, 0)

	var names := []
	for a in _aircraft:
		names.append(a["identifier"])
	_ac_opt = Kit.options(names)
	_ac_opt.item_selected.connect(func(_i: int) -> void: _update_role())
	Kit.row(body, "AIRCRAFT", _ac_opt)
	_role = Kit.label("", "DimLabel")
	Kit.row(body, "ROLE", _role)
	var start_names := []
	for s in _starts:
		start_names.append(_pretty_start(s))
	_start_opt = Kit.options(start_names)
	Kit.row(body, "START", _start_opt)
	_load_opt = Kit.options(session.LOADOUTS)
	Kit.row(body, "LOADOUT", _load_opt)
	_status = Kit.label("THE EVENT KEEPS RUNNING WHILE YOU CHOOSE", "DimLabel")
	body.add_child(_status)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	body.add_child(buttons)
	var fly := Kit.button("FLY", "RedButton" if session.player_team() == "red" else "BlueButton", _fly)
	fly.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(fly)
	buttons.add_child(Kit.button("SETTINGS", "", func() -> void: session.open_settings()))
	_end_btn = Kit.button("END EVENT", "", _end)
	buttons.add_child(_end_btn)
	_update_role()

	session.spawn_menu_requested.connect(_open)

func _open() -> void:
	visible = true
	_end_armed_until = 0.0
	_end_btn.text = "END EVENT"

func _update_role() -> void:
	if _aircraft.is_empty():
		_role.text = "NO AIRCRAFT FOR THIS TEAM"
		return
	_role.text = _aircraft[_ac_opt.selected]["role"]

func _fly() -> void:
	if _aircraft.is_empty() or _starts.is_empty():
		return
	var ok: bool = session.spawn(_aircraft[_ac_opt.selected]["identifier"], _starts[_start_opt.selected],
		session.LOADOUTS[_load_opt.selected])
	if ok:
		visible = false
	else:
		_status.text = "COULD NOT SPAWN HERE - TRY ANOTHER START"

func _end() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now < _end_armed_until:
		session.end_event()
		return
	_end_armed_until = now + END_CONFIRM_S
	_end_btn.text = "CONFIRM END"

# "AI_BLUE_NORTH" -> "AIR: NORTH", "[IFF1]COLE_AFB_RUNWAY" -> "COLE AFB RUNWAY"
static func _pretty_start(stp: String) -> String:
	var up := stp.to_upper()
	if up.begins_with("AI_BLUE_") or up.begins_with("AI_RED_"):
		return "AIR: " + up.get_slice("_", 2)
	return stp.substr(stp.find("]") + 1).replace("_", " ")
