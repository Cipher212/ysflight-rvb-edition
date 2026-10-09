extends RefCounted

const PATH := "user://rvb_loadouts.json"
const MAX_PER_AIRCRAFT := 24
var _aircraft: Dictionary = {}
var _path: String

func _init(path: String = PATH) -> void:
	_path = path
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path)) if FileAccess.file_exists(_path) else null
	if parsed is Dictionary and parsed.get("aircraft", null) is Dictionary:
		_aircraft = parsed["aircraft"]

func names(identifier: String) -> Array:
	var records: Variant = _aircraft.get(identifier, {})
	if not records is Dictionary:
		return []
	var out: Array = records.keys()
	out.sort()
	return out

func get_preset(identifier: String, title: String) -> Dictionary:
	var records: Variant = _aircraft.get(identifier, {})
	if records is Dictionary and records.get(title, null) is Dictionary:
		return records[title].duplicate(true)
	return {}

func save_preset(identifier: String, title: String, data: Dictionary) -> String:
	title = title.strip_edges().left(24)
	if title.is_empty():
		return "Enter a preset name."
	var records: Dictionary = _aircraft.get(identifier, {}) if _aircraft.get(identifier, {}) is Dictionary else {}
	if records.size() >= MAX_PER_AIRCRAFT and not records.has(title):
		return "This aircraft already has 24 presets."
	records[title] = data.duplicate(true)
	_aircraft[identifier] = records
	return _write()

func delete_preset(identifier: String, title: String) -> String:
	if _aircraft.get(identifier, null) is Dictionary:
		_aircraft[identifier].erase(title)
	return _write()

func _write() -> String:
	# Replace only after the whole file is written, so an interrupted save keeps the previous presets.
	var file := FileAccess.open(_path + ".tmp", FileAccess.WRITE)
	if file == null:
		return "Could not save presets."
	file.store_string(JSON.stringify({"version": 1, "aircraft": _aircraft}, "\t"))
	file.close()
	var result := DirAccess.rename_absolute(ProjectSettings.globalize_path(_path + ".tmp"), ProjectSettings.globalize_path(_path))
	return "" if result == OK else "Could not replace presets."
