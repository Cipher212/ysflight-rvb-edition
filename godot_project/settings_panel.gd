extends CanvasLayer

# Settings window (RvB style, logs/UI_scheme.md): category buttons on the left, subpage navigation and
# scrollable settings rows on the right. Rows are built from controls/settings_schema.gd (via controls.gd SETTINGS),
# the single source of truth; every change goes straight to controls.set_value(). Opened from the home screen,
# the spawn menu and the Esc key.

const ControlsScript = preload("res://controls.gd")
const Kit := preload("res://ui/ui_kit.gd")
const PANEL_SIZE := Vector2(1320, 840)
const TAB_WIDTH := 270
const KEY_WIDTH := 360
const AMBER := Color("#ffb23d")

const CATEGORIES: Array[Dictionary] = [
	{
		"id": "controls",
		"label": "CONTROLS",
		"pages": [
			{"id": "flight_controls", "label": "FLIGHT CONTROLS"},
			{"id": "bindings", "label": "KEY BINDINGS"}
		]
	},
	{
		"id": "display_graphics",
		"label": "DISPLAY & GRAPHICS",
		"pages": [
			{"id": "display", "label": "DISPLAY"},
			{"id": "graphics", "label": "GRAPHICS"}
		]
	},
	{
		"id": "audio",
		"label": "AUDIO",
		"pages": [
			{"id": "audio", "label": "AUDIO"}
		]
	},
	{
		"id": "hud_radar",
		"label": "HUD & RADAR",
		"pages": [
			{"id": "hud", "label": "HUD"},
			{"id": "radar", "label": "RADAR"}
		]
	}
]

const SECTION_TO_PAGE: Dictionary = {
	"Stick Device": "flight_controls",
	"Mouse": "flight_controls",
	"Gamepad": "flight_controls",
	"Joystick / HOTAS": "flight_controls",
	"Keyboard Stick": "flight_controls",
	"Throttle / Afterburner": "flight_controls",
	"Hold vs Toggle": "flight_controls",
	"Bindings": "bindings",
	"Display": "display",
	"Graphics": "graphics",
	"Audio": "audio",
	"HUD": "hud",
	"Radar": "radar"
}

var controls: Node = null

var _category_buttons: Dictionary = {}
var _subnav_groups: Dictionary = {}
var _subnav_buttons: Dictionary = {}
var _page_nodes: Dictionary = {}
var _subnav_row: HBoxContainer = null
var _scroll: ScrollContainer = null
var _close_button: Button = null
var _reset_button: Button = null
var _current_category: String = ""
var _current_subpage: String = ""

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
	visibility_changed.connect(_on_visibility_changed)
	_build_ui()
	_update_conflict_warnings()

