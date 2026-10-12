extends RefCounted

# ==============================================================================
# YSFlight RvB Edition - Replay Manager Subsystem
# ==============================================================================
# Master manager for serialization, filesystem I/O, tactical analytics, and
# highlights clustering for .ysrvb flight replay archives.
#
# FULL SPECIFICATION & ARCHITECTURE REFERENCE:
# -> planning/replay_and_spectator_system.md
#
# If any issues occur, see planning/replay_and_spectator_system.md for schema,
# event structures, and clustering parameters.
# ==============================================================================

const FILE_EXTENSION := "ysrvb"
const DEFAULT_FOLDER_NAME := "YSFlight Replays"

# ------------------------------------------------------------------------------
# 1. Directory Resolution
# ------------------------------------------------------------------------------
# Resolves the absolute directory path where replay files are saved and loaded.
# Prioritizes custom settings path, then Documents/YSFlight Replays, then user://replays.
static func get_replay_dir(controls: Node = null) -> String:
	if controls != null and controls.has_method("get_replay_directory"):
		var p: String = controls.get_replay_directory()
		if not p.is_empty():
			_ensure_dir_exists(p)
			return p

	var doc_dir := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if doc_dir.is_empty():
		doc_dir = OS.get_user_data_dir()
	var target := doc_dir.path_join(DEFAULT_FOLDER_NAME)
	_ensure_dir_exists(target)
	return target

static func _ensure_dir_exists(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

# ------------------------------------------------------------------------------
# 2. Saving and Loading .ysrvb Files
# ------------------------------------------------------------------------------
# Saves a recorded replay dictionary to disk as a structured JSON .ysrvb file.
# Generates a clean timestamped filename if custom_name is omitted.
static func save_replay(replay_data: Dictionary, custom_name: String = "", dir: String = "") -> String:
	var target_dir := dir if not dir.is_empty() else get_replay_dir()
	_ensure_dir_exists(target_dir)

	var dt := Time.get_datetime_dict_from_system()
	var base_name := custom_name.strip_edges()
	if base_name.is_empty():
		var map_name: String = str(replay_data.get("metadata", {}).get("map", "FLIGHT")).replace("[RVB]", "").strip_edges()
		base_name = "Replay_%s_%04d%02d%02d_%02d%02d%02d" % [
			map_name, dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second
		]
	if not base_name.ends_with("." + FILE_EXTENSION):
		base_name += "." + FILE_EXTENSION

	# Sanitize filename characters
	base_name = base_name.replace(":", "_").replace("/", "_").replace("\\", "_")
	var full_path := target_dir.path_join(base_name)

	var file := FileAccess.open(full_path, FileAccess.WRITE)
	if file == null:
		push_error("ReplayManager: Failed to open file for writing: " + full_path)
		return ""

	# Serialize with tab indentation for readable debugging and robust parsing
	var json_str := JSON.stringify(replay_data, "\t")
	file.store_string(json_str)
	file.close()

	return full_path

# Loads and validates a .ysrvb replay file. Returns an empty Dictionary on failure.
static func load_replay(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("ReplayManager: Replay file does not exist: " + path)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("ReplayManager: Failed to open replay for reading: " + path)
		return {}

	var content := file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(content)
	if not (parsed is Dictionary):
		push_error("ReplayManager: Corrupt or invalid JSON structure in: " + path)
		return {}

	return parsed

# ------------------------------------------------------------------------------
# 3. Listing Available Replays
# ------------------------------------------------------------------------------
# Scans the target replay directory and returns metadata summaries of all .ysrvb files.
# Sorted by timestamp descending (newest replays appear first).
static func list_replays(dir: String = "") -> Array[Dictionary]:
	var target_dir := dir if not dir.is_empty() else get_replay_dir()
	var out: Array[Dictionary] = []
	if not DirAccess.dir_exists_absolute(target_dir):
		return out

	var d := DirAccess.open(target_dir)
	if d == null:
		return out

	d.list_dir_begin()
	var fname := d.get_next()
	while not fname.is_empty():
		if not d.current_is_dir() and fname.ends_with("." + FILE_EXTENSION):
			var full_path := target_dir.path_join(fname)
			var meta := _read_replay_header(full_path)
			meta["file_name"] = fname
			meta["file_path"] = full_path
			out.append(meta)
		fname = d.get_next()
	d.list_dir_end()

	# Sort newest first based on file modified time or created_at
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("created_at", 0.0)) > float(b.get("created_at", 0.0)))
	return out

