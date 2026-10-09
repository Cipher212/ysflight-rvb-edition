extends Node
# Respawn + flight setup for the classic free play (command-line modes; events and free flight use
# ui/preflight_flow.gd)
# - Automatic respawn: RESPAWN_DELAY seconds after the player dies, a new aircraft of the selected type is
#   placed at a start position (.stp) of the selected team: "Random" picks any [IFF1]/[IFF4] start of that
#   team, skipping "(HELI ONLY)" spots for fixed-wing aircraft. Disabled in benchmark mode so benchmark
#   runs stay comparable with older baselines.
# - F10 opens the flight-setup panel (aircraft, team, start position, respawn now), RvB style (ui/ui_kit.gd).
#   C++ calls: get_airplane_template_names(), get_start_position_names(), is_helicopter_template(),
#   respawn_player().
# Notes: logs/phase6_gameplay_log.md

const Kit := preload("res://ui/ui_kit.gd")
const RESPAWN_DELAY: float = 5.0
const TEAMS: Array[Dictionary] = [
	{"label": "BLUE (IFF1)", "iff": 0},
	{"label": "RED (IFF4)", "iff": 3},
]

var main: Node = null
var sim: YSFlightSimulation = null

var selected_aircraft: String = ""
var selected_team: int = 0          # index into TEAMS
var selected_start: String = "Random"
var auto_respawn: bool = true

var _dead_time: float = 0.0
var _rng := RandomNumberGenerator.new()

var _layer: CanvasLayer = null
var _aircraft_opt: OptionButton = null
var _team_opt: OptionButton = null
var _start_opt: OptionButton = null
var _aircraft_names: PackedStringArray = PackedStringArray()
var _paused_before: bool = false

func setup(p_main: Node, p_sim: YSFlightSimulation) -> void:
	main = p_main
	sim = p_sim
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	var tel: Dictionary = sim.get_player_telemetry()
	selected_aircraft = str(tel.get("identifier", ""))
	selected_team = 1 if int(tel.get("iff", 0)) == 3 else 0
	# Off in benchmarks (comparable runs), arrival tests (a lost jet is a result) and in offline events (the
	# event's spawn menu takes over)
	auto_respawn = not bool(main.get("benchmark_mode")) and not bool(main.get("arrival_test_mode")) and not _menus_spawn()
	_build_panel()

func _process(delta: float) -> void:
	if sim == null or get_tree().paused or not auto_respawn:
		return
	var tel: Dictionary = sim.get_player_telemetry()
	if bool(tel.get("is_alive", true)):
		_dead_time = 0.0
		return
	_dead_time += delta
	if _dead_time >= RESPAWN_DELAY:
		_dead_time = 0.0
		respawn()

# Places a new player aircraft. Returns false if nothing suitable was found.
func respawn() -> bool:
	var iff: int = int(TEAMS[selected_team]["iff"])
	var stp: String = _pick_start_position(iff)
	if stp == "" or selected_aircraft == "":
		push_warning("Respawn: no aircraft or start position (aircraft=%s)" % selected_aircraft)
		return false
	if not sim.respawn_player(selected_aircraft, stp, iff):
		return false
	if bool(main.get("ai_player_mode")):
		sim.enable_player_autopilot()
	main.camera_rig.reset_for_new_aircraft()
	return true

func _pick_start_position(iff: int) -> String:
	var tag: String = "[IFF%d]" % (iff + 1)
	var heli: bool = sim.is_helicopter_template(selected_aircraft)
	var candidates: PackedStringArray = PackedStringArray()
	for n in sim.get_start_position_names():
		if not n.begins_with(tag):
			continue
		if n.contains("HELI") and not heli:
			continue
		candidates.append(n)
	if selected_start != "Random" and candidates.has(selected_start):
		return selected_start
	if candidates.is_empty():
		return ""
	return candidates[_rng.randi_range(0, candidates.size() - 1)]

# ------------------------------------------------------------------------------
# Placeholder panel (F10)
# ------------------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F10 			and not _menus_spawn():
		_set_panel_visible(not _layer.visible)
		get_viewport().set_input_as_handled()

# Events and Free Flight spawn the player through ui/preflight_flow.gd.
func _menus_spawn() -> bool:
	return bool(main.get("event_mode")) or bool(main.get("free_flight_mode"))

func _set_panel_visible(v: bool) -> void:
	_layer.visible = v
	if v:
		_paused_before = get_tree().paused
		get_tree().paused = true
		_refresh_start_options()
	else:
		get_tree().paused = _paused_before

func _build_panel() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 99
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_layer.visible = false
	add_child(_layer)
	var root := Control.new()
	root.theme = Kit.THEME
	_layer.add_child(root)
	Kit.fit_to_window(root)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var box := Kit.panel(center, "FLIGHT SETUP  /  F10")
	box.custom_minimum_size = Vector2(760, 0)

	# RvB aircraft are named "<TYPE>(BLUE/...)" or "<TYPE>(RED/...)"; show only those if any exist
	for n in sim.get_airplane_template_names():
		if n.contains("(BLUE/") or n.contains("(RED/"):
			_aircraft_names.append(n)
	if _aircraft_names.is_empty():
		_aircraft_names = sim.get_airplane_template_names()
	_aircraft_opt = Kit.options(Array(_aircraft_names), maxi(_aircraft_names.find(selected_aircraft), 0))
	_aircraft_opt.item_selected.connect(_on_aircraft_selected)
	Kit.row(box, "AIRCRAFT", _aircraft_opt)

	var team_labels := []
	for t in TEAMS:
		team_labels.append(t["label"])
	_team_opt = Kit.options(team_labels, selected_team)
	_team_opt.item_selected.connect(func(i: int) -> void:
		selected_team = i
		_refresh_start_options())
	Kit.row(box, "TEAM", _team_opt)

	_start_opt = Kit.options(["RANDOM"])
	_start_opt.item_selected.connect(func(i: int) -> void:
		selected_start = "Random" if i == 0 else _start_opt.get_item_text(i))
	Kit.row(box, "START", _start_opt)

	var auto := CheckBox.new()
	auto.text = "AUTOMATIC RESPAWN (%.0f S AFTER DEATH)" % RESPAWN_DELAY
	auto.button_pressed = auto_respawn
	auto.toggled.connect(func(on: bool) -> void: auto_respawn = on)
	box.add_child(auto)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	box.add_child(buttons)
	var respawn_btn := Kit.button("RESPAWN NOW", "RedButton", func() -> void:
		_set_panel_visible(false)
		respawn())
	respawn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(respawn_btn)
	buttons.add_child(Kit.button("CLOSE", "", func() -> void: _set_panel_visible(false)))

func _on_aircraft_selected(i: int) -> void:
	selected_aircraft = _aircraft_names[i]
	# Team follows the RvB naming convention when it is obvious
	if selected_aircraft.contains("(RED/"):
		selected_team = 1
	elif selected_aircraft.contains("(BLUE/"):
		selected_team = 0
	_team_opt.select(selected_team)
	_refresh_start_options()

func _refresh_start_options() -> void:
	var tag: String = "[IFF%d]" % (int(TEAMS[selected_team]["iff"]) + 1)
	var heli: bool = sim.is_helicopter_template(selected_aircraft)
	_start_opt.clear()
	_start_opt.add_item("RANDOM")
	for n in sim.get_start_position_names():
		if n.begins_with(tag) and (heli or not n.contains("HELI")):
			_start_opt.add_item(n)
	selected_start = "Random"
	_start_opt.select(0)
