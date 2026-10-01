extends CanvasLayer

# Settings window (RvB style, logs/UI_scheme.md): section tabs on the left, the chosen section's rows on the right.
# Rows are built from controls/settings_schema.gd (via controls.gd SETTINGS), the single source of truth; every
# change goes straight to controls.set_value(). Opened from the home screen, the spawn menu and the Esc key.

const ControlsScript = preload("res://controls.gd")
const Kit := preload("res://ui/ui_kit.gd")
const PANEL_SIZE := Vector2(1320, 840)
const TAB_WIDTH := 270
const KEY_WIDTH := 360
const AMBER := Color("#ffb23d")

var controls: Node = null

var _pages: Dictionary = {}       # section -> VBoxContainer of rows
var _tabs: Dictionary = {}        # section -> tab Button
var _scroll: ScrollContainer = null
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
	var root := Control.new()
	root.theme = Kit.THEME
	root.mouse_filter = Control.MOUSE_FILTER_STOP # no clicks through to the game or menu behind
	add_child(root)
	Kit.fit_to_window(root)
	var dim := ColorRect.new()
	dim.color = Color(0.016, 0.024, 0.051, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var body := Kit.panel(center, "SETTINGS")
	var frame: PanelContainer = body.get_parent().get_parent()
	frame.custom_minimum_size = PANEL_SIZE
	var solid: StyleBoxFlat = Kit.THEME.get_stylebox("panel", "PanelContainer").duplicate()
	solid.bg_color.a = 0.97 # opaque: the menu or game behind would show through the rows
	frame.add_theme_stylebox_override("panel", solid)

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 20)
	body.add_child(cols)
	var tab_col := VBoxContainer.new()
	tab_col.custom_minimum_size = Vector2(TAB_WIDTH, 0)
	tab_col.add_theme_constant_override("separation", 6)
	cols.add_child(tab_col)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cols.add_child(_scroll)
	var pages := VBoxContainer.new()
	pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pages)

	var group := ButtonGroup.new()
	for s in ControlsScript.SETTINGS:
		var sec: String = s.get("section", "General")
		if not _pages.has(sec):
			var page := VBoxContainer.new()
			page.add_theme_constant_override("separation", 10)
			page.visible = _pages.is_empty()
			pages.add_child(page)
			_pages[sec] = page
			var tab := Kit.button(sec.to_upper(), "", _show_section.bind(sec))
			tab.toggle_mode = true
			tab.button_group = group
			tab.button_pressed = page.visible
			tab.alignment = HORIZONTAL_ALIGNMENT_LEFT
			tab_col.add_child(tab)
			_tabs[sec] = tab
		_add_setting_row(_pages[sec], s)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	body.add_child(footer)
	var hint := Kit.label("ESC CLOSES  /  CHANGES SAVE AS YOU MAKE THEM", "DimLabel")
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	footer.add_child(hint)
	footer.add_child(Kit.button("RESET TO DEFAULTS", "", _on_reset_pressed))
	footer.add_child(Kit.button("CLOSE", "RedButton", _on_close_pressed))

func _show_section(sec: String) -> void:
	for k in _pages:
		_pages[k].visible = k == sec
	_scroll.scroll_vertical = 0

func _add_setting_row(page: VBoxContainer, s: Dictionary) -> void:
	var key: String = s["key"]
	var label_text: String = str(s.get("label", key)).to_upper()
	match s.get("type", "string"):
		"float":
			var val: float = float(controls.get_value(key, s.get("default", 0.0)))
			var slider := HSlider.new()
			slider.min_value = float(s.get("min", 0.0))
			slider.max_value = float(s.get("max", 1.0))
			slider.step = float(s.get("step", 0.05))
			slider.value = val
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var val_lbl := Kit.label("%.2f" % val)
			val_lbl.custom_minimum_size = Vector2(70, 0)
			val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			slider.value_changed.connect(func(new_val: float) -> void:
				val_lbl.text = "%.2f" % new_val
				controls.set_value(key, new_val))
			_float_widgets[key] = {"slider": slider, "label": val_lbl}
			var h := HBoxContainer.new()
			h.add_theme_constant_override("separation", 14)
			h.add_child(slider)
			h.add_child(val_lbl)
			Kit.row(page, label_text, h, KEY_WIDTH)
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = bool(controls.get_value(key, s.get("default", false)))
			cb.toggled.connect(func(pressed: bool) -> void: controls.set_value(key, pressed))
			_bool_widgets[key] = cb
			Kit.row(page, label_text, cb, KEY_WIDTH)
		"enum":
			var options: Array = s.get("options", [])
			var names := []
			for o in options:
				names.append(str(o).to_upper())
			var opt := Kit.options(names, maxi(options.find(str(controls.get_value(key, s.get("default", "")))), 0))
			opt.item_selected.connect(func(idx: int) -> void: controls.set_value(key, str(options[idx])))
			_enum_widgets[key] = {"button": opt, "options": options}
			Kit.row(page, label_text, opt, KEY_WIDTH)
		"binding":
			var v := VBoxContainer.new()
			var h := HBoxContainer.new()
			h.add_theme_constant_override("separation", 8)
			v.add_child(h)
			for i in range(1, int(s.get("slots", 2)) + 1):
				var slot_key: String = "bind." + key if i == 1 else "bind%d." % i + key
				var btn := Kit.button(_binding_text(slot_key))
				btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				btn.clip_text = true
				btn.pressed.connect(_on_binding_button_pressed.bind(slot_key, btn))
				_binding_buttons[slot_key] = btn
				h.add_child(btn)
			var conflict := Kit.label("", "DimLabel")
			conflict.add_theme_color_override("font_color", AMBER)
			conflict.visible = false
			v.add_child(conflict)
			_conflict_labels[key] = conflict
			Kit.row(page, label_text, v, KEY_WIDTH)

