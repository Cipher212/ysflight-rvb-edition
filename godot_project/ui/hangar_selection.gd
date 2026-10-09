extends Control

const Kit := preload("res://ui/ui_kit.gd")
const Loadout := preload("res://core/hangar_loadout.gd")
const Editor := preload("res://ui/hangar_loadout_panel.gd")
const Preview := preload("res://ui/hangar_preview.gd")
const CLASSES := ["GUNNER", "MULTIROLE", "ATTACKER", "STEALTH", "HEAVY", "CAS"]
var preview: SubViewportContainer
var _session: Node
var _aircraft: ItemList
var _starts: OptionButton
var _editor: VBoxContainer
var _title: Label
var _error: Label
var _fly: Button
var _models: Dictionary = {}
var _choices: Array = []
var _choice_rows := PackedInt32Array()
var _model: RefCounted
var _current := ""
var _last_preview := ""
var _binding := false

func setup(session: Node) -> void:
	_session = session
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 24)
	add_child(margin)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 16)
	margin.add_child(page)
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 18)
	page.add_child(columns)
	var aircraft_box := Kit.panel(columns, "AIRCRAFT")
	aircraft_box.get_parent().get_parent().custom_minimum_size.x = 290
	_aircraft = ItemList.new()
	_aircraft.custom_minimum_size.x = 260
	_aircraft.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_aircraft.item_selected.connect(_aircraft_row_selected)
	aircraft_box.add_child(_aircraft)
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(center)
	_title = Kit.label("", "SectionLabel")
	center.add_child(_title)
	preview = Preview.new()
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.add_child(preview)
	var camera_help := HBoxContainer.new()
	center.add_child(camera_help)
	var hint := Kit.label("DRAG: ORBIT  /  WHEEL: ZOOM  /  SHIFT + DRAG: HEIGHT  /  DOUBLE CLICK: OVERVIEW", "DimLabel")
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camera_help.add_child(hint)
	var editor_panel := PanelContainer.new()
	editor_panel.custom_minimum_size.x = 445
	columns.add_child(editor_panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	editor_panel.add_child(scroll)
	_editor = Editor.new()
	_editor.custom_minimum_size.x = 405
	_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_editor)
	_editor.edited.connect(_edited)
	_editor.station_focused.connect(func(index: int) -> void: preview.focus_station(index))
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 16)
	page.add_child(footer)
	footer.add_child(Kit.button("< LOBBY", "", session.show_lobby))
	footer.add_child(Kit.button("SETTINGS", "", session.open_settings))
	footer.add_child(Kit.label("START POSITION", "SectionLabel"))
	_starts = OptionButton.new()
	_starts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_starts.fit_to_longest_item = false
	footer.add_child(_starts)
	_fly = Kit.button("FLY NOW", "RedButton", _spawn)
	_fly.custom_minimum_size.x = 220
	footer.add_child(_fly)
	_error = Kit.label("", "RedText")
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_error)

func refresh_aircraft() -> void:
	var choices: Array = _session.aircraft().filter(func(entry: Dictionary) -> bool:
		# BVR identifiers now resolve to MULTIROLE; omit the defunct tag explicitly.
		return entry["role"] in CLASSES and not str(entry["identifier"]).to_upper().contains("/BVR)"))
	if str(choices) != str(_choices):
		_choices = choices
		_rebuild_aircraft_list()
	var found := -1
	for i in _choices.size():
		if _choices[i]["identifier"] == _current:
			found = i
	if not _choices.is_empty():
		_select_aircraft(maxi(found, 0))
	var previous := _starts.get_item_text(_starts.selected) if _starts.selected >= 0 else ""
	_starts.clear()
	for start in _session.start_positions():
		_starts.add_item(start)
		if start == previous:
			_starts.select(_starts.item_count - 1)
	_fly.disabled = _choices.is_empty() or _starts.item_count == 0
	if _model != null:
		_edited()

func _rebuild_aircraft_list() -> void:
	_aircraft.clear()
	_choice_rows.resize(_choices.size())
	for aircraft_class in CLASSES:
		var heading := -1
		for i in _choices.size():
			var entry: Dictionary = _choices[i]
			if entry["role"] != aircraft_class:
				continue
			if heading < 0:
				heading = _aircraft.add_item(aircraft_class)
				_aircraft.set_item_selectable(heading, false)
				_aircraft.set_item_metadata(heading, -1)
				_aircraft.set_item_custom_bg_color(heading, Kit.PALE)
				_aircraft.set_item_custom_fg_color(heading, Kit.INK)
			var identifier: String = entry["identifier"]
			var row := _aircraft.add_item("  " + identifier.get_slice("(", 0).replace("[BLUE]", "").replace("[RED]", "").replace("_", " "))
			_aircraft.set_item_tooltip(row, identifier + "\n" + str(entry["role"]))
			_aircraft.set_item_metadata(row, i)
			_choice_rows[i] = row

func _aircraft_row_selected(row: int) -> void:
	var index := int(_aircraft.get_item_metadata(row))
	if index >= 0:
		_select_aircraft(index)

func _select_aircraft(index: int) -> void:
	if index < 0 or index >= _choices.size():
		return
	var identifier: String = _choices[index]["identifier"]
	var reset := identifier != _current
	_current = identifier
	_aircraft.select(_choice_rows[index])
	_aircraft.ensure_current_is_visible()
	_title.text = identifier.replace("_", " ")
	if not _models.has(identifier):
		var model := Loadout.new()
		model.setup(_session.sim, identifier)
		_models[identifier] = model
	_model = _models[identifier]
	_binding = true
	_editor.bind_model(_model)
	_binding = false
	_update_preview(reset)
	_edited()

func _edited() -> void:
	if _model == null or _binding:
		return
	var check: Dictionary = _model.validation()
	_error.text = str(check.get("error", ""))
	_fly.disabled = not bool(check.get("ok", false)) or _starts.item_count == 0
	_update_preview(false)

func _update_preview(reset: bool) -> void:
	var signature := _current + str(_model.slots)
	if signature == _last_preview and not reset:
		return
	if preview.show_aircraft(_session.sim, _current, _model.fuel, _model.slots, _model.points, reset):
		_last_preview = signature
	else:
		_error.text = "Preview unavailable for this loadout. " + str(_model.validation().get("error", ""))

func _spawn() -> void:
	if _model == null or _starts.selected < 0:
		return
	var result: Dictionary = _session.spawn_custom(_current, _starts.get_item_text(_starts.selected), _model.fuel, _model.slots)
	_error.text = str(result.get("error", ""))
