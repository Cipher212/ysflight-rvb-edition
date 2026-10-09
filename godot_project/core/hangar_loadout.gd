extends RefCounted

# Editable staging data. Native validation remains authoritative at preview and spawn.
var sim: YSFlightSimulation
var identifier := ""
var points: Array = []
var specs: Dictionary = {}
var slots: Array = []
var fuel := 100.0
var selected := 0

func setup(p_sim: YSFlightSimulation, name: String) -> void:
	sim = p_sim
	identifier = name
	points = sim.get_aircraft_hardpoints(name)
	specs = sim.get_aircraft_specs(name)
	slots = specs.get("default_slots", []).duplicate(true)
	fuel = float(specs.get("default_fuel_percent", 100.0))
	selected = 0

func options(station: int) -> Array:
	var out: Array = [{"weapon": "EMPTY", "capacity": 0}]
	if station < 0 or station >= points.size():
		return out
	var mirror := int(points[station]["mirror"])
	for entry in points[station]["allowed"]:
		var option: Dictionary = entry.duplicate()
		if mirror >= 0:
			var cap := 0
			for other in points[mirror]["allowed"]:
				if other["weapon"] == option["weapon"]:
					cap = mini(int(option["capacity"]), int(other["capacity"]))
			if cap == 0:
				continue
			option["capacity"] = cap
		out.append(option)
	return out

func set_weapon(code: String, count: int) -> void:
	if selected >= slots.size():
		return
	for option in options(selected):
		if option["weapon"] != code:
			continue
		var n := clampi(count, 0 if code == "EMPTY" else 1, int(option["capacity"]))
		_set_station(selected, code, n)
		var mirror := int(points[selected]["mirror"])
		if mirror >= 0:
			_set_station(mirror, code, n)
		return

func _set_station(station: int, code: String, count: int) -> void:
	slots[station] = {"station": station, "weapon": code, "count": count}

func validation() -> Dictionary:
	return sim.validate_aircraft_configuration(identifier, fuel, slots)

func snapshot() -> Dictionary:
	return {"fuel": fuel, "slots": slots.duplicate(true)}

func restore(data: Dictionary) -> String:
	if not data.get("slots", null) is Array:
		return "Preset has no valid stations."
	var check: Dictionary = sim.validate_aircraft_configuration(identifier, float(data.get("fuel", 100.0)), data["slots"])
	if not check.get("ok", false):
		return str(check.get("error", "Invalid preset."))
	fuel = float(data.get("fuel", 100.0))
	slots = check["slots"].duplicate(true)
	return ""
