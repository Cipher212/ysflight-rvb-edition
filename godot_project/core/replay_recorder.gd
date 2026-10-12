extends Node

# ==============================================================================
# YSFlight RvB Edition - In-Flight Replay Recorder
# ==============================================================================
# Records high-fidelity flight telemetry, per-tick missile and ordnance trajectories,
# and tactical combat events for post-flight review and live scoreboard progression.
#
# FULL SPECIFICATION & ARCHITECTURE REFERENCE:
# -> planning/replay_and_spectator_system.md
#
# If any issues occur, see planning/replay_and_spectator_system.md for schema,
# weapon capture details, and autosave flow.
# ==============================================================================

const ReplayManager := preload("res://core/replay_manager.gd")
const SAMPLE_INTERVAL: float = 0.1 # 10 Hz telemetry capture rate

signal replay_saved(path: String)

var main: Node = null
var sim: YSFlightSimulation = null
var config: Dictionary = {}

var is_recording: bool = false
var _elapsed: float = 0.0
var _sample_timer: float = 0.0

var _metadata: Dictionary = {}
var _roster: Array = []
var _frames: Array[Dictionary] = []
var _events: Array[Dictionary] = []

var _last_kill_count: int = 0
var _active_weapon_history: Dictionary = {} # weapon_id -> trajectory points
var _finalized_data: Dictionary = {}

func setup(p_main: Node, p_sim: YSFlightSimulation, p_config: Dictionary = {}) -> void:
	name = "ReplayRecorder"
	main = p_main
	sim = p_sim
	config = p_config.duplicate(true)
	_reset()
	_init_metadata()
	is_recording = true

func _reset() -> void:
	_elapsed = 0.0
	_sample_timer = 0.0
	_metadata.clear()
	_roster.clear()
	_frames.clear()
	_events.clear()
	_last_kill_count = 0
	_active_weapon_history.clear()
	_finalized_data.clear()

func _init_metadata() -> void:
	var dt := Time.get_datetime_dict_from_system()
	_metadata = {
		"version": 1,
		"created_at": Time.get_unix_time_from_system(),
		"date_string": "%04d-%02d-%02d %02d:%02d:%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second],
		"map": str(config.get("map", "LUAVI")),
		"player_callsign": str(config.get("player_name", "PLAYER")),
		"player_team": str(config.get("player_team", "blue")),
		"duration": 0.0,
		"is_event": bool(main != null and main.get("event_mode") == true)
	}

	# Cache initial roster
	if sim != null and sim.has_method("get_event_roster"):
		_roster = sim.get_event_roster()
	if _roster.is_empty() and config.has("pilots"):
		_roster = config.get("pilots", []).duplicate(true)

func _physics_process(delta: float) -> void:
	if not is_recording or sim == null:
		return

	_elapsed += delta
	_sample_timer += delta

	# Poll event state for kills/combat events
	_poll_combat_events()

	# Sample telemetry at 10 Hz
	if _sample_timer >= SAMPLE_INTERVAL:
		_sample_timer -= SAMPLE_INTERVAL
		_record_frame()