func _binding_text(slot_key: String) -> String:
	var b: String = ControlsScript.binding_to_readable_string(str(controls.get_value(slot_key, "")))
	return b.to_upper()

func _on_binding_button_pressed(slot_key: String, btn: Button) -> void:
	if not _listening_slot.is_empty():
		_cancel_listening()
	_listening_slot = {"slot_key": slot_key, "button": btn}
	btn.text = "PRESS A KEY / BUTTON  (ESC CANCEL, BACKSPACE CLEAR)"

func _cancel_listening() -> void:
	if _listening_slot.is_empty():
		return
	_listening_slot["button"].text = _binding_text(_listening_slot["slot_key"])
	_listening_slot.clear()

func _finish_listening(new_binding: String) -> void:
	if _listening_slot.is_empty():
		return
	controls.set_value(_listening_slot["slot_key"], new_binding)
	_listening_slot.clear()
	_update_conflict_warnings()

func _input(event: InputEvent) -> void:
	if _listening_slot.is_empty():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_cancel_listening()
		elif event.keycode == KEY_BACKSPACE:
			_finish_listening("")
		else:
			_finish_listening(ControlsScript.event_to_binding_string(event))
		get_viewport().set_input_as_handled()
	elif (event is InputEventMouseButton or event is InputEventJoypadButton) and event.pressed:
		_finish_listening(ControlsScript.event_to_binding_string(event))
		get_viewport().set_input_as_handled()

func _update_conflict_warnings() -> void:
	if controls == null:
		return
	var users: Dictionary = {} # binding string -> labels of the actions using it
	for s in ControlsScript.SETTINGS:
		if s["type"] != "binding":
			continue
		for i in range(1, int(s.get("slots", 2)) + 1):
			var slot_key: String = "bind." + s["key"] if i == 1 else "bind%d." % i + s["key"]
			var b: String = str(controls.get_value(slot_key, ""))
			if b == "":
				continue
			var lbl: String = str(s.get("label", s["key"])).to_upper()
			if not users.has(b):
				users[b] = []
			if not users[b].has(lbl):
				users[b].append(lbl)
	for s in ControlsScript.SETTINGS:
		if s["type"] != "binding" or not _conflict_labels.has(s["key"]):
			continue
		var mine: String = str(s.get("label", s["key"])).to_upper()
		var others: Array = []
		for i in range(1, int(s.get("slots", 2)) + 1):
			var slot_key: String = "bind." + s["key"] if i == 1 else "bind%d." % i + s["key"]
			var b: String = str(controls.get_value(slot_key, ""))
			for o in users.get(b, []) if b != "" else []:
				if o != mine and not others.has(o):
					others.append(o)
		var lbl: Label = _conflict_labels[s["key"]]
		lbl.visible = not others.is_empty()
		lbl.text = "ALSO USED BY: " + ", ".join(others)

func _on_controls_changed(changed_key: String) -> void:
	if changed_key.is_empty(): # reset to defaults: refresh every widget
		for key in _float_widgets:
			var val: float = float(controls.get_value(key, 0.0))
			_float_widgets[key]["slider"].set_value_no_signal(val)
			_float_widgets[key]["label"].text = "%.2f" % val
		for key in _bool_widgets:
			_bool_widgets[key].set_pressed_no_signal(bool(controls.get_value(key, false)))
		for key in _enum_widgets:
			var w: Dictionary = _enum_widgets[key]
			w["button"].select(maxi(w["options"].find(str(controls.get_value(key, ""))), 0))
		for slot_key in _binding_buttons:
			_binding_buttons[slot_key].text = _binding_text(slot_key)
	elif _binding_buttons.has(changed_key):
		_binding_buttons[changed_key].text = _binding_text(changed_key)
	_update_conflict_warnings()

func _on_reset_pressed() -> void:
	if controls != null:
		controls.reset_to_defaults()

func _on_close_pressed() -> void:
	if controls != null:
		controls.toggle_settings()
