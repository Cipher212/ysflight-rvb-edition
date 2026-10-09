extends "res://core/preflight_session.gd"

# Owns the offline countdown and hard team lock. Native EventMatch owns scoring after activation.
const ESC_WINDOW_S := 2.0
const START_COUNTDOWN_S := 30.0
const DEBRIEF_SCENE := "res://ui/debrief.tscn"

var countdown_left := -1.0
var _esc_until := -1.0
var _done := false
var _started := false

func setup(p_main: Node, p_config: Dictionary) -> void:
	name = "EventSession"
	is_event = true
	setup_base(p_main, p_config)
	sim.set_physics_process(false)
	sim.set_ai_respawn_enabled(false)
	EventConfig.fit_team_sizes(config, catalog)

func _lock_team() -> bool:
	if team_locked:
		return true
	var match_config := EventConfig.with_human_slot(config, _team)
	if not sim.event_begin(match_config):
		last_error = "Could not start the event."
		return false
	team_locked = true
	countdown_left = START_COUNTDOWN_S
	add_message("Teams locked. Match starts in 30 seconds.")
	return true

func roster() -> Array:
	if team_locked:
		return sim.get_event_roster()
	var out: Array = []
	for pilot in EventConfig.with_human_slot(config, _team).get("pilots", []):
		var row: Dictionary = pilot.duplicate()
		row.merge({"player": false, "alive": false, "key": -1})
		out.append(row)
	out.push_front({"name": config.get("player_name", "PLAYER"), "team": _team, "player": true,
		"aircraft": "", "alive": false, "key": -1})
	return out

func status_text() -> String:
	if not team_locked:
		return "%dv%d  /  CHOOSE YOUR TEAM" % [config.get("team_size", 8), config.get("team_size", 8)]
	if not _started:
		return "MATCH STARTS IN %d  /  TEAM LOCKED" % ceili(maxf(countdown_left, 0.0))
	return "MATCH LIVE  /  TEAM LOCKED"

func end_label() -> String:
	return "END EVENT"

func end_session() -> void:
	if not team_locked:
		super.end_session()
	else:
		sim.event_end()
		_finish()

func leave_jet() -> void:
	sim.event_leave_jet()
	_open_screen("hangar")

func _on_escape() -> void:
	if main.controls.settings_panel != null and main.controls.settings_panel.visible:
		main.controls.toggle_settings(false)
		return
	if in_menu:
		if menu_screen == "hangar":
			show_lobby()
		return
	if spectating or not _has_jet():
		_open_screen("lobby")
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
	if team_locked and not _started:
		countdown_left = maxf(0.0, countdown_left - delta)
		if countdown_left <= 0:
			_started = true
			sim.set_physics_process(true)
			add_message("Match started.")
	var state: Dictionary = sim.get_event_state()
	state["time_left"] = float(config.get("duration_min", 20)) * 60.0 if not _started else state.get("time_left", 0.0)
	state["countdown"] = countdown_left if team_locked and not _started else -1.0
	state_updated.emit(state)
	if _esc_until > 0 and Time.get_ticks_msec() / 1000.0 > _esc_until:
		_esc_until = -1.0
		esc_hint.emit(false)
	if bool(state.get("ended", false)):
		_finish()
		return
	super._process(delta)

func _finish() -> void:
	_done = true
	var file := FileAccess.open(EventConfig.RESULTS_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(sim.get_event_results(), "\t"))
	finished.emit()
	main.controls.open_settings_handler = Callable()
	get_tree().paused = false
	get_tree().change_scene_to_file.call_deferred(DEBRIEF_SCENE)
