extends SceneTree

# Native integration checks only; this script draws no gameplay UI.
var sim: Object
var failed := false
var checks := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	failed = failed or not ok
	print("SPAWN EVENTS ", "PASS " if ok else "FAIL ", label)

func player_key() -> int:
	var transforms: Dictionary = sim.get_airplane_transforms()
	for key in transforms:
		if transforms[key].get("is_player", false): return int(key)
	return 0

func run() -> void:
	sim = ClassDB.instantiate("YSFlightSimulation")
	root.add_child(sim)
	sim.initialize_simulation()
	sim.load_yfs(OS.get_cmdline_user_args()[0])
	sim.set_ai_respawn_enabled(false)
	const MODEL := "F-18(BLUE/MULTIROLE)"
	const START := "[IFF1]COLE_SCRAMBLE_01"
	check(sim.respawn_player(MODEL, START, 0), "first stationary join accepted")
	var first := player_key()
	check(not sim.respawn_player(MODEL, START, 0), "same-frame repeated join rejected")
	check(player_key() == first, "rejected join preserves current player")
	var slots: Array = sim.get_aircraft_specs(MODEL).get("default_slots", [])
	var custom: Dictionary = sim.spawn_player_custom(MODEL, START, 0, 100.0, slots)
	check(not custom.get("ok", true) and "occupied" in str(custom.get("error", "")), "custom-loadout join also rejects occupancy")
	var pose: Dictionary
	for row in sim.get_ai_combat_state():
		if int(row.key) == first: pose = row
	check(absf(float(pose.speed)) < 0.001, "ground spawn has zero speed")
	sim.debug_move_airplane(first, float(pose.x) + 60.0, float(pose.y), float(pose.z))
	check(sim.respawn_player(MODEL, START, 0), "start reusable as soon as aircraft physically clears")
	check(not sim.respawn_player(MODEL, "MISSING_START", 0), "invalid start cannot create an unplaced aircraft")
	sim.initialize_simulation()
	sim.load_yfs(OS.get_cmdline_user_args()[0])
	var second := player_key()
	# One actual terrain impact must produce one event, despite subsequent wreck ticks.
	sim.debug_move_airplane(second, -100000.0, -30.0, 0.0)
	for frame in range(30): await process_frame
	var crashes := 0
	for event in sim.get_game_events(0).events:
		if event.kind == "crash" and int(event.victim.key) == second: crashes += 1
	check(crashes == 1, "actual terrain impact produces exactly one crash message")
	var cursor: int = int(sim.get_game_events(0).latest_sequence)
	check(sim.get_game_events(cursor).events.is_empty(), "event cursor does not replay already-read messages")
	sim.event_leave_jet()
	var events: Array = sim.get_game_events(cursor).events
	check(events.size() == 1 and events[0].kind == "leave", "explicit leave recorded before aircraft deletion")
	sim.notify_participant_disconnected("Network pilot")
	check(sim.get_game_events(0).events[-1].kind == "disconnect", "transport disconnect hook records participant")
	for i in range(270): sim.notify_participant_disconnected("pilot %d" % i)
	var history: Dictionary = sim.get_game_events(0)
	check(history.events.size() == 256 and history.dropped, "bounded history reports dropped old messages")
	var old_cursor: int = int(history.latest_sequence)
	sim.initialize_simulation()
	sim.load_yfs(OS.get_cmdline_user_args()[0])
	check(sim.get_game_events(old_cursor).events.is_empty(), "mission reset clears old text events")
	# Use a real missile, with the same native damage/credit path used in ordinary missions.
	var victim := player_key()
	var shooter := 0
	for row in sim.get_ai_combat_state():
		if int(row.key) != victim: shooter = int(row.key)
	check(sim.debug_fire_missile(shooter, 1, victim, false), "real missile launched for kill credit")
	for frame in range(420):
		if frame in [60, 120, 180, 240, 300]: sim.debug_fire_missile(shooter, 1, victim, false)
		await process_frame
	var kills := 0
	for event in sim.get_game_events(old_cursor).events:
		if event.kind == "kill" and int(event.victim.key) == victim:
			kills += 1
			check(int(event.killer.key) == shooter and int(event.killer.iff) == 3, "kill identifies actual enemy shooter")
	check(kills == 1, "real weapon death produces exactly one credited kill")

	sim.queue_free()
	for frame in range(3): await process_frame
	print("SPAWN EVENTS RESULT ", "FAIL" if failed else "PASS", " checks=", checks)
	quit.call_deferred(1 if failed else 0)
