extends RefCounted

# Offline event results (user://rvb_event_results.json, written by core/event_session.gd from the C++ stats):
# loading, per-team totals and CSV export for the debrief. Format: logs/UI_scheme.md "Event data".

const EventConfig := preload("res://core/event_config.gd")
const CLASSES := ["gun", "aam", "agm", "bomb", "rocket"]
const EXPORT_DIR := "results" # next to the game's launchers (res:// is the project folder, its parent the game)

static func load_results() -> Dictionary:
	if not FileAccess.file_exists(EventConfig.RESULTS_PATH):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(EventConfig.RESULTS_PATH))
	return parsed if parsed is Dictionary else {}

# Pilots sorted for the debrief: kills (air + ground) descending, then deaths ascending, then name.
static func ranked(results: Dictionary, team: String = "") -> Array:
	var out := []
	for p in results.get("pilots", []):
		if team == "" or p["team"] == team:
			out.append(p)
	out.sort_custom(func(a, b):
		var ka: int = int(a["air_kills"]) + int(a["ground_kills"])
		var kb: int = int(b["air_kills"]) + int(b["ground_kills"])
		if ka != kb:
			return ka > kb
		if int(a["deaths"]) != int(b["deaths"]):
			return int(a["deaths"]) < int(b["deaths"])
		return str(a["name"]) < str(b["name"]))
	return out

static func team_totals(results: Dictionary, team: String) -> Dictionary:
	var t := {"air_kills": 0, "ground_kills": 0, "deaths": 0, "team_kills": 0, "fired": 0, "hits": 0}
	for p in results.get("pilots", []):
		if p["team"] != team:
			continue
		for k in ["air_kills", "ground_kills", "deaths", "team_kills"]:
			t[k] += int(p[k])
		for c in CLASSES:
			if c != "gun":
				t["fired"] += int(p["fired"].get(c, 0))
				t["hits"] += int(p["hits"].get(c, 0))
	return t

# Missile / bomb / rocket hit rate as text ("3/8 38%"), or "-" if nothing was fired.
static func hit_rate(p: Dictionary) -> String:
	var fired := 0
	var hits := 0
	for c in CLASSES:
		if c != "gun":
			fired += int(p["fired"].get(c, 0))
			hits += int(p["hits"].get(c, 0))
	if fired == 0:
		return "-"
	return "%d/%d %d%%" % [hits, fired, roundi(100.0 * hits / fired)]

static func to_csv(results: Dictionary) -> String:
	var lines := PackedStringArray()
	var cols := PackedStringArray(["pilot", "team", "aircraft", "role", "air_kills", "ground_kills", "team_kills",
		"deaths", "crashes", "leaves"])
	for c in CLASSES:
		cols.append(c + "_fired")
		cols.append(c + "_hits")
	lines.append(",".join(cols))
	for p in ranked(results):
		var row := PackedStringArray([_csv(p["name"]), p["team"], _csv(p["aircraft"]), p["role"],
			str(int(p["air_kills"])), str(int(p["ground_kills"])), str(int(p["team_kills"])), str(int(p["deaths"])),
			str(int(p["crashes"])), str(int(p.get("leaves", 0)))])
		for c in CLASSES:
			row.append(str(int(p["fired"].get(c, 0))))
			row.append(str(int(p["hits"].get(c, 0))))
		lines.append(",".join(row))
	lines.append("")
	lines.append("time_s,killer,killer_team,victim,victim_team,how,ground,team_kill")
	for k in results.get("kills", []):
		lines.append(",".join(PackedStringArray(["%.1f" % float(k["time"]), _csv(k["killer"]), k["killer_team"],
			_csv(k["victim"]), k["victim_team"], k["how"], str(k["ground"]), str(k["team_kill"])])))
	return "\n".join(lines) + "\n"

# Writes <game folder>/results/rvb_event_<date>_<time>.csv. Returns the absolute path, or "" on failure.
static func export_csv(results: Dictionary) -> String:
	var dir := ProjectSettings.globalize_path("res://").get_base_dir().get_base_dir().path_join(EXPORT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")
	var path := dir.path_join("rvb_event_%s.csv" % stamp)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(to_csv(results))
	return path

static func _csv(v) -> String:
	var s := str(v)
	return "\"%s\"" % s.replace("\"", "\"\"") if s.contains(",") or s.contains("\"") else s