func _on_visibility_changed() -> void:
	if not visible:
		_cancel_listening()

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
	solid.bg_color.a = 1.0 # opaque: the menu or game behind would show through the rows
	frame.add_theme_stylebox_override("panel", solid)

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 20)
	body.add_child(cols)

	var tab_col := VBoxContainer.new()
	tab_col.custom_minimum_size = Vector2(TAB_WIDTH, 0)
	tab_col.add_theme_constant_override("separation", 8)
	cols.add_child(tab_col)

	var content_col := VBoxContainer.new()
	content_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_col.add_theme_constant_override("separation", 12)
	cols.add_child(content_col)

	_subnav_row = HBoxContainer.new()
	_subnav_row.add_theme_constant_override("separation", 8)
	content_col.add_child(_subnav_row)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content_col.add_child(_scroll)

	var pages_holder := VBoxContainer.new()
	pages_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pages_holder)

	var cat_group := ButtonGroup.new()
	for cat in CATEGORIES:
		var cid: String = cat["id"]
		var cbtn := Kit.button(cat["label"], "", _on_category_pressed.bind(cid))
		cbtn.toggle_mode = true
		cbtn.button_group = cat_group
		cbtn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		cbtn.custom_minimum_size = Vector2(TAB_WIDTH, 48)
		tab_col.add_child(cbtn)
		_category_buttons[cid] = cbtn

		var pages_list: Array = cat["pages"]
		if pages_list.size() > 1:
			var sub_box := HBoxContainer.new()
			sub_box.add_theme_constant_override("separation", 8)
			_subnav_row.add_child(sub_box)
			_subnav_groups[cid] = sub_box
			var sub_group := ButtonGroup.new()
			for p in pages_list:
				var pid: String = p["id"]
				var sbtn := Kit.button(p["label"], "", _on_subpage_pressed.bind(cid, pid))
				sbtn.toggle_mode = true
				sbtn.button_group = sub_group
				sbtn.custom_minimum_size = Vector2(160, 38)
				sub_box.add_child(sbtn)
				_subnav_buttons[pid] = sbtn
		else:
			_subnav_groups[cid] = null

		for p in pages_list:
			var pid: String = p["id"]
			var page := VBoxContainer.new()
			page.add_theme_constant_override("separation", 10)
			page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			page.visible = false
			pages_holder.add_child(page)
			_page_nodes[pid] = page

	var last_flight_sec: String = ""
	for s in ControlsScript.SETTINGS:
		var sec: String = s.get("section", "General")
		var pid: String = SECTION_TO_PAGE.get(sec, "flight_controls")
		var page: VBoxContainer = _page_nodes.get(pid, _page_nodes["flight_controls"])
		if pid == "flight_controls":
			if sec != last_flight_sec:
				_add_group_heading(page, sec, last_flight_sec == "")
				last_flight_sec = sec
		_add_setting_row(page, s)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	body.add_child(footer)
	var hint := Kit.label("ESC CLOSES  /  CHANGES SAVE AS YOU MAKE THEM", "DimLabel")
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	footer.add_child(hint)
	_reset_button = Kit.button("RESET TO DEFAULTS", "", _on_reset_pressed)
	footer.add_child(_reset_button)
	_close_button = Kit.button("CLOSE", "RedButton", _on_close_pressed)
	footer.add_child(_close_button)

	_select_category("controls")

func _add_group_heading(page: VBoxContainer, title: String, is_first: bool) -> void:
	if not is_first:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, 8)
		page.add_child(spacer)
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(Kit.label(title.to_upper(), "SectionLabel"))
	head.add_child(HSeparator.new())
	page.add_child(head)

func _on_category_pressed(cid: String) -> void:
	_select_category(cid)

func _on_subpage_pressed(cid: String, pid: String) -> void:
	_select_subpage(cid, pid)

func _select_category(cid: String) -> void:
	_cancel_listening()
	_current_category = cid
	if _category_buttons.has(cid):
		_category_buttons[cid].button_pressed = true

	var has_subnav: bool = false
	for id in _subnav_groups:
		var group: Control = _subnav_groups[id]
		if group != null:
			group.visible = (id == cid)
			if id == cid:
				has_subnav = true
	_subnav_row.visible = has_subnav

	var target_pid: String = ""
	for cat in CATEGORIES:
		if cat["id"] == cid:
			target_pid = cat["pages"][0]["id"]
			break
	if target_pid != "":
		_select_subpage(cid, target_pid)

func _select_subpage(cid: String, pid: String) -> void:
	_cancel_listening()
	_current_category = cid
	_current_subpage = pid
	if _subnav_buttons.has(pid):
		_subnav_buttons[pid].button_pressed = true
	for id in _page_nodes:
		_page_nodes[id].visible = (id == pid)
	if _scroll != null:
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
			var h := HBoxContainer.new()
			h.add_theme_constant_override("separation", 14)
			h.add_child(slider)
			if bool(s.get("field", false)): # typed value next to the slider (e.g. volumes 0.00 - 1.00)
				var field := LineEdit.new()
				field.text = "%.2f" % val
				field.custom_minimum_size = Vector2(110, 0)
				field.alignment = HORIZONTAL_ALIGNMENT_RIGHT
				field.select_all_on_focus = true
				slider.value_changed.connect(func(new_val: float) -> void:
					field.text = "%.2f" % new_val
					controls.set_value(key, new_val))
				# Typed value: clamped to the slider's range; anything that is not a number puts the old value back
				var commit := func(_t: String = "") -> void:
					var typed := field.text.strip_edges()
					if typed.is_valid_float():
						slider.value = clampf(snappedf(typed.to_float(), slider.step), slider.min_value, slider.max_value)
					field.text = "%.2f" % slider.value
				field.text_submitted.connect(commit)
				field.focus_exited.connect(commit)
				_float_widgets[key] = {"slider": slider, "field": field}
				h.add_child(field)
			else:
				var val_lbl := Kit.label("%.2f" % val)
				val_lbl.custom_minimum_size = Vector2(70, 0)
				val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				slider.value_changed.connect(func(new_val: float) -> void:
					val_lbl.text = "%.2f" % new_val
					controls.set_value(key, new_val))
				_float_widgets[key] = {"slider": slider, "label": val_lbl}
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
	var btn: Button = _listening_slot.get("button", null)
	if btn != null and is_instance_valid(btn):
		btn.text = _binding_text(_listening_slot["slot_key"])
	_listening_slot.clear()

