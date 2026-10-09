extends Node

# Rebuilt combat AI harness (main.gd starts it with "-- --ai-combat --combat-out <dir>"; the launcher and judge
# is tools/ai_combat_test.py). Samples every aircraft every SAMPLE_S of sim time into <dir>/trace.json (the
# per-tick control-ownership counters are kept in C++), applies the scenario's scripted events, and writes
# <dir>/result.json and quits at the time limit (--combat-limit S).
# Events: --combat-kill-at S [--combat-kill-idx I] kills aircraft I (default 1, the first target);
# --combat-move-at S [--combat-move-idx I] moves aircraft I 40 km further east (contact loss);
# --combat-jinker-idx I gives aircraft I a jinking-target autopilot (gunnery against a defending player);
# --combat-fire "T,S,W,G,K;..." makes aircraft S fire weapon type W (FSWEAPONTYPE) at aircraft G at time T,
# K = 1 keeps the shooter's lock while a human could (missile-defence fixtures);
# --combat-high selects the high difficulty (default medium); --combat-defence "key=value,..." then changes the AI's
# missile-defence settings (sweeps; keys in ai_combat.cpp).
# A2G fixtures: --combat-ground MODE ("peaceful" default, "live", "area") and --combat-ground-area "X,Z,R" (ground
# objects within R m of X/Z are sampled every row; in "area" mode only they keep their weapons; "quiet_target_area":
# all quiet and the strike plans only groups inside); result.json then
# carries the target inventory (sim/ai_combat_ground.cpp). --combat-drop "T,S,W;..." makes aircraft S release weapon
# type W (bomb / rocket / AGM-65, FSWEAPONTYPE) at time T (A2G model fixtures); every ended bomb, rocket and AGM is
# collected each tick into trace.json "ordnance_ended" (model prediction vs real impact).

const SAMPLE_S := 0.1
const MOVE_M := 40000.0

var main: Node = null
var sim: YSFlightSimulation = null
var out_dir: String = ""
var limit_s: float = 180.0
var kill_at: float = -1.0
var kill_idx: int = 1
var move_at: float = -1.0
var move_idx: int = 1
var fires: Array = [] # [t, shooter idx, weapon type, target idx, support], fired in time order
var drops: Array = [] # [t, shooter idx, weapon type], A2G releases

var _samples: Array = []
var _transitions: Array = []
var _events: Array = []
var _ordnance: Array = []
var _next_sample: float = 0.0
var _done: bool = false
var ground_mode: String = "peaceful"

func _arg_float(args: PackedStringArray, name: String, fallback: float) -> float:
	var i := args.find(name)
	return float(args[i + 1]) if i >= 0 and i + 1 < args.size() else fallback

func setup(p_main: Node, p_out_dir: String) -> void:
	process_physics_priority = 101 # after the simulation (priority 100)
	main = p_main
	sim = main.ysflight_sim
	out_dir = ProjectSettings.globalize_path(p_out_dir)
	var args := OS.get_cmdline_user_args()
	if args.find("--combat-out-stamp") >= 0: # owner fights: one folder per fight, kept for analysis
		out_dir = out_dir.path_join(Time.get_datetime_string_from_system().replace(":", "").replace("T", "_"))
	DirAccess.make_dir_recursive_absolute(out_dir)
	limit_s = _arg_float(args, "--combat-limit", limit_s)
	kill_at = _arg_float(args, "--combat-kill-at", kill_at)
	kill_idx = int(_arg_float(args, "--combat-kill-idx", kill_idx))
	move_at = _arg_float(args, "--combat-move-at", move_at)
	move_idx = int(_arg_float(args, "--combat-move-idx", move_idx))
	if "--combat-high" in args:
		sim.debug_set_combat_preset("HIGH")
	var di := args.find("--combat-defence")
	if di >= 0 and di + 1 < args.size():
		var skill := {}
		for kv in args[di + 1].split(",", false):
			var p := kv.split("=")
			skill[p[0]] = p[1] if p[0] in ["pre", "jink"] else (p[1] != "0" if p[0] == "outrun" else float(p[1]))
		sim.debug_set_defence_skill(skill)
	var fi := args.find("--combat-fire")
	if fi >= 0 and fi + 1 < args.size():
		for item in args[fi + 1].split(";", false):
			var f := item.split(",")
			fires.append([float(f[0]), int(f[1]), int(f[2]), int(f[3]), int(f[4]) != 0])
	var dri := args.find("--combat-drop")
	if dri >= 0 and dri + 1 < args.size():
		for item in args[dri + 1].split(";", false):
			var d := item.split(",")
			drops.append([float(d[0]), int(d[1]), int(d[2])])
	var gi := args.find("--combat-ground")
	var ai := args.find("--combat-ground-area")
	var area := PackedFloat64Array([0.0, 0.0, 0.0])
	if ai >= 0 and ai + 1 < args.size():
		area = PackedFloat64Array(Array(args[ai + 1].split(",")).map(func(v): return float(v)))
	ground_mode = args[gi + 1] if gi >= 0 and gi + 1 < args.size() else "peaceful"
	var rsi := args.find("--route-seed") # AI route / attack-axis randomness: 0 (default) = deterministic
	sim.debug_set_route_seed(int(args[rsi + 1]) if rsi >= 0 and rsi + 1 < args.size() else 0)
	sim.debug_set_combat_ground(ground_mode, area[0], area[1], area[2])
	var rows: Array = sim.get_ai_combat_state() # first call applies the ground mode before the first tick
	var ji := args.find("--combat-jinker-idx") # aircraft I becomes a jinking target (fixture autopilot)
	if ji >= 0 and ji + 1 < args.size() and int(args[ji + 1]) < rows.size():
		sim.debug_set_combat_jinker(int(rows[int(args[ji + 1])]["key"]))
	var ti := args.find("--combat-turner") # index,speed_mps; harness-only sustained turning opponent
	if ti >= 0 and ti + 1 < args.size():
		var turn := args[ti + 1].split(",")
		if turn.size() == 2 and int(turn[0]) >= 0 and int(turn[0]) < rows.size():
			sim.debug_set_combat_turner(int(rows[int(turn[0])]["key"]), float(turn[1]))

