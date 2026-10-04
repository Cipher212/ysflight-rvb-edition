extends Node

# Arrival follower test (main.gd starts it with "-- --ai-arrival <RUNWAY> --arrival-out <dir>"; the launcher and
# judge is tools/ai_arrival_test.py). Samples every aircraft on the follower every SAMPLE_S of sim time into
# <dir>/trace.json, and in a window saves one screenshot when the player's jet reaches each new phase. Writes
# <dir>/result.json and quits when every jet is DONE, FAILED or dead, or at the time limit (--arrival-limit S).

const SAMPLE_S := 0.25
const FINISHED := ["DONE", "FAILED"]

var main: Node = null
var sim: YSFlightSimulation = null
var out_dir: String = ""
var limit_s: float = 900.0

var _trace: Array = []
var _next_sample: float = 0.0
var _last_phase: String = ""
var _shots: bool = false
var _shot_pending: String = ""
var _shot_n: int = 0
var _done: bool = false

var kill_at_sec: float = -1.0
var kill_jet_idx: int = -1
var kill_approach_at_sec: float = -1.0
var kill_first_waiting: bool = false
var kill_approach_holder: bool = false
var _killed: bool = false
var _kill_event: Dictionary = {}
var _initial_keys: Array[int] = []
var _waiting_ready_at: float = -1.0

