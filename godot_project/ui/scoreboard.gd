extends CanvasLayer

# ==============================================================================
# YSFlight RvB Edition - Dynamic Tactical Scoreboard
# ==============================================================================
# Unified match scoreboard used both in-game during live events and during replay
# playback. Features timepoint-aware progression: in replay mode, scores and kills
# dynamically update based on the scrubbed timepoint.
#
# FULL SPECIFICATION & ARCHITECTURE REFERENCE:
# -> planning/replay_and_spectator_system.md
#
# If any issues occur, see planning/replay_and_spectator_system.md for columns,
# team styling, and progression calculation.
# ==============================================================================

const Kit := preload("res://ui/ui_kit.gd")
const PANEL_WIDTH := 1200
const PANEL_HEIGHT := 720
const COLUMNS := ["PILOT", "AIRCRAFT", "ROLE", "AIR", "GND", "DEATHS", "SCORE", "STATUS"]

var main: Node = null
var sim: YSFlightSimulation = null
var is_replay_mode: bool = false

var _replay_data: Dictionary = {}
var _current_replay_time: float = 0.0

var _root_control: Control = null
var _title_label: Label = null
var _clock_label: Label = null
var _score_summary_label: Label = null
var _blue_table_container: GridContainer = null
var _red_table_container: GridContainer = null
var _blue_score_lbl: Label = null
var _red_score_lbl: Label = null

func _init() -> void:
	layer = 95
	process_mode = Node.PROCESS_MODE_ALWAYS

func _ready() -> void:
	visible = false
	if _root_control == null:
		_build_ui()

func setup_live(p_main: Node, p_sim: YSFlightSimulation) -> void:
	if _root_control == null:
		_build_ui()
	main = p_main
	sim = p_sim
	is_replay_mode = false

func setup_replay(replay_data: Dictionary) -> void:
	if _root_control == null:
		_build_ui()
	_replay_data = replay_data
	is_replay_mode = true
	_current_replay_time = 0.0
	update_replay_timepoint(0.0)

func toggle_scoreboard() -> void:
	visible = not visible
	if visible:
		refresh()

func _input(event: InputEvent) -> void:
	if not is_replay_mode and event.is_action_pressed("toggle_scoreboard"):
		toggle_scoreboard()
		get_viewport().set_input_as_handled()

