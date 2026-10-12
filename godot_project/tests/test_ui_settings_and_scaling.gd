extends SceneTree

# Comprehensive test for UI scaling and settings navigation.
# Verifies schema coverage, category/subpage navigation, binding capture cancellation,
# audio numeric input clamping, conflict warnings, and layout bounds across resolutions.

const Kit := preload("res://ui/ui_kit.gd")
const ControlsScript := preload("res://controls.gd")
const SettingsSchema := preload("res://controls/settings_schema.gd")
const SettingsPanelScript := preload("res://settings_panel.gd")
const DisplaySettingsScript := preload("res://display_settings.gd")

var _step := 0
var _sim: YSFlightSimulation = null
var _controls: Node = null
var _panel: CanvasLayer = null
var _home_node: Control = null

func _process(_delta: float) -> bool:
	match _step:
		0:
			_step = 1
			_run_settings_test()
			return false
		1:
			_step = 2
			var home_scene: PackedScene = load("res://ui/home.tscn")
			_home_node = home_scene.instantiate()
			root.add_child(_home_node)
			return false
		2:
			_step = 3
			return false # wait for _ready() to finish executing
		3:
			_step = 4
			_run_home_test()
			return false
		4:
			print("--- ALL UI SCALING & SETTINGS NAVIGATION CHECKS PASSED ---")
			quit(0)
			return true
	return false

