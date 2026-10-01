extends Control

# Home screen (main scene): Local (offline event builder), Free Flight (alone on the map), Online (placeholder
# screen), Settings, Quit. Command-line modes
# (tests, benchmark, spectator, AI soak, --mission) skip the menus and start the game directly.

const Kit := preload("res://ui/ui_kit.gd")
const AppState := preload("res://core/app_state.gd")
const GAME_SCENE := "res://main.tscn"
const BUILDER_SCENE := "res://ui/event_builder.tscn"
const ONLINE_SCENE := "res://ui/online.tscn"
const DIRECT_FLAGS := ["--run-tests", "--benchmark", "--ai-player", "--ai-soak", "--mission"]

var _controls: Node = null

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
	_controls.setup(null, sim) # no game here: controls skip camera / flight actions
	var settings: CanvasLayer = preload("res://settings_panel.gd").new()
	add_child(settings)
	settings.setup(_controls)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 28)
	center.add_child(col)

	var mark := HBoxContainer.new()
	mark.alignment = BoxContainer.ALIGNMENT_CENTER
	for part in [["R", Kit.RED], ["v", Color.WHITE], ["B", Kit.BLUE]]:
		var l := Kit.label(part[0], "TitleLabel")
		l.add_theme_color_override("font_color", part[1])
		if part[0] == "v":
			l.add_theme_font_size_override("font_size", 40)
		mark.add_child(l)
	col.add_child(mark)
	var sub := Kit.label("YSFLIGHT RVB EDITION", "SectionLabel")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(sub)

	var body := Kit.panel(col, "MAIN MENU")
	body.custom_minimum_size = Vector2(420, 0)
	body.add_child(Kit.button("LOCAL", "RedButton", func() -> void:
		get_tree().change_scene_to_file(BUILDER_SCENE)))
	body.add_child(Kit.button("FREE FLIGHT", "", _free_flight))
	body.add_child(Kit.button("ONLINE", "", func() -> void: get_tree().change_scene_to_file(ONLINE_SCENE)))
	body.add_child(Kit.button("SETTINGS", "BlueButton", func() -> void: _controls.toggle_settings(false)))
	body.add_child(Kit.button("QUIT", "", func() -> void: get_tree().quit()))

func _free_flight() -> void:
	AppState.mode = "free_flight"
	Kit.show_loading(get_tree(), "FREE FLIGHT", "LUAVI  /  NO OTHER AIRCRAFT")
	await get_tree().process_frame # let the loading screen draw before the map load blocks
	await get_tree().process_frame
	get_tree().change_scene_to_file(GAME_SCENE)
