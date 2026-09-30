extends RefCounted

# Writes the YSFlight mission (.yfs) for an offline event: only the map and the weapon rules. It has no
# aircraft: the event spawns its AI pilots in the air from the config (sim/event_match.cpp) and the player picks
# a jet in the spawn menu (ui/spawn_menu.gd).

const MISSION_PATH := "user://rvb_event_mission.yfs"

static func write(cfg: Dictionary) -> String:
	var lines := PackedStringArray([
		"YFSVERSI 20141101",
		"SIMTITLE \"RvB offline event\"",
		"FIELDNAM %s 0 0 0 0 0 0 TRUE" % str(cfg["map"]),
		"ALLOWAAM TRUE",
		"ALLOWGUN TRUE",
		"ALLOWAGM TRUE",
		"ALLOWBOM TRUE",
		"ALLOWRKT TRUE",
	])
	var f := FileAccess.open(MISSION_PATH, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string("\n".join(lines) + "\n")
	return MISSION_PATH
