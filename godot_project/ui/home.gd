extends Control

# Home screen (main scene): Local (offline event builder), Free Flight (alone on the map), Online (placeholder
# screen), Settings, Quit. Command-line modes
# (tests, benchmark, spectator, AI soak, --mission) skip the menus and start the game directly.
# Features full RvB website visual atmosphere: procedural wireframe terrain flyby, 2D jet dogfights/flybys,
# intro jet merge with sonic boom, tactical HUD frame with rolling compass tape, and subtle logo glitching.

const Kit := preload("res://ui/ui_kit.gd")
const AppState := preload("res://core/app_state.gd")
const HomeTerrain := preload("res://ui/home_terrain.gd")
const HomeFlightFx := preload("res://ui/home_flight_fx.gd")
const HomeHud := preload("res://ui/home_hud.gd")

const GAME_SCENE := "res://main.tscn"
const BUILDER_SCENE := "res://ui/event_builder.tscn"
const ONLINE_SCENE := "res://ui/online.tscn"
const DIRECT_FLAGS := ["--run-tests", "--benchmark", "--ai-player", "--ai-soak", "--ai-arrival", "--mission"]

const MENU_WIDTH := 620
const BUTTON_HEIGHT := 62
const BUTTON_SPACING := 12
const LOGO_LETTER_SIZE := 80
const LOGO_CENTRE_V_SIZE := 52
const SUBTITLE_SIZE := 18

var _controls: Node = null
var _terrain: Control = null
var _flight_fx: Control = null
var _hud: Control = null
var _menu_col: VBoxContainer = null
var _logo_mark: HBoxContainer = null
var _logo_letters: Array[Label] = []
var _body_panel: Control = null

var _intro_done: bool = false
var _glitch_timer: float = 3.5

func _ready() -> void:
	for f in DIRECT_FLAGS:
		if f in OS.get_cmdline_user_args():
			AppState.mode = "free"
			get_tree().change_scene_to_file.call_deferred(GAME_SCENE)
			return
	Kit.make_screen(self)

	# Settings need the controls node, which needs a sim node (left uninitialised: nothing to fly here)
	var sim := YSFlightSimulation.new()
	add_child(sim)
	_controls = preload("res://controls.gd").new()
	_controls.name = "Controls"
	add_child(_controls)
	_controls.setup(null, sim)
	var display: Node = preload("res://display_settings.gd").new()
	add_child(display)
	display.setup(_controls)
	var settings: CanvasLayer = preload("res://settings_panel.gd").new()
	add_child(settings)
	settings.setup(_controls)

	# 1. Wireframe terrain flyby layer
	_terrain = HomeTerrain.new()
	_terrain.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_terrain)

	# 2. 2D Jet flybys & dogfights layer
	_flight_fx = HomeFlightFx.new()
	_flight_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_flight_fx)

	# 3. Tactical HUD overlay (corners, rolling compass tape)
	_hud = HomeHud.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_hud)

	# 4. Main Menu Center Container
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_menu_col = VBoxContainer.new()
	_menu_col.add_theme_constant_override("separation", 28)
	center.add_child(_menu_col)

	# Logo
	_logo_mark = HBoxContainer.new()
	_logo_mark.alignment = BoxContainer.ALIGNMENT_CENTER
	for part in [["R", Kit.RED], ["v", Kit.PALE], ["B", Kit.BLUE]]:
		var l := Kit.label(part[0], "TitleLabel")
		l.add_theme_color_override("font_color", part[1])
		if part[0] == "v":
			l.add_theme_font_size_override("font_size", LOGO_CENTRE_V_SIZE)
		else:
			l.add_theme_font_size_override("font_size", LOGO_LETTER_SIZE)
		_logo_mark.add_child(l)
		_logo_letters.append(l)
	_menu_col.add_child(_logo_mark)

	var sub := Kit.label("YSFLIGHT RVB EDITION", "SectionLabel")
	sub.add_theme_font_size_override("font_size", SUBTITLE_SIZE)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_col.add_child(sub)

	# Main Menu Panel
	_body_panel = Kit.panel(_menu_col, "MAIN MENU")
	_body_panel.custom_minimum_size = Vector2(MENU_WIDTH, 0)
	_body_panel.add_theme_constant_override("separation", BUTTON_SPACING)

	_add_button(_body_panel, "LOCAL", "HomeRedButton", func() -> void:
		get_tree().change_scene_to_file(BUILDER_SCENE))
	_add_button(_body_panel, "FREE FLIGHT", "HomeButton", _free_flight)
	_add_button(_body_panel, "ONLINE", "HomeButton", func() -> void:
		get_tree().change_scene_to_file(ONLINE_SCENE))
	_add_button(_body_panel, "SETTINGS", "HomeBlueButton", func() -> void:
		_controls.toggle_settings(false))
	_add_button(_body_panel, "QUIT", "HomeButton", func() -> void:
		get_tree().quit())

	_start_intro()