# Fast inspection of a replay file: reads metadata without parsing the entire telemetry stream.
static func _read_replay_header(path: String) -> Dictionary:
	var default_meta: Dictionary = {
		"map": "UNKNOWN",
		"duration": 0.0,
		"created_at": FileAccess.get_modified_time(path),
		"pilots_count": 0,
		"kills_count": 0,
		"player_callsign": "PILOT"
	}

	var full := load_replay(path)
	if full.has("metadata"):
		var m: Dictionary = full["metadata"]
		default_meta["map"] = str(m.get("map", default_meta["map"]))
		default_meta["duration"] = float(m.get("duration", 0.0))
		default_meta["created_at"] = int(m.get("created_at", default_meta["created_at"]))
		default_meta["player_callsign"] = str(m.get("player_callsign", default_meta["player_callsign"]))
		default_meta["pilots_count"] = full.get("roster", []).size()
		default_meta["kills_count"] = full.get("events", []).size()
	return default_meta

# ------------------------------------------------------------------------------
# 4. Highlights Reel Clustering Algorithm
# ------------------------------------------------------------------------------
# Detects combat turning points and dogfight furballs.
# An event is flagged as a highlight cluster when:
#   min_kills (default 2) occur within a window_s (default 20s) inside max_radius_m (3500m).
# Full algorithm design in planning/replay_and_spectator_system.md "Section 6".
static func detect_highlights(events: Array, window_s: float = 20.0, min_kills: int = 2, max_radius_m: float = 3500.0) -> Array[Dictionary]:
	var kills: Array[Dictionary] = []
	for ev in events:
		if ev is Dictionary and str(ev.get("type", "")) == "kill":
			kills.append(ev)

	var clusters: Array[Dictionary] = []
	var visited: Dictionary = {}

	for i in range(kills.size()):
		if visited.has(i):
			continue
		var k1 := kills[i]
		var t1 := float(k1.get("time", 0.0))
		var pos1_arr = k1.get("pos", [0, 0, 0])
		var p1 := Vector3(float(pos1_arr[0]), float(pos1_arr[1]), float(pos1_arr[2]))

		var cluster_indices: Array[int] = [i]
		var center_sum: Vector3 = p1

		for j in range(i + 1, kills.size()):
			if visited.has(j):
				continue
			var k2 := kills[j]
			var t2 := float(k2.get("time", 0.0))
			if t2 - t1 > window_s:
				break

			var pos2_arr = k2.get("pos", [0, 0, 0])
			var p2 := Vector3(float(pos2_arr[0]), float(pos2_arr[1]), float(pos2_arr[2]))

			if p1.distance_to(p2) <= max_radius_m:
				cluster_indices.append(j)
				center_sum += p2

		if cluster_indices.size() >= min_kills:
			for idx in cluster_indices:
				visited[idx] = true

			var first_k: Dictionary = kills[cluster_indices[0]]
			var last_k: Dictionary = kills[cluster_indices[-1]]
			var start_t: float = maxf(0.0, float(first_k.get("time", 0.0)) - 5.0)
			var end_t: float = float(last_k.get("time", 0.0)) + 5.0
			var centroid := center_sum / float(cluster_indices.size())

			var desc := "FURBALL: %d KILLS IN %ds" % [
				cluster_indices.size(),
				roundi(float(last_k.get("time", 0.0)) - float(first_k.get("time", 0.0)) + 1.0)
			]

			clusters.append({
				"title": desc,
				"start_time": start_t,
				"end_time": end_t,
				"peak_time": float(first_k.get("time", 0.0)),
				"kill_count": cluster_indices.size(),
				"position": [centroid.x, centroid.y, centroid.z]
			})

	return clusters