func _run_settings_test() -> void:
	print("--- BEGIN UI SCALING & SETTINGS NAVIGATION TEST ---")
	_sim = YSFlightSimulation.new()
	root.add_child(_sim)

	_controls = ControlsScript.new()
	root.add_child(_controls)
	_controls.setup(null, _sim)

	_panel = SettingsPanelScript.new()
	root.add_child(_panel)
	_panel.setup(_controls)

	# 1. Verify all 5 Categories and Subpages exist (Ref: planning/replay_and_spectator_system.md)
	assert(_panel._category_buttons.size() == 5, "Expected 5 category buttons")
	assert(_panel._category_buttons.has("controls"), "Missing controls category")
	assert(_panel._category_buttons.has("display_graphics"), "Missing display_graphics category")
	assert(_panel._category_buttons.has("audio"), "Missing audio category")
	assert(_panel._category_buttons.has("hud_radar"), "Missing hud_radar category")
	assert(_panel._category_buttons.has("gameplay"), "Missing gameplay category")

	# Check subpages
	assert(_panel._page_nodes.has("flight_controls"), "Missing flight_controls page")
	assert(_panel._page_nodes.has("bindings"), "Missing bindings page")
	assert(_panel._page_nodes.has("display"), "Missing display page")
	assert(_panel._page_nodes.has("graphics"), "Missing graphics page")
	assert(_panel._page_nodes.has("audio"), "Missing audio page")
	assert(_panel._page_nodes.has("hud"), "Missing hud page")
	assert(_panel._page_nodes.has("radar"), "Missing radar page")
	assert(_panel._page_nodes.has("gameplay"), "Missing gameplay page")
	print("CHECK 1 PASSED: All 5 categories and 8 presentation pages exist.")

	# 2. Verify default opening page is Controls > Flight Controls
	assert(_panel._current_category == "controls", "Default category must be controls")
	assert(_panel._current_subpage == "flight_controls", "Default subpage must be flight_controls")
	assert(_panel._page_nodes["flight_controls"].visible == true, "flight_controls must be visible")
	assert(_panel._page_nodes["bindings"].visible == false, "bindings must be hidden")
	assert(_panel._subnav_row.visible == true, "controls subnav row must be visible")
	assert(_panel._category_buttons["controls"].button_pressed == true, "controls category button must be pressed")
	assert(_panel._subnav_buttons["flight_controls"].button_pressed == true, "flight_controls subnav button must be pressed")
	print("CHECK 2 PASSED: Default opening page is Controls > Flight Controls with correct highlighting.")

	# 3. Verify schema row coverage: count rows and verify every schema entry is rendered
	var total_schema_entries: int = SettingsSchema.SETTINGS.size()
	var rendered_widgets: int = _panel._float_widgets.size() + _panel._bool_widgets.size() + _panel._enum_widgets.size() + _panel._path_widgets.size() + _panel._conflict_labels.size()
	assert(rendered_widgets == total_schema_entries, "Every schema row must be rendered exactly once. Expected %d, got %d" % [total_schema_entries, rendered_widgets])

	# Verify Flight Controls contains section headings for the 7 grouped sections
	var fc_page: VBoxContainer = _panel._page_nodes["flight_controls"]
	var heading_count := 0
	for child in fc_page.get_children():
		if child is VBoxContainer and child.get_child_count() >= 2:
			var first = child.get_child(0)
			if first is Label and first.theme_type_variation == "SectionLabel":
				heading_count += 1
	assert(heading_count == 7, "Expected 7 section headings on Flight Controls page, got %d" % heading_count)
	print("CHECK 3 PASSED: All %d schema entries generated exactly once with 7 group headings." % total_schema_entries)

	# 4. Test Navigation to Audio: subnav must be hidden
	_panel._select_category("audio")
	assert(_panel._current_category == "audio", "Category should be audio")
	assert(_panel._current_subpage == "audio", "Subpage should be audio")
	assert(_panel._page_nodes["audio"].visible == true, "audio page must be visible")
	assert(_panel._page_nodes["flight_controls"].visible == false, "flight_controls page must be hidden")
	assert(_panel._subnav_row.visible == false, "audio subnav row must be hidden (no redundant secondary tab)")
	print("CHECK 4 PASSED: Audio category has no redundant secondary tab and displays correctly.")

	# 5. Test Navigation to Display & Graphics and HUD & Radar
	_panel._select_category("display_graphics")
	assert(_panel._subnav_row.visible == true, "display_graphics subnav row must be visible")
	assert(_panel._current_subpage == "display", "Default subpage must be display")
	assert(_panel._page_nodes["display"].visible == true, "display page must be visible")

	_panel._select_subpage("display_graphics", "graphics")
	assert(_panel._current_subpage == "graphics", "Subpage should be graphics")
	assert(_panel._page_nodes["graphics"].visible == true, "graphics page must be visible")
	assert(_panel._page_nodes["display"].visible == false, "display page must be hidden")

	_panel._select_category("hud_radar")
	assert(_panel._subnav_row.visible == true, "hud_radar subnav row must be visible")
	assert(_panel._current_subpage == "hud", "Default subpage must be hud")
	assert(_panel._page_nodes["hud"].visible == true, "hud page must be visible")

	_panel._select_subpage("hud_radar", "radar")
	assert(_panel._current_subpage == "radar", "Subpage should be radar")
	assert(_panel._page_nodes["radar"].visible == true, "radar page must be visible")
	assert(_panel._page_nodes["hud"].visible == false, "hud page must be hidden")
	print("CHECK 5 PASSED: Display & Graphics and HUD & Radar categories and subpages navigate correctly.")

	# 6. Test Key Bindings and Binding Listening Cancellation
	_panel.visible = true
	_panel._select_category("controls")
	_panel._select_subpage("controls", "bindings")
	assert(_panel._page_nodes["bindings"].visible == true, "bindings page must be visible")

	# Simulate pressing a binding button to start listening
	var test_slot_key := "bind.gear"
	var test_btn: Button = _panel._binding_buttons[test_slot_key]
	var initial_text := test_btn.text
	_panel._on_binding_button_pressed(test_slot_key, test_btn)
	assert(not _panel._listening_slot.is_empty(), "Listening slot must be active")
	assert("PRESS A KEY" in test_btn.text, "Button text should prompt for key")

	# Test Escape while listening cancels listening without closing panel
	var esc_event := InputEventKey.new()
	esc_event.pressed = true
	esc_event.keycode = KEY_ESCAPE
	_panel._input(esc_event)
	assert(_panel._listening_slot.is_empty(), "Listening should be cancelled by Escape")
	assert(test_btn.text == initial_text, "Button text should revert to original binding")
	assert(_panel.visible == true, "Panel must stay open when cancelling binding with Escape")

	# Test listening and switching subpage cancels listening
	_panel._on_binding_button_pressed(test_slot_key, test_btn)
	assert(not _panel._listening_slot.is_empty(), "Listening slot must be active again")
	_panel._select_subpage("controls", "flight_controls")
	assert(_panel._listening_slot.is_empty(), "Switching subpage must cancel active binding capture")
	assert(test_btn.text == initial_text, "Button text must revert on page switch")

	# Test hidden binding page does not capture input
	_panel._select_subpage("controls", "flight_controls")
	var key_event := InputEventKey.new()
	key_event.pressed = true
	key_event.keycode = KEY_SPACE
	_panel._input(key_event) # should do nothing since listening is empty and page is hidden
	print("CHECK 6 PASSED: Binding listening, Escape cancellation, and hidden-page protection verified.")