func _start_intro() -> void:
	# Initial presentation: menu panel starts slightly faded, logo animates in on jet cross
	_logo_mark.modulate.a = 0.0
	_body_panel.modulate.a = 0.0
	_flight_fx.play_intro(func() -> void:
		_on_intro_merged())

	# Safety fallback in case of frame drop: reveal menu after 2.5s regardless
	get_tree().create_timer(2.5).timeout.connect(func() -> void:
		if not _intro_done:
			_skip_to_menu())

func _on_intro_merged() -> void:
	if _intro_done:
		return
	_intro_done = true

	# Logo pop animation
	_logo_mark.modulate.a = 1.0
	_logo_mark.scale = Vector2(1.35, 1.35)
	_logo_mark.pivot_offset = _logo_mark.size * 0.5
	var tw_logo := create_tween()
	tw_logo.tween_property(_logo_mark, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# Panel smooth reveal
	var tw_panel := create_tween()
	tw_panel.tween_property(_body_panel, "modulate:a", 1.0, 0.40).set_delay(0.20)

func _skip_to_menu() -> void:
	_intro_done = true
	_logo_mark.modulate.a = 1.0
	_logo_mark.scale = Vector2.ONE
	_body_panel.modulate.a = 1.0
	_flight_fx.skip_intro()

func _gui_input(event: InputEvent) -> void:
	if not _intro_done and (event is InputEventKey or event is InputEventMouseButton):
		_skip_to_menu()

func _unhandled_input(event: InputEvent) -> void:
	if not _intro_done and (event is InputEventKey or event is InputEventMouseButton):
		_skip_to_menu()

func _process(delta: float) -> void:
	if not _intro_done:
		return
	_glitch_timer -= delta
	if _glitch_timer <= 0.0:
		_glitch_timer = randf_range(4.0, 8.5)
		_trigger_logo_glitch()

func _trigger_logo_glitch() -> void:
	if _logo_letters.is_empty():
		return
	var l: Label = _logo_letters[randi() % _logo_letters.size()]
	var orig_pos := l.position
	l.position += Vector2(randf_range(-2.0, 2.0), randf_range(-1.5, 1.5))
	l.modulate = Color(1.3, 1.3, 1.5, 1.0)
	get_tree().create_timer(0.22).timeout.connect(func() -> void:
		if is_instance_valid(l):
			l.position = orig_pos
			l.modulate = Color.WHITE)

func _add_button(container: Control, text: String, variation: String, on_press: Callable = Callable()) -> Button:
	var btn := Kit.button(text, variation, on_press)
	btn.custom_minimum_size.y = BUTTON_HEIGHT
	container.add_child(btn)
	return btn

func _free_flight() -> void:
	AppState.mode = "free_flight"
	Kit.show_loading(get_tree(), "FREE FLIGHT", "LUAVI  /  NO OTHER AIRCRAFT")
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().change_scene_to_file(GAME_SCENE)
