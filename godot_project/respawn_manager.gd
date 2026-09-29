extends Node
# ==============================================================================
# Respawn + flight setup (PLACEHOLDER UI)
# ==============================================================================
# - Automatic respawn: RESPAWN_DELAY seconds after the player dies, a new aircraft of the selected type is
#   placed at a start position (.stp) of the selected team: "Random" picks any [IFF1]/[IFF4] start of that
#   team, skipping "(HELI ONLY)" spots for fixed-wing aircraft. Disabled in benchmark mode so benchmark
#   runs stay comparable with older baselines.
# - F10 opens a placeholder flight-setup panel (aircraft, team, start position, respawn now). It will be
#   replaced by the real menu/lobby, which should call the same C++ functions:
#   get_airplane_template_names(), get_start_position_names(), is_helicopter_template(), respawn_player().
# Notes: logs/phase6_gameplay_log.md
# ==============================================================================

const RESPAWN_DELAY: float = 5.0
const TEAMS: Array[Dictionary] = [
	{"label": "IFF1 (Blue)", "iff": 0},
	{"label": "IFF4 (Red)", "iff": 3},
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
	auto_respawn = not bool(main.get("benchmark_mode"))
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
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F10:
		_set_panel_visible(not _layer.visible)
		get_viewport().set_input_as_handled()

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

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(460, 0)
	panel.position = Vector2(-230, -150)
	_layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)

	var title := Label.new()
	title.text = "FLIGHT SETUP (placeholder, F10)"
	box.add_child(title)

	# RvB aircraft are named "<TYPE>(BLUE/...)" or "<TYPE>(RED/...)"; show only those if any exist
	for n in sim.get_airplane_template_names():
		if n.contains("(BLUE/") or n.contains("(RED/"):
			_aircraft_names.append(n)
	if _aircraft_names.is_empty():
		_aircraft_names = sim.get_airplane_template_names()
	_aircraft_opt = _add_option(box, "Aircraft", _aircraft_names)
	var cur: int = _aircraft_names.find(selected_aircraft)
	if cur >= 0:
		_aircraft_opt.select(cur)
	_aircraft_opt.item_selected.connect(_on_aircraft_selected)

	var team_labels := PackedStringArray()
	for t in TEAMS:
		team_labels.append(t["label"])
	_team_opt = _add_option(box, "Team", team_labels)
	_team_opt.select(selected_team)
	_team_opt.item_selected.connect(func(i: int) -> void:
		selected_team = i
		_refresh_start_options())

	_start_opt = _add_option(box, "Start position", PackedStringArray(["Random"]))
	_start_opt.item_selected.connect(func(i: int) -> void:
		selected_start = _start_opt.get_item_text(i))

	var auto := CheckBox.new()
	auto.text = "Automatic respawn (%.0f s after death)" % RESPAWN_DELAY
	auto.button_pressed = auto_respawn
	auto.toggled.connect(func(on: bool) -> void: auto_respawn = on)
	box.add_child(auto)

	var respawn_btn := Button.new()
	respawn_btn.text = "Respawn now"
	respawn_btn.pressed.connect(func() -> void:
		_set_panel_visible(false)
		respawn())
	box.add_child(respawn_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func() -> void: _set_panel_visible(false))
	box.add_child(close_btn)

func _add_option(box: VBoxContainer, label_text: String, items: PackedStringArray) -> OptionButton:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(130, 0)
	row.add_child(label)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for it in items:
		opt.add_item(it)
	row.add_child(opt)
	box.add_child(row)
	return opt

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
	_start_opt.add_item("Random")
	for n in sim.get_start_position_names():
		if n.begins_with(tag) and (heli or not n.contains("HELI")):
			_start_opt.add_item(n)
	selected_start = "Random"
	_start_opt.select(0)