func _build_ui() -> void:
	_root_control = Control.new()
	_root_control.theme = Kit.THEME
	_root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root_control)

	# Semi-transparent backdrop for tactical legibility
	var dim := ColorRect.new()
	dim.color = Color(0.012, 0.02, 0.035, 0.85)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_control.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_control.add_child(center)

	var body := Kit.panel(center, "TACTICAL SCOREBOARD")
	var frame: PanelContainer = body.get_parent().get_parent()
	frame.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 14)
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(layout)

	# Top status banner
	var header_bar := HBoxContainer.new()
	header_bar.add_theme_constant_override("separation", 24)
	layout.add_child(header_bar)

	_title_label = Kit.label("MATCH PROGRESSION", "SectionLabel")
	header_bar.add_child(_title_label)

	_clock_label = Kit.label("00:00", "TagLabel")
	_clock_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_bar.add_child(_clock_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_bar.add_child(spacer)

	_blue_score_lbl = Kit.label("BLUE: 0", "BigNumber")
	_blue_score_lbl.add_theme_color_override("font_color", Kit.BLUE)
	header_bar.add_child(_blue_score_lbl)

	_red_score_lbl = Kit.label("RED: 0", "BigNumber")
	_red_score_lbl.add_theme_color_override("font_color", Kit.RED)
	header_bar.add_child(_red_score_lbl)

	layout.add_child(HSeparator.new())

	# Side-by-side or stacked tables for Blue vs Red forces
	var tables_row := HBoxContainer.new()
	tables_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tables_row.add_theme_constant_override("separation", 20)
	layout.add_child(tables_row)

	_blue_table_container = _create_team_box(tables_row, "BLUE FORCE", Kit.BLUE)
	_red_table_container = _create_team_box(tables_row, "RED FORCE", Kit.RED)

	var footer := HBoxContainer.new()
	layout.add_child(footer)
	var hint := Kit.label("TAB: TOGGLE SCOREBOARD  /  DYNAMIC TIMEPOINT EVALUATION", "DimLabel")
	footer.add_child(hint)

func _create_team_box(parent: Control, team_title: String, team_color: Color) -> GridContainer:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	parent.add_child(box)

	var head := Kit.label(team_title, "SectionLabel")
	head.add_theme_color_override("font_color", team_color)
	box.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	var grid := GridContainer.new()
	grid.columns = COLUMNS.size()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(grid)

	return grid

# Refreshes the display according to current mode
func refresh() -> void:
	if is_replay_mode:
		update_replay_timepoint(_current_replay_time)
	else:
		_refresh_live_state()

# ------------------------------------------------------------------------------
# Replay Mode: Evaluates match state at timestamp T
# ------------------------------------------------------------------------------
func update_replay_timepoint(t: float) -> void:
	_current_replay_time = t
	_clock_label.text = Kit.clock(t)

	var roster: Array = _replay_data.get("roster", [])
	var events: Array = _replay_data.get("events", [])

	# Calculate dynamic state for each pilot based on events up to time t
	var pilot_states: Dictionary = {} # pilot_name -> stats
	for p in roster:
		var pname: String = str(p.get("name", ""))
		pilot_states[pname] = {
			"name": pname,
			"aircraft": str(p.get("aircraft", "")),
			"role": str(p.get("role", "FIGHTER")),
			"team": str(p.get("team", "blue")),
			"air_kills": 0,
			"ground_kills": 0,
			"deaths": 0,
			"is_alive": true
		}

	var blue_score := 0
	var red_score := 0

	# Process events up to current scrubbed timestamp
	for ev in events:
		if not (ev is Dictionary):
			continue
		var ev_time: float = float(ev.get("time", 0.0))
		if ev_time > t:
			continue

		var ev_type: String = str(ev.get("type", ""))
		if ev_type == "kill":
			var killer: String = str(ev.get("killer_name", ""))
			var victim: String = str(ev.get("victim_name", ""))
			var k_team: String = str(ev.get("killer_team", ""))
			var is_ground: bool = bool(ev.get("ground", false))

			if pilot_states.has(killer):
				if is_ground:
					pilot_states[killer]["ground_kills"] += 1
				else:
					pilot_states[killer]["air_kills"] += 1

			if pilot_states.has(victim):
				pilot_states[victim]["deaths"] += 1
				# If victim died recently relative to t, mark status
				pilot_states[victim]["is_alive"] = false

			if k_team == "blue":
				blue_score += (2 if is_ground else 3)
			elif k_team == "red":
				red_score += (2 if is_ground else 3)

	_blue_score_lbl.text = "BLUE: %d" % blue_score
	_red_score_lbl.text = "RED: %d" % red_score

	_populate_table(_blue_table_container, pilot_states, "blue")
	_populate_table(_red_table_container, pilot_states, "red")

# ------------------------------------------------------------------------------
# Live In-Game Mode: Pulls state from live sim
# ------------------------------------------------------------------------------
func _refresh_live_state() -> void:
	if sim == null:
		return

	var res: Dictionary = sim.get_event_results() if sim.has_method("get_event_results") else {}
	var pilots: Array = res.get("pilots", [])
	if pilots.is_empty() and sim.has_method("get_event_roster"):
		pilots = sim.get_event_roster()

	var state: Dictionary = sim.get_event_state() if sim.has_method("get_event_state") else {}
	var elapsed: float = float(state.get("elapsed", 0.0))
	_clock_label.text = Kit.clock(elapsed)

	var pilot_states: Dictionary = {}
	for p in pilots:
		var pname: String = str(p.get("name", ""))
		pilot_states[pname] = {
			"name": pname,
			"aircraft": str(p.get("aircraft", "")),
			"role": str(p.get("role", "FIGHTER")),
			"team": str(p.get("team", "blue")),
			"air_kills": int(p.get("air_kills", 0)),
			"ground_kills": int(p.get("ground_kills", 0)),
			"deaths": int(p.get("deaths", 0)),
			"is_alive": bool(p.get("alive", true))
		}

	var bk: int = int(state.get("blue_kills", 0))
	var rk: int = int(state.get("red_kills", 0))
	_blue_score_lbl.text = "BLUE: %d" % bk
	_red_score_lbl.text = "RED: %d" % rk

	_populate_table(_blue_table_container, pilot_states, "blue")
	_populate_table(_red_table_container, pilot_states, "red")

func _populate_table(grid: GridContainer, pilot_states: Dictionary, team: String) -> void:
	for child in grid.get_children():
		child.queue_free()

	# Column Headers
	for c in COLUMNS:
		var th := Kit.label(c, "TableHead")
		grid.add_child(th)

	var team_pilots: Array = []
	for p in pilot_states.values():
		if p["team"] == team:
			team_pilots.append(p)

	# Rank: total kills descending, then deaths ascending
	team_pilots.sort_custom(func(a, b):
		var ka: int = a["air_kills"] + a["ground_kills"]
		var kb: int = b["air_kills"] + b["ground_kills"]
		if ka != kb:
			return ka > kb
		return a["deaths"] < b["deaths"])

	for p in team_pilots:
		var score: int = (p["air_kills"] * 3) + (p["ground_kills"] * 2) - (p["deaths"] * 1)
		var status_str := "AIRBORNE" if bool(p["is_alive"]) else "KIA"

		var row_cells := [
			p["name"],
			p["aircraft"],
			p["role"],
			str(p["air_kills"]),
			str(p["ground_kills"]),
			str(p["deaths"]),
			str(score),
			status_str
		]

		for i in range(row_cells.size()):
			var text: String = str(row_cells[i])
			var style := "RedText" if team == "red" and i == 0 else ("BlueText" if i == 0 else "")
			var cell := Kit.label(text, style)
			if i == 1:
				cell.clip_text = true
			if i == 7: # Status
				cell.add_theme_color_override("font_color", Color("#55ff55") if status_str == "AIRBORNE" else Color("#ff5555"))
			grid.add_child(cell)
