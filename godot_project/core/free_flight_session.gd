extends Node

# Free flight (Home > FREE FLIGHT): the map with no other aircraft. Created by main.gd when AppState.mode is
# "free_flight"; drives the same spawn menu as an event (ui/spawn_menu.gd) with every RvB aircraft and every
# start position of both teams. Esc opens the menu and pauses (you are alone: nothing should fly on without
# you; Esc again resumes while you have a jet); shot down or crashed: the menu opens DEATH_MENU_DELAY_S later.
# No clock, no score, no debrief.

signal spawn_menu_requested
signal menu_closed

const DEATH_MENU_DELAY_S := 3.0
const HOME_SCENE := "res://ui/home.tscn"
const LOADOUTS := ["DEFAULT", "AIR-TO-AIR", "STRIKE", "GUNS ONLY"] # sim/flight_setup.h presets
const END_LABEL := "EXIT TO MENU"

var main: Node = null
var sim: YSFlightSimulation = null
var catalog: Array = []
var in_menu := false

var _dead_for := 0.0

func setup(p_main: Node) -> void:
	name = "FreeFlightSession"
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = p_main
	sim = main.ysflight_sim
	catalog = sim.get_aircraft_catalog()
	main.controls.open_settings_handler = _on_escape
	_set_out_of_jet(true)
	in_menu = true
	spawn_menu_requested.emit.call_deferred()

func aircraft() -> Array:
	return catalog

func menu_title() -> String:
	return "FREE FLIGHT"

func menu_team() -> String:
	return ""

func menu_note() -> String:
	return "NO OTHER AIRCRAFT  /  ESC OPENS THIS MENU"

# Air starts of both teams first (not carrier decks), then the airfield and carrier spots.
func start_positions() -> PackedStringArray:
	var air := PackedStringArray()
	var ground := PackedStringArray()
	for n in sim.get_start_position_names():
		var up := n.to_upper()
		if up.begins_with("AI_BLUE") or up.begins_with("AI_RED"):
			if not up.contains("CARRIER"):
				air.append(n)
		elif n.begins_with("[IFF") and not n.contains("HELI"):
			ground.append(n)
	air.append_array(ground)
	return air

func spawn(identifier: String, start: String, loadout: String) -> bool:
	var iff := 3 if identifier.to_upper().contains("(RED/") else 0
	if not sim.respawn_player(identifier, start, iff):
		return false
	sim.apply_player_loadout(loadout)
	_close_menu()
	main.controls.recenter_mouse() # mouse = stick: don't start with the stick where the FLY button was
	main.camera_rig.reset_for_new_aircraft()
	main.camera_rig.set_mode(main.camera_rig.CamMode.HORIZON_CHASE)
	return true

func open_settings() -> void:
	main.controls.toggle_settings(true) # stays paused behind the menu

func end_session() -> void:
	main.controls.open_settings_handler = Callable()
	get_tree().paused = false
	get_tree().change_scene_to_file.call_deferred(HOME_SCENE)

func _has_jet() -> bool:
	return bool(sim.get_player_telemetry().get("is_alive", false))

func _open_menu() -> void:
	in_menu = true
	get_tree().paused = true
	spawn_menu_requested.emit()

func _close_menu() -> void:
	in_menu = false
	get_tree().paused = false
	_dead_for = 0.0
	_set_out_of_jet(false)
	menu_closed.emit()

func _set_out_of_jet(out: bool) -> void:
	main.hud.visible = not out
	main.radar_scope.visible = not out
	if out:
		main.camera_rig.set_mode(main.camera_rig.CamMode.SPECTATOR_AI)

func _on_escape() -> void:
	if main.controls.settings_panel != null and main.controls.settings_panel.visible:
		main.controls.toggle_settings(false)
	elif in_menu:
		if _has_jet():
			_close_menu()
	else:
		_open_menu()

func _process(delta: float) -> void:
	if in_menu or get_tree().paused:
		return
	if _has_jet():
		_dead_for = 0.0
		return
	_dead_for += delta
	if _dead_for >= DEATH_MENU_DELAY_S:
		_set_out_of_jet(true)
		_open_menu()
