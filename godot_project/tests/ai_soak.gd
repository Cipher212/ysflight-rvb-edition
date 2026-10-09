extends Node

# AI soak run (main.gd starts it with "-- --ai-soak <sim seconds>"; tools/ai_soak.py launches it and prints the
# summary). Every aircraft is on AI (the player jet too), optionally faster than real time (--sim-speed N).
# Samples the RvB AI state every sample_s seconds of sim time into crashlog/ai_soak/<time>/samples.json,
# writes summary.json with the totals (landings, refuels, take-offs, respawns, tasks seen) and quits.

var sample_s: float = 10.0    # --soak-sample S

var main: Node = null
var sim: YSFlightSimulation = null
var out_dir: String = ""
var duration: float = 600.0

var _next_sample: float = 0.0
var _samples: Array = []
var _tasks_seen := {}
var _stages_seen := {}
var _start_usec: int = 0
var _done: bool = false

func setup(p_main: Node, p_duration: float) -> void:
	main = p_main
	sim = main.ysflight_sim
	var args := OS.get_cmdline_user_args()
	var route_i := args.find("--route-seed")
	if route_i >= 0 and route_i + 1 < args.size():
		sim.debug_set_route_seed(int(args[route_i + 1]))
		sim.set_random_seed(12345)
	duration = p_duration
	_start_usec = Time.get_ticks_usec()
	var dt := Time.get_datetime_dict_from_system()
	out_dir = ProjectSettings.globalize_path("res://").path_join("../crashlog/ai_soak/%04d%02d%02d_%02d%02d%02d" % [
		dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]).simplify_path()
	DirAccess.make_dir_recursive_absolute(out_dir)

func _process(_delta: float) -> void:
	if _done:
		return
	var st: Dictionary = sim.get_ai_state()
	var t: float = float(st.get("sim_time", 0.0))
	if t >= _next_sample:
		_next_sample = t + sample_s
		st["real_s"] = (Time.get_ticks_usec() - _start_usec) / 1000000.0
		st["ground_alive_by_iff"] = sim.get_ground_alive_by_iff()
		_samples.append(st)
		for k in (st.get("tasks", {}) as Dictionary).keys():
			_tasks_seen[k] = maxi(int(_tasks_seen.get(k, 0)), int(st["tasks"][k]))
		for k in (st.get("stages", {}) as Dictionary).keys():
			_stages_seen[k] = maxi(int(_stages_seen.get(k, 0)), int(st["stages"][k]))
		print("AI soak t=%4.0fs  alive %s  ground %s  tasks %s  landings %d refuels %d takeoffs %d respawned %d" % [
			t, str(st.get("alive_by_iff", {})), str(st["ground_alive_by_iff"]), str(st.get("tasks", {})), int(st.get("landings", 0)),
			int(st.get("refuels", 0)), int(st.get("takeoffs", 0)), int(st.get("respawned", 0))])
	if t >= duration:
		_finish(st, t)

func _finish(last: Dictionary, t: float) -> void:
	_done = true
	var real_s := (Time.get_ticks_usec() - _start_usec) / 1000000.0
	var summary := {
		"sim_seconds": t,
		"real_seconds": real_s,
		"speed": t / maxf(real_s, 0.001),
		"final": last,
		"max_tasks_at_once": _tasks_seen,
		"max_stages_at_once": _stages_seen,
		"samples": _samples.size(),
		"samples0": _samples[0] if not _samples.is_empty() else {},
	}
	var f := FileAccess.open(out_dir.path_join("samples.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(_samples, "  "))
	f.close()
	f = FileAccess.open(out_dir.path_join("summary.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(summary, "  "))
	f.close()
	print("AI soak done: ", out_dir)
	get_tree().quit(0)
