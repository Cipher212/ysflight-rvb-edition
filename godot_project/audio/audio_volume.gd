extends Node

# Player volume sliders (Settings > Audio). Each category gets its own bus that the game's buses feed into, so a
# slider never fights the cockpit ducking that audio/audio_buses.gd does on Others / Effects:
#   PlayerEngine + Others -> VolEngines, Effects -> VolEffects, Cockpit -> VolWarnings, all -> Master.
# Music, Radio and Menu are placeholder buses (nothing plays on them yet). Values are 0..1 (linear), saved with
# the other settings. Not created in benchmark runs (the benchmark mutes Master).

const CATEGORIES := { # setting key -> bus
	"volume_master": "Master",
	"volume_engines": "VolEngines",
	"volume_effects": "VolEffects",
	"volume_warnings": "VolWarnings",
	"volume_music": "Music",
	"volume_radio": "Radio",
	"volume_menu": "Menu",
}
const ROUTES := {"PlayerEngine": "VolEngines", "Others": "VolEngines", "Effects": "VolEffects", "Cockpit": "VolWarnings"}

var controls: Node = null

func setup(p_controls: Node) -> void:
	name = "AudioVolume"
	controls = p_controls
	for bus in CATEGORIES.values():
		_ensure_bus(bus)
	for from in ROUTES:
		var idx := AudioServer.get_bus_index(from)
		if idx >= 0:
			AudioServer.set_bus_send(idx, ROUTES[from])
	controls.changed.connect(func(key: String) -> void:
		if key.is_empty() or CATEGORIES.has(key):
			apply())
	apply()

func apply() -> void:
	for key in CATEGORIES:
		var v: float = clampf(float(controls.get_value(key, 1.0)), 0.0, 1.0)
		var idx := AudioServer.get_bus_index(CATEGORIES[key])
		AudioServer.set_bus_mute(idx, v <= 0.0)
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(v, 0.0001)))

func _ensure_bus(bus: String) -> void:
	if AudioServer.get_bus_index(bus) >= 0:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus)
	AudioServer.set_bus_send(idx, "Master")