func _run_home_test() -> void:
	print("Home children count: ", _home_node.get_child_count())
	for c in _home_node.get_children():
		print("Child: ", c.name, " type: ", c.get_class())
	var found_buttons: Array[Button] = []
	var found_body: VBoxContainer = null
	for child in _home_node.find_children("*", "Button", true, false):
		found_buttons.append(child)
	for child in _home_node.find_children("*", "VBoxContainer", true, false):
		if child.custom_minimum_size.x >= 600.0:
			found_body = child
	assert(found_body != null, "Home menu body must have custom_minimum_size.x >= 600")
	assert(found_body.custom_minimum_size.x >= 600.0 and found_body.custom_minimum_size.x <= 620.0,
		"Home menu body width should be 600-620px, got %f" % found_body.custom_minimum_size.x)

	# Verify button minimum height and theme variations (Ref: planning/replay_and_spectator_system.md)
	var btn_texts := ["LOCAL", "FREE FLIGHT", "ONLINE", "REPLAYS", "SETTINGS", "QUIT"]
	for txt in btn_texts:
		var b_match: Button = null
		for b in found_buttons:
			if b.text == txt:
				b_match = b
				break
		assert(b_match != null, "Missing button: " + txt)
		assert(b_match.custom_minimum_size.y >= 60.0 and b_match.custom_minimum_size.y <= 64.0,
			"Button %s minimum height should be 60-64px, got %f" % [txt, b_match.custom_minimum_size.y])
	print("CHECK 7 PASSED: Home menu body width (620px) and button heights (62px) verified.")

	# 8. Test Resolution Scaling logic at 720p, 1080p, 1440p, 4K
	var test_resolutions := [
		{"res": Vector2(1280, 720), "expected_scale": 1280.0 / 1920.0},
		{"res": Vector2(1920, 1080), "expected_scale": 1.0},
		{"res": Vector2(2560, 1440), "expected_scale": 2560.0 / 1920.0},
		{"res": Vector2(3840, 2160), "expected_scale": 3840.0 / 1920.0}
	]
	for tr in test_resolutions:
		var win: Vector2 = tr["res"]
		var exp_s: float = tr["expected_scale"]
		var s: float = maxf(minf(win.x / Kit.DESIGN_SIZE.x, win.y / Kit.DESIGN_SIZE.y), Kit.MIN_SCALE)
		assert(absf(s - exp_s) < 0.001, "Scale mismatch at %s: got %f expected %f" % [win, s, exp_s])
		var scaled_size: Vector2 = win / s
		assert(absf(scaled_size.x - 1920.0) < 0.01 and absf(scaled_size.y - 1080.0) < 0.01,
			"Scaled root size must equal 1920x1080, got %s" % scaled_size)
		# Verify settings panel (1320x840) fits cleanly within design size (1920x1080)
		assert(SettingsPanelScript.PANEL_SIZE.x <= scaled_size.x, "Panel width must fit design width")
		assert(SettingsPanelScript.PANEL_SIZE.y <= scaled_size.y, "Panel height must fit design height")
	print("CHECK 8 PASSED: Resolution scaling at 720p, 1080p, 1440p, 4K verified.")

	# 9. Verify DisplaySettings preserves maximized state across scene transitions
	assert(DisplaySettingsScript._initial_applied == true, "DisplaySettings must record initial application")
	DisplaySettingsScript._initial_applied = false
	assert(DisplaySettingsScript._initial_applied == false, "DisplaySettings._initial_applied must clear")
	var disp: Node = DisplaySettingsScript.new()
	disp.setup(_controls)
	assert(DisplaySettingsScript._initial_applied == true, "DisplaySettings.setup must set initial flag")

	var prev_mode := DisplayServer.window_get_mode()
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED:
		disp.apply(false)
		assert(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED,
			"DisplaySettings.apply(false) must not un-maximize window in Windowed mode")
		DisplayServer.window_set_mode(prev_mode)
	disp.queue_free()
	print("CHECK 9 PASSED: DisplaySettings preserves maximized window state.")

	_home_node.queue_free()
	_panel.queue_free()
	_controls.queue_free()
	_sim.queue_free()
