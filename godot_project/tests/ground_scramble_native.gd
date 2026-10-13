extends SceneTree

# Exercise ordinary mission loading and role AI without forcing arrival followers or ground state.
var sim: Object
var roster: Array[int] = []
var latest: Dictionary = {}
var next_sample := 0.0
var trace: Array = []
var departures: Dictionary = {}

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	sim = ClassDB.instantiate("YSFlightSimulation")
	root.add_child(sim)
	sim.initialize_simulation()
	sim.set_random_seed(12345) # Match the soak harness; later RTB traffic must be reproducible.
	sim.set_ai_respawn_enabled(false)
	sim.set_ai_ground_ops(true)
	sim.set_ai_recovery_all_roles(true)
	sim.load_yfs(args[0])
	sim.debug_set_route_seed(12345)
	sim.set_process(false) # This headless proof needs physics, not mesh/visual synchronization.
	sim.enable_player_autopilot()
	var initial: Array = sim.get_ai_combat_state()
	var stationary := true
	for row in initial:
		roster.append(int(row.key))
		stationary = stationary and float(row.speed) < 0.001 and float(row.throttle) < 0.001
	sim.set_sim_speed(16)
	var passed := false
	var time := 0.0
	for frame in range(8000):
		await process_frame
		var rows: Array = sim.get_ai_arrival_state()
		if rows.is_empty(): continue
		time = float(rows[0].t)
		var alive := true
		var pavement_clean := true
		for row in rows:
			latest[int(row.search_key)] = row
			if bool(row.report.airborne) and not departures.has(int(row.search_key)):
				departures[int(row.search_key)] = row
			# A later combat death or RTB must not erase a verified safe takeoff.
			alive = alive and (bool(row.alive) or departures.has(int(row.search_key)))
			if not departures.has(int(row.search_key)):
				pavement_clean = pavement_clean and float(row.report.off_pavement_s) <= 0.1
		var departed := 0
		for key in roster:
			if departures.has(key): departed += 1
		if time >= next_sample:
			next_sample = time + 5.0
			trace.append({"t": time, "aircraft": rows})
			var progress := FileAccess.open(args[1].path_join("progress.json"), FileAccess.WRITE)
			progress.store_string(JSON.stringify({"sim_time": time, "departed": departed, "aircraft": rows}))
		if departed == roster.size() and alive:
			passed = true
			break
		if not alive or not pavement_clean or time >= 900.0: break
	passed = passed and stationary and roster.size() == 32
	for key in departures:
		latest[key] = departures[key]
	var result := FileAccess.open(args[1].path_join("result.json"), FileAccess.WRITE)
	result.store_string(JSON.stringify({"pass": passed, "stationary": stationary, "t": time,
		"initial": initial, "aircraft": latest.values(), "trace": trace}, "\t"))
	print("NATIVE SCRAMBLE ", "PASS" if passed else "FAIL", " originals=", roster.size(), " t=", time)
	sim.queue_free()
	for frame in range(3): await process_frame
	quit.call_deferred(0 if passed else 1)