func _finish_listening(new_binding: String) -> void:
	if _listening_slot.is_empty():
		return
	controls.set_value(_listening_slot["slot_key"], new_binding)
	_listening_slot.clear()
	_update_conflict_warnings()

func _is_mouse_over_control(control: Control, viewport_pos: Vector2) -> bool:
	if control == null or not is_instance_valid(control) or not control.is_inside_tree() or not control.is_visible_in_tree():
		return false
	var xform: Transform2D = control.get_global_transform_with_canvas()
	if is_zero_approx(xform.determinant()):
		return false
	var local_pos: Vector2 = xform.affine_inverse() * viewport_pos
	return Rect2(Vector2.ZERO, control.size).has_point(local_pos)

func _get_navigation_buttons() -> Array[Button]:
	var list: Array[Button] = []
	for btn in _category_buttons.values():
		if btn is Button:
			list.append(btn)
	for btn in _subnav_buttons.values():
		if btn is Button:
			list.append(btn)
	if _close_button != null:
		list.append(_close_button)
	if _reset_button != null:
		list.append(_reset_button)
	var current_btn: Button = _listening_slot.get("button", null)
	for btn in _binding_buttons.values():
		if btn is Button and btn != current_btn:
			list.append(btn)
	return list

func _is_mouse_over_navigation_button(viewport_pos: Vector2) -> bool:
	for btn: Button in _get_navigation_buttons():
		if not is_instance_valid(btn) or not btn.is_inside_tree() or not btn.is_visible_in_tree() or btn.disabled:
			continue
		if _scroll != null and is_instance_valid(_scroll) and _scroll.is_ancestor_of(btn):
			if not _is_mouse_over_control(_scroll, viewport_pos):
				continue
		var xform: Transform2D = btn.get_global_transform_with_canvas()
		if is_zero_approx(xform.determinant()):
			continue
		var local_pos: Vector2 = xform.affine_inverse() * viewport_pos
		if Rect2(Vector2.ZERO, btn.size).has_point(local_pos):
			return true
	return false

func _input(event: InputEvent) -> void:
	if not visible or _listening_slot.is_empty():
		return
	var b_page: Control = _page_nodes.get("bindings")
	if b_page == null or not b_page.is_visible_in_tree():
		_cancel_listening()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _is_mouse_over_navigation_button(event.position):
			_cancel_listening()
			return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_cancel_listening()
		elif event.keycode == KEY_BACKSPACE:
			_finish_listening("")
		else:
			_finish_listening(ControlsScript.event_to_binding_string(event))
		var vp := get_viewport()
		if vp != null:
			vp.set_input_as_handled()
	elif (event is InputEventMouseButton or event is InputEventJoypadButton) and event.pressed:
		_finish_listening(ControlsScript.event_to_binding_string(event))
		var vp := get_viewport()
		if vp != null:
			vp.set_input_as_handled()

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
			var w: Dictionary = _float_widgets[key]
			w["slider"].set_value_no_signal(val)
			if w.has("field"):
				w["field"].text = "%.2f" % val
			else:
				w["label"].text = "%.2f" % val
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
	_cancel_listening()
	if controls != null:
		controls.reset_to_defaults()

func _on_close_pressed() -> void:
	_cancel_listening()
	if controls != null:
		controls.toggle_settings()