func setup(p_main: Node, p_out_dir: String) -> void:
	main = p_main
	sim = main.ysflight_sim
	out_dir = ProjectSettings.globalize_path(p_out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var args := OS.get_cmdline_user_args()
	var li := args.find("--arrival-limit")
	if li >= 0 and li + 1 < args.size():
		limit_s = float(args[li + 1])
	var ki := args.find("--kill-at-sec")
	if ki >= 0 and ki + 1 < args.size():
		kill_at_sec = float(args[ki + 1])
	var kji := args.find("--kill-jet-idx")
	if kji >= 0 and kji + 1 < args.size():
		kill_jet_idx = int(args[kji + 1])
	var kai := args.find("--kill-approach-at-sec")
	if kai >= 0 and kai + 1 < args.size():
		kill_approach_at_sec = float(args[kai + 1])
	if args.find("--kill-first-waiting") >= 0:
		kill_first_waiting = true
	if args.find("--kill-approach-holder") >= 0:
		kill_approach_holder = true
	_shots = DisplayServer.get_name() != "headless"

func _trigger_kill(target: Dictionary, t: float, rows: Array) -> void:
	_killed = true
	var target_key: int = int(target["search_key"])
	print("Killing target jet (key=%d, phase=%s, hold=%s) at t=%.2f s" % [target_key, target.get("phase", ""), target.get("hold_state", ""), t])
	_kill_event = {
		"target_key": target_key,
		"kill_requested_at": t,
		"pre_kill_state": {
			"phase": str(target.get("phase", "")),
			"hold_state": str(target.get("hold_state", "")),
			"stack_level": int(target.get("stack_level", 0)),
			"clearance_approach": bool(target.get("clearance_approach", false)),
			"clearance_runway": bool(target.get("clearance_runway", false))
		},
		"death_confirmed_at": -1.0,
		"clearance_released_at": -1.0
	}
	var waiting_keys: Array[int] = []
	for r in rows:
		if r["alive"] and r["phase"] == "HOLDING" and int(r["search_key"]) != target_key:
			waiting_keys.append(int(r["search_key"]))
	_kill_event["waiting_keys"] = waiting_keys
	sim.debug_kill_airplane(target_key)

func _process(_delta: float) -> void:
	if _done:
		return
	if _shot_pending != "":
		# One frame after the phase change, so the frame shows the new phase
		_shot_n += 1
		get_viewport().get_texture().get_image().save_png(out_dir.path_join("shot_%02d_%s.png" % [_shot_n, _shot_pending]))
		_shot_pending = ""
	var rows: Array = sim.get_ai_arrival_state()
	if rows.is_empty():
		_finish(rows, 0.0)  # Nothing on the follower (wrong runway name, or the jets were removed)
		return
	var t: float = float(rows[0]["t"])
	if _initial_keys.is_empty():
		for r in rows:
			_initial_keys.append(int(r["search_key"]))
	if not _killed:
		if kill_at_sec >= 0.0 and t >= kill_at_sec and kill_jet_idx >= 0 and kill_jet_idx < rows.size():
			_trigger_kill(rows[kill_jet_idx], t, rows)
		elif kill_approach_holder or (kill_approach_at_sec >= 0.0 and t >= kill_approach_at_sec):
			for r in rows:
				if r.get("clearance_approach", false) and r.get("alive", false):
					_trigger_kill(r, t, rows)
					break
		elif kill_first_waiting:
			var waiting_count := 0
			for r in rows:
				if r["alive"] and r["phase"] == "HOLDING":
					waiting_count += 1
			if waiting_count < 2:
				_waiting_ready_at = -1.0
			elif _waiting_ready_at < 0.0:
				_waiting_ready_at = t
			for r in rows:
				# Record the follower at level 1 before killing level 0, so the trace proves its step-down.
				if waiting_count >= 2 and t - _waiting_ready_at >= SAMPLE_S * 2.0 and r["phase"] == "HOLDING" and r["stack_level"] == 0 and r["alive"]:
					_trigger_kill(r, t, rows)
					break

	if _killed and not _kill_event.is_empty():
		var target_row = null
		for r in rows:
			if int(r.get("search_key", 0)) == _kill_event["target_key"]:
				target_row = r
				break
		if _kill_event["death_confirmed_at"] < 0.0:
			if target_row == null or not target_row.get("alive", false):
				_kill_event["death_confirmed_at"] = t
		if _kill_event["clearance_released_at"] < 0.0:
			if not _kill_event["pre_kill_state"]["clearance_approach"] and not _kill_event["pre_kill_state"]["clearance_runway"]:
				_kill_event["clearance_released_at"] = t
			elif target_row == null:
				_kill_event["clearance_released_at"] = t
			elif not target_row.get("clearance_approach", false) and not target_row.get("clearance_runway", false):
				_kill_event["clearance_released_at"] = t

	var all_finished := true
	for r in rows:
		if r["alive"] and not (r["phase"] in FINISHED):
			all_finished = false
	var player_phase: String = str(rows[0]["phase"])
	if _shots and player_phase != _last_phase:
		_shot_pending = player_phase
	_last_phase = player_phase
	if t >= _next_sample:
		_next_sample = t + SAMPLE_S
		var sample := []
		for r in rows:
			sample.append([r["x"], r["y"], r["z"], r["phase"], r["ground_speed"], r["ground"], r["offpave"],
				r["holding"], r["gear"], r["flap"], r["spoiler"], r["throttle"], r["brake"], r["alive"],
				r.get("hold_state", "NONE"), r.get("radial_error", 0.0),
				r.get("search_key", 0), r.get("line", ""), r.get("assigned_alt", 0.0), r.get("stack_level", 0),
				r.get("clearance_approach", false), r.get("clearance_runway", false), r.get("terrain_clearance_agl", 0.0),
				r.get("hold_center_x", 0.0), r.get("hold_center_z", 0.0), r.get("hold_radius", 0.0)])
		_trace.append([t, sample])
	if all_finished or t >= limit_s:
		_finish(rows, t)

func _finish(rows: Array, t: float) -> void:
	_done = true
	var f := FileAccess.open(out_dir.path_join("trace.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"columns": ["x", "y", "z", "phase", "ground_speed", "ground", "offpave", "holding",
		"gear", "flap", "spoiler", "throttle", "brake", "alive", "hold_state", "radial_error",
		"search_key", "line", "assigned_alt", "stack_level", "clearance_approach", "clearance_runway", "terrain_clearance_agl",
		"hold_center_x", "hold_center_z", "hold_radius"], "samples": _trace}))
	f.close()
	var res_dict := {
		"sim_time": t,
		"timed_out": t >= limit_s,
		"initial_keys": _initial_keys,
		"aircraft": rows
	}
	if not _kill_event.is_empty():
		res_dict["kill_event"] = _kill_event
	f = FileAccess.open(out_dir.path_join("result.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(res_dict, "  "))
	f.close()
	print("Arrival test done at t=%.0f s: %s" % [t, out_dir])
	get_tree().quit(0)
