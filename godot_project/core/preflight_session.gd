extends Node

# Shared session state for lobby, hangar and spectator flow. Screens only request transitions.
const EventConfig := preload("res://core/event_config.gd")
const HOME_SCENE := "res://ui/home.tscn"
const DEATH_MENU_DELAY_S := 3.0

signal menu_requested(screen: String)
signal menu_closed
signal state_updated(state: Dictionary)
signal esc_hint(show: bool)
signal finished
signal message_added(text: String)

var main: Node
var sim: YSFlightSimulation
var config: Dictionary = {}
var catalog: Array = []
var in_menu := true
var team_locked := false
var spectating := false
var is_event := false
var menu_screen := "lobby"
var messages: Array[String] = []
var last_error := ""
var _team := "blue"
var _dead_for := 0.0
var _flight_camera_mode := -1

func setup_base(p_main: Node, p_config: Dictionary) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = p_main
	sim = main.ysflight_sim
	config = p_config.duplicate(true)
	_team = str(config.get("player_team", "blue"))
	catalog = sim.get_aircraft_catalog()
	main.controls.open_settings_handler = _on_escape
	_set_out_of_jet(true)
	add_message("Choose your team, then enter the hangar or spectate.")
	menu_requested.emit.call_deferred("lobby")

func player_team() -> String:
	return _team

func aircraft() -> Array:
	return EventConfig.aircraft_for(catalog, _team)

func choose_team(team: String) -> bool:
	if team_locked or team not in ["blue", "red"]:
		return false
	_team = team
	config["player_team"] = team
	return true

func start_positions() -> PackedStringArray:
	var air := PackedStringArray()
	var ground := PackedStringArray()
	var air_tag := "AI_RED_" if _team == "red" else "AI_BLUE_"
	var ground_tag := "[IFF4]" if _team == "red" else "[IFF1]"
	for value in sim.get_start_position_names():
		var up := value.to_upper()
		if up.begins_with(air_tag) and not up.contains("CARRIER"):
			air.append(value)
		elif up.begins_with(ground_tag) and not up.contains("HELI"):
			ground.append(value)
	air.append_array(ground)
	return air

func enter_hangar() -> bool:
	if not _lock_team():
		return false
	_open_screen("hangar")
	return true

func _lock_team() -> bool:
	team_locked = true
	return true

func show_lobby() -> void:
	_open_screen("lobby")

func spawn_custom(identifier: String, start: String, fuel: float, slots: Array) -> Dictionary:
	if not team_locked or not in_menu:
		return {"ok": false, "error": "Enter the hangar before spawning."}
	var permitted := false
	for entry in aircraft():
		if entry["identifier"] == identifier:
			permitted = true
	if not permitted or not start_positions().has(start):
		return {"ok": false, "error": "Aircraft or start is unavailable for your team."}
	var result: Dictionary = sim.spawn_player_custom(identifier, start, 3 if _team == "red" else 0, fuel, slots)
	if not bool(result.get("ok", false)):
		return result
	spectating = false
	_close_menu()
	main.controls.recenter_mouse()
	main.camera_rig.reset_for_new_aircraft()
	main.camera_rig.set_mode(main.camera_rig.CamMode.HORIZON_CHASE)
	add_message("%s selected %s." % [config.get("player_name", "PLAYER"), identifier])
	return result

func spectate(target_key: int = -1) -> bool:
	if not _lock_team():
		return false
	if target_key >= 0:
		var allowed := false
		for pilot in roster():
			if pilot.get("team", "") == _team and bool(pilot.get("alive", false)) and int(pilot.get("key", -1)) == target_key:
				allowed = true
		if not allowed:
			return false
	if _has_jet():
		sim.event_leave_jet()
	spectating = true
	in_menu = false
	get_tree().paused = false
	_dead_for = 0.0
	_set_out_of_jet(true)
	main.camera_rig.set_session_spectator(true, 3 if _team == "red" else 0, target_key)
	menu_closed.emit()
	return true

func roster() -> Array:
	return [{"name": config.get("player_name", "PLAYER"), "team": _team, "player": true,
		"aircraft": "", "alive": _has_jet(), "key": -1}]

func status_text() -> String:
	return "FREE FLIGHT  /  " + ("TEAM LOCKED" if team_locked else "CHOOSE A TEAM")

func end_label() -> String:
	return "EXIT TO MENU"

func add_message(text: String) -> void:
	messages.append(text.left(240))
	if messages.size() > 100:
		messages.pop_front()
	message_added.emit(messages.back())

func send_message(text: String) -> void:
	var trimmed := text.strip_edges().left(160)
	if not trimmed.is_empty():
		add_message("%s: %s" % [config.get("player_name", "PLAYER"), trimmed])

func open_settings() -> void:
	main.controls.toggle_settings(not is_event)

func end_session() -> void:
	main.controls.open_settings_handler = Callable()
	get_tree().paused = false
	get_tree().change_scene_to_file.call_deferred(HOME_SCENE)

func _has_jet() -> bool:
	return bool(sim.get_player_telemetry().get("is_alive", false))

func in_flight() -> bool:
	return not in_menu and not spectating and _has_jet()

func can_resume() -> bool:
	return not is_event and _has_jet()

func resume_flight() -> void:
	if can_resume():
		spectating = false
		_close_menu()

func _open_screen(screen: String) -> void:
	if not in_menu and not spectating:
		_flight_camera_mode = main.camera_rig.mode
	in_menu = true
	menu_screen = screen
	_dead_for = 0.0
	_set_out_of_jet(true)
	if not is_event:
		get_tree().paused = true
	menu_requested.emit(screen)

func _close_menu() -> void:
	in_menu = false
	get_tree().paused = false
	_dead_for = 0.0
	_set_out_of_jet(false)
	main.camera_rig.set_mode(_flight_camera_mode if _flight_camera_mode >= 0 else main.camera_rig.CamMode.HORIZON_CHASE)
	menu_closed.emit()

func _set_out_of_jet(out: bool) -> void:
	main.hud.visible = not out
	main.radar_scope.visible = not out
	main.controls.set_session_input_enabled(not out)
	main.camera_rig.set_session_spectator(false, -1)
	main.camera_rig.set_process_unhandled_input(not out)
	if out:
		main.camera_rig.set_mode(main.camera_rig.CamMode.SPECTATOR_AI)

func _on_escape() -> void:
	if main.controls.settings_panel != null and main.controls.settings_panel.visible:
		main.controls.toggle_settings(false)
	elif in_menu:
		if menu_screen == "hangar":
			show_lobby()
		else:
			resume_flight()
	else:
		_open_screen("lobby")

func _process(delta: float) -> void:
	if in_menu or spectating or get_tree().paused:
		return
	if _has_jet():
		_dead_for = 0.0
	else:
		_dead_for += delta
		if _dead_for >= DEATH_MENU_DELAY_S:
			add_message("Aircraft lost. Select an aircraft to fly again.")
			_open_screen("hangar")