func _physics_process(_delta: float) -> void:
	if _done or sim == null:
		return
	var rows: Array = sim.get_ai_combat_state()
	if rows.is_empty():
		return
	var t: float = float(rows[0]["t"])
	_ordnance.append_array(rows[0].get("ordnance_ended", []))
	for r in rows:
		if r.has("combat"):
			for tr in r["combat"]["transitions"]:
				tr["key"] = r["key"]
				_transitions.append(tr)
	if kill_at >= 0.0 and t >= kill_at and kill_idx < rows.size():
		sim.debug_kill_airplane(int(rows[kill_idx]["key"]))
		_events.append({"t": t, "event": "kill", "key": rows[kill_idx]["key"]})
		kill_at = -1.0
	if move_at >= 0.0 and t >= move_at and move_idx < rows.size():
		var r: Dictionary = rows[move_idx]
		sim.debug_move_airplane(int(r["key"]), float(r["x"]) + MOVE_M, float(r["y"]), float(r["z"]))
		_events.append({"t": t, "event": "move", "key": r["key"]})
		move_at = -1.0
	for f in fires:
		if f[0] >= 0.0 and t >= f[0] and maxi(f[1], f[3]) < rows.size():
			var ok: bool = sim.debug_fire_missile(int(rows[f[1]]["key"]), f[2], int(rows[f[3]]["key"]), f[4])
			_events.append({"t": t, "event": "fire", "key": rows[f[1]]["key"], "target": rows[f[3]]["key"],
					"type": f[2], "ok": ok})
			f[0] = -1.0
	for d in drops:
		if d[0] >= 0.0 and t >= d[0] and d[1] < rows.size():
			var ok: bool = sim.debug_fire_ordnance(int(rows[d[1]]["key"]), d[2])
			_events.append({"t": t, "event": "drop", "key": rows[d[1]]["key"], "type": d[2], "ok": ok})
			d[0] = -1.0
	if t >= _next_sample:
		_next_sample = t + SAMPLE_S
		for r in rows:
			if r.has("combat"):
				r["combat"].erase("transitions")
		_samples.append(rows)
	if t >= limit_s:
		_finish(t)

func _notification(what: int) -> void:
	# Owner fights end by closing the window: save what was flown.
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _done and not _samples.is_empty():
		_finish(float(_samples[-1][0]["t"]))

func _finish(t: float) -> void:
	_done = true
	var f := FileAccess.open(out_dir.path_join("trace.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"samples": _samples, "transitions": _transitions, "events": _events,
			"ordnance_ended": _ordnance}))
	f.close()
	f = FileAccess.open(out_dir.path_join("result.json"), FileAccess.WRITE)
	var result := {"sim_time": t, "aircraft": _samples[-1] if not _samples.is_empty() else []}
	if ground_mode != "peaceful":
		result["ground_inventory"] = sim.get_combat_ground_inventory()
	f.store_string(JSON.stringify(result, "  "))
	f.close()
	print("Combat test done at t=%.0f s: %s" % [t, out_dir])
	get_tree().quit(0)