# Samples aircraft positions and active ordnance trajectories
func _record_frame() -> void:
	var frame: Dictionary = {
		"time": snappedf(_elapsed, 0.01),
		"aircraft": [],
		"weapons": []
	}

	# 1. Capture Player Aircraft Telemetry
	var player_xform: Transform3D = sim.get_player_transform()
	var player_tel: Dictionary = sim.get_player_telemetry()
	var player_alive: bool = bool(player_tel.get("is_alive", true))

	frame["aircraft"].append({
		"id": 0,
		"name": _metadata.get("player_callsign", "PLAYER"),
		"team": _metadata.get("player_team", "blue"),
		"pos": [snappedf(player_xform.origin.x, 0.1), snappedf(player_xform.origin.y, 0.1), snappedf(player_xform.origin.z, 0.1)],
		"basis": [
			[snappedf(player_xform.basis.x.x, 0.001), snappedf(player_xform.basis.x.y, 0.001), snappedf(player_xform.basis.x.z, 0.001)],
			[snappedf(player_xform.basis.y.x, 0.001), snappedf(player_xform.basis.y.y, 0.001), snappedf(player_xform.basis.y.z, 0.001)],
			[snappedf(player_xform.basis.z.x, 0.001), snappedf(player_xform.basis.z.y, 0.001), snappedf(player_xform.basis.z.z, 0.001)]
		],
		"speed_kt": snappedf(float(player_tel.get("speed_kt", 0.0)), 0.1),
		"alt_ft": snappedf(float(player_tel.get("altitude_ft", 0.0)), 1.0),
		"g_load": snappedf(float(player_tel.get("g_force", 1.0)), 0.1),
		"afterburner": bool(player_tel.get("afterburner", false)),
		"gear": snappedf(float(player_tel.get("gear", 0.0)), 0.01),
		"alive": player_alive
	})

	# 2. Capture Other Aircraft (via sim.get_airplane_transforms())
	if sim.has_method("get_airplane_transforms"):
		var xforms = sim.get_airplane_transforms()
		if xforms is Dictionary:
			for key in xforms:
				var xf = xforms[key]
				if not (xf is Transform3D):
					continue
				frame["aircraft"].append({
					"id": int(key),
					"pos": [snappedf(xf.origin.x, 0.1), snappedf(xf.origin.y, 0.1), snappedf(xf.origin.z, 0.1)],
					"basis": [
						[snappedf(xf.basis.x.x, 0.001), snappedf(xf.basis.x.y, 0.001), snappedf(xf.basis.x.z, 0.001)],
						[snappedf(xf.basis.y.x, 0.001), snappedf(xf.basis.y.y, 0.001), snappedf(xf.basis.y.z, 0.001)],
						[snappedf(xf.basis.z.x, 0.001), snappedf(xf.basis.z.y, 0.001), snappedf(xf.basis.z.z, 0.001)]
					]
				})
		elif xforms is Array:
			for i in range(xforms.size()):
				if not (xforms[i] is Transform3D):
					continue
				var xf: Transform3D = xforms[i]
				frame["aircraft"].append({
					"id": i + 1,
					"pos": [snappedf(xf.origin.x, 0.1), snappedf(xf.origin.y, 0.1), snappedf(xf.origin.z, 0.1)],
					"basis": [
						[snappedf(xf.basis.x.x, 0.001), snappedf(xf.basis.x.y, 0.001), snappedf(xf.basis.x.z, 0.001)],
						[snappedf(xf.basis.y.x, 0.001), snappedf(xf.basis.y.y, 0.001), snappedf(xf.basis.y.z, 0.001)],
						[snappedf(xf.basis.z.x, 0.001), snappedf(xf.basis.z.y, 0.001), snappedf(xf.basis.z.z, 0.001)]
					]
				})

	# 3. Capture Active Weapons & Missiles (Ref: planning/replay_and_spectator_system.md)
	# Records full ordnance trajectories (AIM-9, AIM-120, AGM-65, Bombs, Rockets)
	if sim.has_method("get_active_weapons"):
		var active_wpns: Array = sim.get_active_weapons()
		for w in active_wpns:
			if not (w is Dictionary):
				continue
			var w_pos: Vector3 = w.get("pos", Vector3.ZERO)
			var w_id: int = int(w.get("slot_id", 0))
			var w_type: int = int(w.get("type", 0))

			frame["weapons"].append({
				"id": w_id,
				"type": w_type,
				"pos": [snappedf(w_pos.x, 0.1), snappedf(w_pos.y, 0.1), snappedf(w_pos.z, 0.1)],
				"life": snappedf(float(w.get("life_remain", 0.0)), 0.1)
			})

	_frames.append(frame)

# Checks for new kills or match events from the simulation
func _poll_combat_events() -> void:
	if not (sim != null and sim.has_method("get_event_results")):
		return

	var res: Dictionary = sim.get_event_results()
	var kills: Array = res.get("kills", [])
	if kills.size() > _last_kill_count:
		for i in range(_last_kill_count, kills.size()):
			var k: Dictionary = kills[i]
			_events.append({
				"time": float(k.get("time", _elapsed)),
				"type": "kill",
				"killer_name": str(k.get("killer", "")),
				"killer_team": str(k.get("killer_team", "")),
				"victim_name": str(k.get("victim", "")),
				"victim_team": str(k.get("victim_team", "")),
				"weapon": str(k.get("how", "WEAPON")),
				"ground": bool(k.get("ground", false)),
				"team_kill": bool(k.get("team_kill", false)),
				"pos": [0, 0, 0] # Approximate centroid
			})
		_last_kill_count = kills.size()

# Finalizes the recorded session data into exportable dictionary
func finalize_recording() -> Dictionary:
	is_recording = false
	_metadata["duration"] = snappedf(_elapsed, 0.1)
	_metadata["frames_count"] = _frames.size()
	_metadata["events_count"] = _events.size()

	# Refresh final roster
	if sim != null and sim.has_method("get_event_roster"):
		var live_roster = sim.get_event_roster()
		if not live_roster.is_empty():
			_roster = live_roster

	_finalized_data = {
		"metadata": _metadata,
		"roster": _roster,
		"frames": _frames,
		"events": _events
	}
	return _finalized_data

# Checks autosave setting and automatically writes replay to disk if enabled
func check_and_autosave(controls: Node = null) -> String:
	if _finalized_data.is_empty():
		finalize_recording()

	var autosave_enabled := false
	if controls != null and controls.has_method("is_autosave_replays_enabled"):
		autosave_enabled = controls.is_autosave_replays_enabled()

	if autosave_enabled:
		var saved_path := ReplayManager.save_replay(_finalized_data, "", ReplayManager.get_replay_dir(controls))
		if not saved_path.is_empty():
			print("ReplayRecorder: Autosaved replay to: ", saved_path)
			replay_saved.emit(saved_path)
			return saved_path
	return ""