# ------------------------------------------------------------------------------
# 5. Tactical Statistics Aggregators
# ------------------------------------------------------------------------------
# Computes aircraft utilization and combat lethality across the match.
# Returns sorted array from most-flown to least-flown aircraft.
static func compute_aircraft_statistics(replay_data: Dictionary) -> Array[Dictionary]:
	var stats: Dictionary = {} # aircraft_name -> Dictionary
	var roster: Array = replay_data.get("roster", [])
	for pilot in roster:
		var ac: String = str(pilot.get("aircraft", "UNKNOWN")).strip_edges()
		if ac.is_empty():
			continue
		if not stats.has(ac):
			stats[ac] = {
				"aircraft": ac,
				"sorties": 0,
				"air_kills": 0,
				"ground_kills": 0,
				"deaths": 0,
				"pilots": []
			}
		stats[ac]["sorties"] += 1
		var pname: String = str(pilot.get("name", ""))
		if not stats[ac]["pilots"].has(pname):
			stats[ac]["pilots"].append(pname)

	# Aggregate kills and deaths from events
	for ev in replay_data.get("events", []):
		if not (ev is Dictionary):
			continue
		var ev_type := str(ev.get("type", ""))
		if ev_type == "kill":
			var killer_ac: String = str(ev.get("killer_aircraft", ""))
			var victim_ac: String = str(ev.get("victim_aircraft", ""))
			var is_ground: bool = bool(ev.get("ground", false))

			if not killer_ac.is_empty() and stats.has(killer_ac):
				if is_ground:
					stats[killer_ac]["ground_kills"] += 1
				else:
					stats[killer_ac]["air_kills"] += 1

			if not victim_ac.is_empty() and stats.has(victim_ac):
				stats[victim_ac]["deaths"] += 1

	var list: Array[Dictionary] = []
	for ac in stats:
		var item: Dictionary = stats[ac]
		var total_k: int = item["air_kills"] + item["ground_kills"]
		var d: int = item["deaths"]
		item["kd_ratio"] = "%.2f" % (float(total_k) / float(maxi(d, 1)))
		list.append(item)

	# Sort: most sorties first, then most kills
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["sorties"] != b["sorties"]:
			return a["sorties"] > b["sorties"]
		return (a["air_kills"] + a["ground_kills"]) > (b["air_kills"] + b["ground_kills"]))

	return list

# Computes ground threat lethality (SAMs, mobile AAA, ships, command posts).
# Identifies most deadly ground units and most frequently destroyed targets.
static func compute_ground_statistics(replay_data: Dictionary) -> Dictionary:
	var destroyed_targets: Dictionary = {} # target_name -> count
	var ground_threat_kills: Dictionary = {} # ground_unit_name -> kills caused

	for ev in replay_data.get("events", []):
		if not (ev is Dictionary):
			continue
		var ev_type := str(ev.get("type", ""))
		if ev_type == "kill":
			var is_ground: bool = bool(ev.get("ground", false))
			var victim: String = str(ev.get("victim_name", ""))
			var killer: String = str(ev.get("killer_name", ""))

			if is_ground and not victim.is_empty():
				destroyed_targets[victim] = destroyed_targets.get(victim, 0) + 1

			var killer_is_ground: bool = bool(ev.get("killer_is_ground", false))
			if killer_is_ground and not killer.is_empty():
				ground_threat_kills[killer] = ground_threat_kills.get(killer, 0) + 1

	return {
		"most_destroyed": _dict_to_sorted_list(destroyed_targets, "target", "count"),
		"most_deadly": _dict_to_sorted_list(ground_threat_kills, "threat", "kills")
	}

static func _dict_to_sorted_list(dict: Dictionary, key_name: String, val_name: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for k in dict:
		out.append({key_name: k, val_name: dict[k]})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a[val_name] > b[val_name])
	return out
