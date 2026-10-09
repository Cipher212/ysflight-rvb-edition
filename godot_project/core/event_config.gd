extends RefCounted

# Offline RvB event config: the one data structure the match builder writes, the game reads at launch and the
# debrief shows (decoupled through user:// JSON files). Pure data + helpers, no UI. Format: logs/UI_scheme.md
# "Event data". C++ side: gdextension/ysflight/src/sim/event_match.h (same limits).

const CONFIG_PATH := "user://rvb_event.json"
const RESULTS_PATH := "user://rvb_event_results.json"
const MAX_PER_SIDE := 18       # EventMatch::MAX_PER_SIDE (user: hard cap 18 v 18)
const MIN_MINUTES := 5
const MAX_MINUTES := 120
const MAPS := [{"id": "[RVB]LUAVI", "label": "LUAVI"}]
const DIFFICULTIES := ["STANDARD"]             # placeholder: every AI flies the same for now
const TIMES_OF_DAY := ["STATIC", "DYNAMIC"]     # STATIC: fixed daylight; DYNAMIC: dawn-to-night cycle
# Placeholder pilot names (callsign-style, short enough for the roster and debrief tables)
const NAMES := ["BOB", "JIM", "TIM", "SAM", "MAX", "LEO", "RAY", "KAI", "ZED", "NED", "OWEN", "EVAN", "HANK",
	"IVAN", "JACK", "KURT", "LUKE", "MARK", "NICK", "OTTO", "PAUL", "RICK", "SEAN", "TOBY", "VICK", "WADE",
	"ALEX", "BART", "CODY", "DREW", "ERIC", "FINN", "GARY", "HUGO", "IGOR", "JOEL", "KARL", "LARS", "MILO",
	"NILS", "OLAF", "PETE", "QUIN", "ROSS", "STAN", "TROY", "URI", "VERN", "WALT", "XAVI", "YURI", "ZANE",
	"ACE", "BUD", "COLE", "DAX", "ELI", "FOX", "GUS", "HAL"]

static func defaults() -> Dictionary:
	return {
		"version": 1,
		"team_size": 8,
		"map": MAPS[0]["id"],
		"player_team": "blue",
		"player_name": "PLAYER",
		"ai_difficulty": DIFFICULTIES[0],
		"time_of_day": TIMES_OF_DAY[0],
		"duration_min": 20,
		"rules": {"collisions": true, "friendly_fire": false},
		"pilots": [],   # [{"name", "team" ("blue"/"red"), "aircraft" (YS identifier)}]; role comes from the aircraft
	}

# Clamps and fills a config read from disk or built by the UI, so the game never gets bad values.
static func validated(cfg: Dictionary) -> Dictionary:
	var out := defaults()
	for k in out.keys():
		if cfg.has(k):
			out[k] = cfg[k]
	out["duration_min"] = clampi(int(out["duration_min"]), MIN_MINUTES, MAX_MINUTES)
	out["team_size"] = 16 if int(out["team_size"]) == 16 else 8
	out["player_team"] = "red" if str(out["player_team"]) == "red" else "blue"
	var rules: Dictionary = defaults()["rules"]
	if out["rules"] is Dictionary:
		for k in rules.keys():
			rules[k] = bool((out["rules"] as Dictionary).get(k, rules[k]))
	out["rules"] = rules
	var kept := []
	var per_side := {"blue": 0, "red": 0}
	for p in out["pilots"]:
		if not (p is Dictionary) or str(p.get("aircraft", "")) == "":
			continue
		var team := "red" if str(p.get("team", "")) == "red" else "blue"
		if per_side[team] >= MAX_PER_SIDE:
			continue
		per_side[team] += 1
		kept.append({"name": str(p.get("name", "AI")).to_upper(), "team": team, "aircraft": str(p["aircraft"])})
	out["pilots"] = kept
	return out

static func save(cfg: Dictionary, path: String = CONFIG_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(validated(cfg), "\t"))
	return true

