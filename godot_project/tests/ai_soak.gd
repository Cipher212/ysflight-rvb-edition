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
var _next_score_sample: float = 0.0
var _samples: Array = []
var _score_timeline: Array = []
var _score_csv_lines: Array[String] = []
var _tasks_seen := {}
var _stages_seen := {}
var _start_usec: int = 0
var _done: bool = false

func setup(p_main: Node, p_duration: float) -> void:
	main = p_main
	sim = main.ysflight_sim
	# Native AI respawn owns the camera slot too; the free-play timer must not create a second replacement.
	var respawn_manager: Node = main.get_node("RespawnManager")
	respawn_manager.set("auto_respawn", false)
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
	_score_csv_lines.append("sim_time,real_s,blue_score,blue_air_k,blue_gnd_k,blue_deaths,blue_deaths_wep,blue_deaths_crash,blue_air_dmg,blue_gnd_dmg,red_score,red_air_k,red_gnd_k,red_deaths,red_deaths_wep,red_deaths_crash,red_air_dmg,red_gnd_dmg")

func _compute_team_aggregates(lives: Array) -> Dictionary:
	var teams := {
		"blue": {
			"iff": 0, "air_kills": 0, "ground_kills": 0, "deaths": 0,
			"deaths_weapon": 0, "deaths_crash": 0, "air_damage": 0, "ground_damage": 0,
			"score": 0,
			"multirole": {"air_kills": 0, "ground_kills": 0, "deaths": 0, "deaths_weapon": 0, "deaths_crash": 0},
			"attacker": {"air_kills": 0, "ground_kills": 0, "deaths": 0, "deaths_weapon": 0, "deaths_crash": 0}
		},
		"red": {
			"iff": 3, "air_kills": 0, "ground_kills": 0, "deaths": 0,
			"deaths_weapon": 0, "deaths_crash": 0, "air_damage": 0, "ground_damage": 0,
			"score": 0,
			"multirole": {"air_kills": 0, "ground_kills": 0, "deaths": 0, "deaths_weapon": 0, "deaths_crash": 0},
			"attacker": {"air_kills": 0, "ground_kills": 0, "deaths": 0, "deaths_weapon": 0, "deaths_crash": 0}
		}
	}
	for life in lives:
		if not (life is Dictionary):
			continue
		var iff: int = int(life.get("iff", -1))
		var t: Dictionary = teams["blue"] if iff == 0 else (teams["red"] if iff == 3 else {})
		if t.is_empty():
			continue
		var ak: int = int(life.get("air_kills", 0))
		var gk: int = int(life.get("ground_kills", 0))
		var is_dead: bool = bool(life.get("dead", false))
		var cause: String = str(life.get("cause", ""))
		var role: String = str(life.get("role", "")).to_lower()
		t["air_kills"] += ak
		t["ground_kills"] += gk
		t["air_damage"] += int(life.get("air_damage", 0))
		t["ground_damage"] += int(life.get("ground_damage", 0))
		var is_wep: bool = cause in ["MISSILE", "GUN"]
		if is_dead:
			t["deaths"] += 1
			if is_wep:
				t["deaths_weapon"] += 1
			else:
				t["deaths_crash"] += 1
		if role in t:
			t[role]["air_kills"] += ak
			t[role]["ground_kills"] += gk
			if is_dead:
				t[role]["deaths"] += 1
				if is_wep:
					t[role]["deaths_weapon"] += 1
				else:
					t[role]["deaths_crash"] += 1
	for k in teams.keys():
		teams[k]["score"] = 3 * teams[k]["air_kills"] + 2 * teams[k]["ground_kills"] - teams[k]["deaths"]
	return teams

func _process(_delta: float) -> void:
	if _done:
		return
	var st: Dictionary = sim.get_ai_state()
	var t: float = float(st.get("sim_time", 0.0))
	var need_score := t >= _next_score_sample
	var need_sample := t >= _next_sample
	var team_aggs := {}
	if need_score or need_sample:
		var lives: Array = st.get("soak_stats", {}).get("lives", [])
		team_aggs = _compute_team_aggregates(lives)

	if need_score:
		_next_score_sample = t + 60.0
		var real_s := (Time.get_ticks_usec() - _start_usec) / 1000000.0
		var b: Dictionary = team_aggs["blue"]
		var r: Dictionary = team_aggs["red"]
		_score_csv_lines.append("%.1f,%.2f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d" % [
			t, real_s, b["score"], b["air_kills"], b["ground_kills"], b["deaths"], b["deaths_weapon"], b["deaths_crash"], b["air_damage"], b["ground_damage"],
			r["score"], r["air_kills"], r["ground_kills"], r["deaths"], r["deaths_weapon"], r["deaths_crash"], r["air_damage"], r["ground_damage"]])
		_score_timeline.append({"sim_time": t, "real_s": real_s, "teams": team_aggs})

	if need_sample:
		_next_sample = t + sample_s
		st["real_s"] = (Time.get_ticks_usec() - _start_usec) / 1000000.0
		st["ground_alive_by_iff"] = sim.get_ground_alive_by_iff()
		# The cumulative native weapon/life ledger is saved once in the final summary.
		var sample := st.duplicate()
		sample["team_scores"] = team_aggs
		sample.erase("soak_stats")
		_samples.append(sample)
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
	last["ground_alive_by_iff"] = sim.get_ground_alive_by_iff()
	var real_s := (Time.get_ticks_usec() - _start_usec) / 1000000.0
	var final_lives: Array = last.get("soak_stats", {}).get("lives", [])
	var final_team_aggs := _compute_team_aggregates(final_lives)
	
	# Add final timestamp to score CSV if needed
	var b: Dictionary = final_team_aggs["blue"]
	var r: Dictionary = final_team_aggs["red"]
	_score_csv_lines.append("%.1f,%.2f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d" % [
		t, real_s, b["score"], b["air_kills"], b["ground_kills"], b["deaths"], b["deaths_weapon"], b["deaths_crash"], b["air_damage"], b["ground_damage"],
		r["score"], r["air_kills"], r["ground_kills"], r["deaths"], r["deaths_weapon"], r["deaths_crash"], r["air_damage"], r["ground_damage"]])
	
	var summary := {
		"sim_seconds": t,
		"real_seconds": real_s,
		"speed": t / maxf(real_s, 0.001),
		"native_ai_respawns_only": not bool(main.get_node("RespawnManager").get("auto_respawn")),
		"final": last,
		"team_scores": final_team_aggs,
		"team_score_timeline": _score_timeline,
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
	var f_csv := FileAccess.open(out_dir.path_join("team_scores.csv"), FileAccess.WRITE)
	f_csv.store_string("\n".join(_score_csv_lines) + "\n")
	f_csv.close()
	print("AI soak done: ", out_dir)
	get_tree().quit(0)
