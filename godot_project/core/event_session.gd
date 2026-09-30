extends Node

# Runtime of an offline RvB event, created by main.gd when AppState.mode == "event" (the generated mission is
# already loaded). Logic only - the screens (ui/event_overlay.gd, ui/spawn_menu.gd) listen to the signals and
# call spawn() / leave_jet() / end_event(). The event clock and the AI never pause for these menus.
# - Starts the event (C++ EventMatch: roster, AI air starts, rules, stats).
# - Esc (the "open_settings" action): once shows a hint, twice within ESC_WINDOW_S leaves the jet (spawn menu).
# - Player shot down: the spawn menu opens DEATH_MENU_DELAY_S later. Out of a jet: spectator camera, no HUD.
# - Time up (or "End event"): results -> RESULTS_PATH, then the debrief scene.

const EventConfig := preload("res://core/event_config.gd")

signal state_updated(state: Dictionary)   # every frame: time_left, blue/red kills, player status
signal spawn_menu_requested               # open the spawn menu (event start, Esc x2, after death)
signal esc_hint(show: bool)               # "press Esc again to leave your jet"
signal finished                           # results saved; the debrief scene is about to load

const ESC_WINDOW_S := 2.0
const DEATH_MENU_DELAY_S := 3.0
const DEBRIEF_SCENE := "res://ui/debrief.tscn"
const LOADOUTS := ["DEFAULT", "AIR-TO-AIR", "STRIKE", "GUNS ONLY"] # sim/flight_setup.h presets

var main: Node = null
var sim: YSFlightSimulation = null
var config: Dictionary = {}
var catalog: Array = []                   # [{identifier, team, role}] (C++ get_aircraft_catalog)
var in_menu := false                      # the spawn menu is open

var _esc_until := -1.0
var _dead_for := 0.0
var _done := false

func setup(p_main: Node, p_config: Dictionary) -> void:
	name = "EventSession"
	main = p_main
	sim = main.ysflight_sim
	config = p_config
	catalog = sim.get_aircraft_catalog()
	if not sim.event_begin(config):
		push_error("Event: event_begin failed")
	main.controls.open_settings_handler = _on_escape
	_set_out_of_jet(true)
	spawn_menu_requested.emit.call_deferred()
	in_menu = true

func player_team() -> String:
	return str(config.get("player_team", "blue"))

# Start positions for the spawn menu: the map's air spots for the team first, then its airfield spots.
func start_positions() -> PackedStringArray:
	var air := PackedStringArray()
	var ground := PackedStringArray()
	var air_tag := "AI_RED" if player_team() == "red" else "AI_BLUE"
	var gnd_tag := "[IFF4]" if player_team() == "red" else "[IFF1]"
	for n in sim.get_start_position_names():
		if n.to_upper().begins_with(air_tag):
			if not n.to_upper().contains("CARRIER"): # a deck spot, not an air start (carriers: [IFFn]CARRIER_*)
				air.append(n)
		elif n.begins_with(gnd_tag) and not n.contains("HELI"):
			ground.append(n)
	air.append_array(ground)
	return air

func spawn(aircraft: String, start: String, loadout: String) -> bool:
	var iff := 3 if player_team() == "red" else 0
	if not sim.respawn_player(aircraft, start, iff):
		return false
	sim.apply_player_loadout(loadout)
	in_menu = false
	_dead_for = 0.0
	_set_out_of_jet(false)
	main.controls.recenter_mouse() # mouse = stick: don't start with the stick where the FLY button was
	main.camera_rig.reset_for_new_aircraft()
	main.camera_rig.set_mode(main.camera_rig.CamMode.HORIZON_CHASE)
	return true

func leave_jet() -> void:
	sim.event_leave_jet()
	_open_menu()

func end_event() -> void:
	sim.event_end()

func open_settings() -> void:
	main.controls.toggle_settings(false) # never pauses during an event

func _open_menu() -> void:
	_set_out_of_jet(true)
	in_menu = true
	spawn_menu_requested.emit()

func _set_out_of_jet(out: bool) -> void:
	main.hud.visible = not out
	main.radar_scope.visible = not out
	if out:
		main.camera_rig.set_mode(main.camera_rig.CamMode.SPECTATOR_AI)

func _on_escape() -> void:
	if in_menu: # Esc in the spawn menu only closes the settings panel
		if main.controls.settings_panel != null and main.controls.settings_panel.visible:
			main.controls.toggle_settings(false)
		return
	var state: Dictionary = sim.get_event_state()
	if not bool(state.get("player_in_jet", false)):
		_open_menu()
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now < _esc_until:
		_esc_until = -1.0
		esc_hint.emit(false)
		leave_jet()
	else:
		_esc_until = now + ESC_WINDOW_S
		esc_hint.emit(true)

func _process(delta: float) -> void:
	if _done:
		return
	var state: Dictionary = sim.get_event_state()
	state_updated.emit(state)
	if _esc_until > 0.0 and Time.get_ticks_msec() / 1000.0 > _esc_until:
		_esc_until = -1.0
		esc_hint.emit(false)
	if bool(state.get("ended", false)):
		_finish()
		return
	# Shot down or crashed (counted from the moment of the kill): the wreck stays the player's aircraft until
	# the next spawn; open the menu after a moment
	if not in_menu and not bool(state.get("player_in_jet", true)):
		_dead_for += delta
		if _dead_for >= DEATH_MENU_DELAY_S:
			_open_menu()
	else:
		_dead_for = 0.0 # also covers the frame between spawn() and the sim binding the new jet

func _finish() -> void:
	_done = true
	var f := FileAccess.open(EventConfig.RESULTS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(sim.get_event_results(), "\t"))
		f.close()
	finished.emit()
	main.controls.open_settings_handler = Callable()
	get_tree().paused = false
	get_tree().change_scene_to_file.call_deferred(DEBRIEF_SCENE)