static func load_config(path: String = CONFIG_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return defaults()
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return validated(parsed if parsed is Dictionary else {})

static func count(cfg: Dictionary, team: String) -> int:
	var n := 0
	for p in cfg["pilots"]:
		if p["team"] == team:
			n += 1
	return n

# Setup stores a complete side; the lobby replaces one slot with the human after team choice.
static func fit_team_sizes(cfg: Dictionary, catalog: Array) -> void:
	var target := int(cfg.get("team_size", 8))
	var kept: Array = []
	var counts := {"blue": 0, "red": 0}
	for pilot in cfg["pilots"]:
		var team: String = pilot["team"]
		if counts[team] < target and role_of(catalog, pilot["aircraft"]) != "?":
			kept.append(pilot)
			counts[team] += 1
	cfg["pilots"] = kept
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for team in ["blue", "red"]:
		fill(cfg, catalog, team, target - count(cfg, team), "", rng)

static func with_human_slot(cfg: Dictionary, team: String) -> Dictionary:
	var match_config := cfg.duplicate(true)
	match_config["player_team"] = team
	for i in range(match_config["pilots"].size() - 1, -1, -1):
		if match_config["pilots"][i]["team"] == team:
			match_config["pilots"].remove_at(i)
			break
	return match_config

# A name not used yet in this event (placeholder list, then numbered).
static func free_name(cfg: Dictionary, rng: RandomNumberGenerator) -> String:
	var used := {}
	for p in cfg["pilots"]:
		used[p["name"]] = true
	var pool := []
	for n in NAMES:
		if not used.has(n):
			pool.append(n)
	if not pool.is_empty():
		return pool[rng.randi_range(0, pool.size() - 1)]
	var i := 2
	while used.has("AI-%d" % i):
		i += 1
	return "AI-%d" % i

# Aircraft of the catalog (YSFlightSimulation.get_aircraft_catalog()) for a team, optionally one role.
static func aircraft_for(catalog: Array, team: String, role: String = "") -> Array:
	var out := []
	var seen := {}
	for a in catalog:
		if a["team"] == team and (role == "" or a["role"] == role):
			var id: String = a.get("identifier", "")
			if not seen.has(id):
				seen[id] = true
				out.append(a)
	return out

static func role_of(catalog: Array, identifier: String) -> String:
	for a in catalog:
		if a["identifier"] == identifier:
			return a["role"]
	return "?"

# Quick-fill: adds up to n pilots of a role (random aircraft of that role) to a team, within the cap.
static func fill(cfg: Dictionary, catalog: Array, team: String, n: int, role: String, rng: RandomNumberGenerator) -> void:
	var choices := aircraft_for(catalog, team, role)
	if choices.is_empty():
		return
	for i in n:
		if count(cfg, team) >= MAX_PER_SIDE:
			return
		var a: Dictionary = choices[rng.randi_range(0, choices.size() - 1)]
		cfg["pilots"].append({"name": free_name(cfg, rng), "team": team, "aircraft": a["identifier"]})

# Mirror: the other side gets the same roles in the same order (its own team's aircraft of that role,
# nearest match; the original pilots of that side are replaced).
static func mirror(cfg: Dictionary, catalog: Array, from_team: String, rng: RandomNumberGenerator) -> void:
	var to_team := "red" if from_team == "blue" else "blue"
	var kept := []
	for p in cfg["pilots"]:
		if p["team"] != to_team:
			kept.append(p)
	cfg["pilots"] = kept
	var source := []
	for p in cfg["pilots"]:
		if p["team"] == from_team:
			source.append(p)
	for p in source:
		var choices := aircraft_for(catalog, to_team, role_of(catalog, p["aircraft"]))
		if choices.is_empty():
			choices = aircraft_for(catalog, to_team)
		if choices.is_empty():
			return
		var a: Dictionary = choices[rng.randi_range(0, choices.size() - 1)]
		cfg["pilots"].append({"name": free_name(cfg, rng), "team": to_team, "aircraft": a["identifier"]})
