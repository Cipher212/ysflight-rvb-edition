extends Control

const Kit := preload("res://ui/ui_kit.gd")
const Roster := preload("res://ui/lobby_roster.gd")
const Messages := preload("res://ui/lobby_messages.gd")
var _session: Node
var _status: Label
var _team_buttons: Array[Button] = []
var _roster: VBoxContainer
var _resume: Button
var _end: Button
var _confirm_until := 0.0
var _refresh_in := 0.0

func setup(session: Node) -> void:
	_session = session
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 40)
	add_child(margin)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 22)
	margin.add_child(page)
	page.add_child(Kit.label("PRE-FLIGHT LOBBY", "TitleLabel"))
	_status = Kit.label("", "TagLabel")
	page.add_child(_status)
	page.add_child(HSeparator.new())
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 24)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(columns)
	var teams := Kit.panel(columns, "TEAM SELECTION")
	teams.get_parent().get_parent().custom_minimum_size.x = 320
	for team in ["blue", "red"]:
		var button := Kit.button(team.to_upper() + " TEAM", "BlueButton" if team == "blue" else "RedButton", func() -> void:
			session.choose_team(team)
			refresh())
		button.toggle_mode = true
		button.custom_minimum_size.y = 72
		teams.add_child(button)
		_team_buttons.append(button)
	var note := Kit.label("CHOOSE ONCE\n\nYour team locks when you enter the hangar or spectate.\n\nOnly your team's aircraft, starts and spectator targets are available.", "DimLabel")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	teams.add_child(note)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	teams.add_child(spacer)
	teams.add_child(Kit.label(str(session.config.get("player_name", "PLAYER")), "SectionLabel"))
	teams.add_child(Kit.label("OFFLINE EVENT" if session.is_event else "FREE FLIGHT", "DimLabel"))
	var roster_box := Kit.panel(columns, "PILOT ROSTER")
	roster_box.get_parent().get_parent().size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	roster_box.add_child(scroll)
	_roster = Roster.new()
	_roster.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roster.add_theme_constant_override("separation", 10)
	scroll.add_child(_roster)
	_roster.target_selected.connect(func(key: int) -> void: session.spectate(key))
	var chat_box := Kit.panel(columns, "SESSION LOG + CHAT")
	chat_box.get_parent().get_parent().custom_minimum_size.x = 420
	var chat := Messages.new()
	chat.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_box.add_child(chat)
	chat.setup(session)
	page.add_child(HSeparator.new())
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 14)
	page.add_child(footer)
	_end = Kit.button(session.end_label(), "", _end_pressed)
	footer.add_child(_end)
	footer.add_child(Kit.button("SETTINGS", "", session.open_settings))
	_resume = Kit.button("RESUME FLIGHT", "", session.resume_flight)
	footer.add_child(_resume)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(gap)
	footer.add_child(Kit.button("SPECTATE", "", func() -> void:
		if not session.spectate():
			_status.text = session.last_error))
	footer.add_child(Kit.button("ENTER HANGAR  >", "RedButton", func() -> void:
		if not session.enter_hangar():
			_status.text = session.last_error))
	refresh()

func refresh() -> void:
	_status.text = _session.status_text()
	for i in _team_buttons.size():
		_team_buttons[i].set_pressed_no_signal(_session.player_team() == ("blue" if i == 0 else "red"))
		_team_buttons[i].disabled = _session.team_locked
	_roster.refresh(_session.roster(), _session.player_team())
	_resume.visible = _session.can_resume()
	if Time.get_ticks_msec() / 1000.0 > _confirm_until:
		_end.text = _session.end_label()

func _end_pressed() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now < _confirm_until:
		_session.end_session()
	else:
		_confirm_until = now + 3.0
		_end.text = "CONFIRM EXIT"

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_in -= delta
	if _refresh_in <= 0:
		_refresh_in = 0.5
		refresh()
