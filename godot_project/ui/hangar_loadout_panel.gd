extends VBoxContainer

# Right-side editor. Kept separate from the preview so the layout can move to a bottom tray later.
const Kit := preload("res://ui/ui_kit.gd")
const Presets := preload("res://core/loadout_presets.gd")
signal edited
signal station_focused(index: int)
var model: RefCounted
var _presets := Presets.new()
var _stations: ItemList
var _weapon: OptionButton
var _count: SpinBox
var _fuel: HSlider
var _fuel_text: Label
var _stats: Label
var _selected_title: Label
var _preset_options: OptionButton
var _preset_name: LineEdit
var _notice: Label
var _options: Array = []
var _syncing := false

func _ready() -> void:
	add_theme_constant_override("separation", 12)
	add_child(Kit.header_strip("HARDPOINTS + LOADOUT"))
	add_child(Kit.label("SELECT A STATION BELOW TO INSPECT ITS LOADOUT", "DimLabel"))
	_stations = ItemList.new()
	_stations.custom_minimum_size.y = 195
	_stations.item_selected.connect(select_station)
	add_child(_stations)
	_selected_title = Kit.label("", "SectionLabel")
	add_child(_selected_title)
	_weapon = OptionButton.new()
	_weapon.item_selected.connect(_weapon_changed)
	add_child(_weapon)
	_count = SpinBox.new()
	_count.min_value = 0
	_count.max_value = 100
	_count.step = 1
	_count.value_changed.connect(_count_changed)
	Kit.row(self, "QUANTITY PER STATION", _count, 235)
	add_child(HSeparator.new())
	_fuel_text = Kit.label("INTERNAL FUEL", "SectionLabel")
	add_child(_fuel_text)
	_fuel = HSlider.new()
	_fuel.min_value = 0
	_fuel.max_value = 100
	_fuel.step = 1
	_fuel.custom_minimum_size.y = 36
	_fuel.value_changed.connect(func(value: float) -> void:
		if model != null and not _syncing:
			model.fuel = value
			_update_stats()
			edited.emit())
	add_child(_fuel)
	_stats = Kit.label("", "DimLabel")
	add_child(_stats)
	add_child(HSeparator.new())
	add_child(Kit.label("SAVED LOADOUTS", "SectionLabel"))
	_preset_options = OptionButton.new()
	add_child(_preset_options)
	var actions := HBoxContainer.new()
	add_child(actions)
	actions.add_child(Kit.button("LOAD", "", _load_preset))
	actions.add_child(Kit.button("DELETE", "", _delete_preset))
	_preset_name = LineEdit.new()
	_preset_name.placeholder_text = "PRESET NAME"
	_preset_name.max_length = 24
	add_child(_preset_name)
	add_child(Kit.button("SAVE CURRENT LOADOUT", "", _save_preset))
	_notice = Kit.label("", "DimLabel")
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_notice)

func bind_model(value: RefCounted) -> void:
	model = value
	_notice.text = ""
	_syncing = true
	_fuel.value = model.fuel
	_syncing = false
	_refresh_stations()
	_refresh_presets()
	select_station(model.selected, false)
	_update_stats()

func _refresh_stations() -> void:
	_stations.clear()
	for i in model.slots.size():
		var slot: Dictionary = model.slots[i]
		_stations.add_item("%02d   %s%s" % [i + 1, slot["weapon"], "  x%d" % int(slot["count"]) if int(slot["count"]) > 0 else ""])
	if model.selected < _stations.item_count:
		_stations.select(model.selected)

func select_station(index: int, focus_camera: bool = true) -> void:
	if model == null or model.slots.is_empty():
		_weapon.disabled = true
		_count.editable = false
		_selected_title.text = "NO EDITABLE STATIONS"
		return
	model.selected = clampi(index, 0, model.slots.size() - 1)
	_stations.select(model.selected)
	var mirror := int(model.points[model.selected]["mirror"])
	_selected_title.text = "STATION %02d" % (model.selected + 1)
	if mirror >= 0:
		_selected_title.text += " + %02d  /  SYMMETRIC" % (mirror + 1)
	_options = model.options(model.selected)
	_weapon.clear()
	var slot: Dictionary = model.slots[model.selected]
	for option in _options:
		_weapon.add_item(str(option["weapon"]) + ("  /  MAX %d" % int(option["capacity"]) if int(option["capacity"]) > 0 else ""))
		if option["weapon"] == slot["weapon"]:
			_weapon.select(_weapon.item_count - 1)
	_weapon.disabled = false
	_sync_count()
	edited.emit()
	if focus_camera:
		station_focused.emit(model.selected)

func _sync_count() -> void:
	_syncing = true
	var option: Dictionary = _options[maxi(_weapon.selected, 0)]
	_count.min_value = 0 if option["weapon"] == "EMPTY" else 1
	_count.max_value = int(option["capacity"])
	_count.value = int(model.slots[model.selected]["count"])
	_count.editable = int(option["capacity"]) > 1
	_syncing = false

func _weapon_changed(index: int) -> void:
	model.set_weapon(_options[index]["weapon"], int(_options[index]["capacity"]))
	_sync_count()
	_changed()
	station_focused.emit(model.selected)

func _count_changed(value: float) -> void:
	if not _syncing and model != null:
		model.set_weapon(_options[_weapon.selected]["weapon"], int(value))
		_changed()

func _changed() -> void:
	_refresh_stations()
	_update_stats()
	edited.emit()

func _update_stats() -> void:
	var check: Dictionary = model.validation()
	_fuel_text.text = "INTERNAL FUEL  /  %d%%" % roundi(model.fuel)
	var data: Dictionary = check if check.get("ok", false) else model.specs
	_stats.text = "EMPTY  %s KG\nFUEL  %s / %s KG\nPAYLOAD  %s / %s KG\nGUN  %d ROUNDS  /  ALWAYS FULL" % [
		_kg(float(data.get("empty_weight_kg", 0))), _kg(float(data.get("internal_fuel_kg", 0))),
		_kg(float(data.get("max_fuel_kg", 0))), _kg(float(data.get("payload_kg", 0))),
		_kg(float(data.get("max_payload_kg", 0))), int(data.get("gun_rounds", 0))]
	_notice.text = str(check.get("error", "Invalid loadout.")) if not check.get("ok", false) else ""

func _kg(value: float) -> String:
	return str(roundi(value))

func _refresh_presets() -> void:
	_preset_options.clear()
	for title in _presets.names(model.identifier):
		_preset_options.add_item(title)
	_preset_options.disabled = _preset_options.item_count == 0

func _load_preset() -> void:
	if _preset_options.selected < 0:
		return
	var error: String = model.restore(_presets.get_preset(model.identifier, _preset_options.get_item_text(_preset_options.selected)))
	if error.is_empty():
		bind_model(model)
		edited.emit()
	_notice.text = error if not error.is_empty() else "Preset loaded."

func _save_preset() -> void:
	var check: Dictionary = model.validation()
	if not check.get("ok", false):
		_notice.text = check.get("error", "Invalid loadout.")
		return
	var error: String = _presets.save_preset(model.identifier, _preset_name.text, model.snapshot())
	_notice.text = error if not error.is_empty() else "Preset saved."
	_refresh_presets()

func _delete_preset() -> void:
	if _preset_options.selected >= 0:
		_notice.text = _presets.delete_preset(model.identifier, _preset_options.get_item_text(_preset_options.selected))
		_refresh_presets()
