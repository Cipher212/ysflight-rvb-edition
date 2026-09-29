extends CanvasLayer
class_name SettingsPanel

# ==============================================================================
# PLACEHOLDER UI, will be replaced by the real menu later;
# draws the Controls.SETTINGS list directly so settings remain the single source of truth.
# ==============================================================================

const ControlsScript = preload("res://controls.gd")

var controls: Node = null

var _panel: PanelContainer = null
var _scroll_vbox: VBoxContainer = null

var _float_widgets: Dictionary = {}
var _bool_widgets: Dictionary = {}
var _enum_widgets: Dictionary = {}
var _binding_buttons: Dictionary = {}
var _conflict_labels: Dictionary = {}

var _listening_slot: Dictionary = {}

func _init() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

func setup(p_controls: Node) -> void:
	controls = p_controls
	controls.set_settings_panel(self)
	controls.changed.connect(_on_controls_changed)
	_build_ui()
	_update_conflict_warnings()

func _build_ui() -> void:
	# Semi-transparent backdrop overlay to prevent clicks leaking
	var backdrop := Control.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	_panel = PanelContainer.new()
	_panel.name = "SettingsPanelContainer"
	# Centred panel container occupying ~70% of the screen
	_panel.anchor_left = 0.15
	_panel.anchor_top = 0.08
	_panel.anchor_right = 0.85
	_panel.anchor_bottom = 0.92
	_panel.offset_left = 0
	_panel.offset_top = 0
	_panel.offset_right = 0
	_panel.offset_bottom = 0
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	_panel.add_child(margin)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 12)
	margin.add_child(root_vbox)

	# --- Header ---
	var header_hbox := HBoxContainer.new()
	var title_lbl := Label.new()
	title_lbl.text = "Flight Controls & Simulation Settings"
	title_lbl.add_theme_font_size_override("font_size", 20)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(title_lbl)

	var esc_hint := Label.new()
	esc_hint.text = "[Esc] / [Pad Start] to Close"
	esc_hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	header_hbox.add_child(esc_hint)
	root_vbox.add_child(header_hbox)

	var sep_top := HSeparator.new()
	root_vbox.add_child(sep_top)

	# --- Scrollable Settings Area ---
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_vbox.add_child(scroll)

	_scroll_vbox = VBoxContainer.new()
	_scroll_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(_scroll_vbox)

	# Populate sections and rows from ControlsScript.SETTINGS
	var current_section: String = ""
	for s in ControlsScript.SETTINGS:
		var sec: String = s.get("section", "General")
		if sec != current_section:
			current_section = sec
			_add_section_header(current_section)

		_add_setting_row(s)

	# --- Footer ---
	var sep_bottom := HSeparator.new()
	root_vbox.add_child(sep_bottom)

	var footer_hbox := HBoxContainer.new()
	footer_hbox.add_theme_constant_override("separation", 16)

	var reset_btn := Button.new()
	reset_btn.text = "Reset to Defaults"
	reset_btn.custom_minimum_size = Vector2(160, 34)
	reset_btn.pressed.connect(_on_reset_pressed)
	footer_hbox.add_child(reset_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_hbox.add_child(spacer)

	var close_btn := Button.new()
	close_btn.text = "Close & Save"
	close_btn.custom_minimum_size = Vector2(140, 34)
	close_btn.pressed.connect(_on_close_pressed)
	footer_hbox.add_child(close_btn)

	root_vbox.add_child(footer_hbox)

func _add_section_header(title: String) -> void:
	var sec_box := VBoxContainer.new()
	sec_box.add_theme_constant_override("separation", 4)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	sec_box.add_child(spacer)

	var lbl := Label.new()
	lbl.text = title.to_upper()
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", Color(0.35, 1.0, 0.45))
	sec_box.add_child(lbl)

	var sep := HSeparator.new()
	sec_box.add_child(sep)

	_scroll_vbox.add_child(sec_box)

func _add_setting_row(s: Dictionary) -> void:
	var key: String = s["key"]
	var label_text: String = s.get("label", key)
	var type: String = s.get("type", "string")

	var row_hbox := HBoxContainer.new()
	row_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_lbl := Label.new()
	name_lbl.text = label_text
	name_lbl.custom_minimum_size = Vector2(240, 0)
	row_hbox.add_child(name_lbl)

	match type:
		"float":
			var val: float = float(controls.get_value(key, s.get("default", 0.0)))
			var slider := HSlider.new()
			slider.min_value = float(s.get("min", 0.0))
			slider.max_value = float(s.get("max", 1.0))
			slider.step = float(s.get("step", 0.05))
			slider.value = val
			slider.custom_minimum_size = Vector2(220, 0)
			slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER

			var val_lbl := Label.new()
			val_lbl.text = "%.2f" % val
			val_lbl.custom_minimum_size = Vector2(50, 0)
			val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

			slider.value_changed.connect(func(new_val: float):
				val_lbl.text = "%.2f" % new_val
				controls.set_value(key, new_val)
			)

			_float_widgets[key] = { "slider": slider, "label": val_lbl }

			var val_hbox := HBoxContainer.new()
			val_hbox.add_theme_constant_override("separation", 10)
			val_hbox.add_child(slider)
			val_hbox.add_child(val_lbl)
			row_hbox.add_child(val_hbox)
			_scroll_vbox.add_child(row_hbox)

		"bool":
			var val: bool = bool(controls.get_value(key, s.get("default", false)))
			var cb := CheckBox.new()
			cb.button_pressed = val
			cb.toggled.connect(func(pressed: bool):
				controls.set_value(key, pressed)
			)
			_bool_widgets[key] = cb
			row_hbox.add_child(cb)
			_scroll_vbox.add_child(row_hbox)

		"enum":
			var val_str: String = str(controls.get_value(key, s.get("default", "")))
			var opt := OptionButton.new()
			var options: Array = s.get("options", [])
			var selected_idx := 0
			for i in range(options.size()):
				var opt_name: String = str(options[i])
				opt.add_item(opt_name, i)
				if opt_name == val_str:
					selected_idx = i

			opt.selected = selected_idx
			opt.item_selected.connect(func(idx: int):
				var choice: String = str(options[idx])
				controls.set_value(key, choice)
			)
			_enum_widgets[key] = opt
			row_hbox.add_child(opt)
			_scroll_vbox.add_child(row_hbox)

		"binding":
			var bind_vbox := VBoxContainer.new()
			bind_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

			var btns_hbox := HBoxContainer.new()
			btns_hbox.add_theme_constant_override("separation", 8)

			var slots: int = s.get("slots", 2)
			for i in range(1, slots + 1):
				var slot_key: String = "bind." + key if i == 1 else "bind%d." % i + key
				var b_str: String = str(controls.get_value(slot_key, ""))

				var btn := Button.new()
				btn.text = ControlsScript.binding_to_readable_string(b_str)
				btn.custom_minimum_size = Vector2(160, 30)
				btn.pressed.connect(_on_binding_button_pressed.bind(slot_key, btn, key))
				_binding_buttons[slot_key] = btn
				btns_hbox.add_child(btn)

			bind_vbox.add_child(btns_hbox)

			# Conflict warning label (orange)
			var conflict_lbl := Label.new()
			conflict_lbl.add_theme_color_override("font_color", Color(1.0, 0.65, 0.1))
			conflict_lbl.add_theme_font_size_override("font_size", 13)
			conflict_lbl.visible = false
			bind_vbox.add_child(conflict_lbl)
			_conflict_labels[key] = conflict_lbl

			row_hbox.add_child(bind_vbox)
			_scroll_vbox.add_child(row_hbox)

func _on_binding_button_pressed(slot_key: String, btn: Button, action_key: String) -> void:
	if not _listening_slot.is_empty():
		_cancel_listening()

	_listening_slot = {
		"slot_key": slot_key,
		"button": btn,
		"action_key": action_key
	}
	btn.text = "Press key / button... (Esc = cancel, Backspace = clear)"

func _cancel_listening() -> void:
	if _listening_slot.is_empty():
		return
	var slot_key: String = _listening_slot["slot_key"]
	var btn: Button = _listening_slot["button"]
	var b_str: String = str(controls.get_value(slot_key, ""))
	btn.text = ControlsScript.binding_to_readable_string(b_str)
	_listening_slot.clear()

func _finish_listening(new_binding: String) -> void:
	if _listening_slot.is_empty():
		return
	var slot_key: String = _listening_slot["slot_key"]
	controls.set_value(slot_key, new_binding)
	_listening_slot.clear()
	_update_conflict_warnings()

func _input(event: InputEvent) -> void:
	if _listening_slot.is_empty():
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_cancel_listening()
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_BACKSPACE:
			_finish_listening("")
			get_viewport().set_input_as_handled()
			return
		else:
			var b := ControlsScript.event_to_binding_string(event)
			_finish_listening(b)
			get_viewport().set_input_as_handled()
			return
	elif event is InputEventMouseButton and event.pressed:
		var b := ControlsScript.event_to_binding_string(event)
		_finish_listening(b)
		get_viewport().set_input_as_handled()
		return
	elif event is InputEventJoypadButton and event.pressed:
		var b := ControlsScript.event_to_binding_string(event)
		_finish_listening(b)
		get_viewport().set_input_as_handled()
		return

func _update_conflict_warnings() -> void:
	if controls == null:
		return

	# Map binding_string -> Array of action labels
	var map: Dictionary = {}
	for s in ControlsScript.SETTINGS:
		if s["type"] != "binding":
			continue
		var act: String = s["key"]
		var slots: int = s.get("slots", 2)
		for i in range(1, slots + 1):
			var slot_key: String = "bind." + act if i == 1 else "bind%d." % i + act
			var b_str: String = str(controls.get_value(slot_key, ""))
			if b_str != "":
				if not map.has(b_str):
					map[b_str] = []
				var lbl_text: String = s.get("label", act)
				if not map[b_str].has(lbl_text):
					map[b_str].append(lbl_text)

	# Now update conflict label for every binding
	for s in ControlsScript.SETTINGS:
		if s["type"] != "binding":
			continue
		var act: String = s["key"]
		if not _conflict_labels.has(act):
			continue
		var conflict_lbl: Label = _conflict_labels[act]
		var my_lbl: String = s.get("label", act)
		var conflicts: Array = []

		var slots: int = s.get("slots", 2)
		for i in range(1, slots + 1):
			var slot_key: String = "bind." + act if i == 1 else "bind%d." % i + act
			var b_str: String = str(controls.get_value(slot_key, ""))
			if b_str != "" and map.has(b_str):
				for other_lbl in map[b_str]:
					if other_lbl != my_lbl and not conflicts.has(other_lbl):
						conflicts.append(other_lbl)

		if conflicts.size() > 0:
			conflict_lbl.text = "Also used by: " + ", ".join(conflicts)
			conflict_lbl.visible = true
		else:
			conflict_lbl.visible = false

func _on_controls_changed(changed_key: String) -> void:
	if changed_key.is_empty():
		# Full reset: refresh all widgets
		for key in _float_widgets:
			var w = _float_widgets[key]
			var val: float = float(controls.get_value(key, 0.0))
			w["slider"].value = val
			w["label"].text = "%.2f" % val
		for key in _bool_widgets:
			_bool_widgets[key].button_pressed = bool(controls.get_value(key, false))
		for key in _enum_widgets:
			var opt: OptionButton = _enum_widgets[key]
			var val_str: String = str(controls.get_value(key, ""))
			for i in range(opt.item_count):
				if opt.get_item_text(i) == val_str:
					opt.selected = i
					break
		for slot_key in _binding_buttons:
			var btn: Button = _binding_buttons[slot_key]
			var b_str: String = str(controls.get_value(slot_key, ""))
			btn.text = ControlsScript.binding_to_readable_string(b_str)
	else:
		if _binding_buttons.has(changed_key):
			var btn: Button = _binding_buttons[changed_key]
			var b_str: String = str(controls.get_value(changed_key, ""))
			btn.text = ControlsScript.binding_to_readable_string(b_str)

	_update_conflict_warnings()

func _on_reset_pressed() -> void:
	if controls != null:
		controls.reset_to_defaults()

func _on_close_pressed() -> void:
	if controls != null:
		controls.toggle_settings()
