extends RefCounted

# Classify before allocating a pooled player. Positions exist only for this collected batch.
const MAX_DISTANCE: float = 10000.0
const UNIT_SIZE: float = 1000.0
const MAX_PER_FRAME: int = 6
const MATCH_HORIZONTAL_METRES: float = 2.0
const SoundLibrary := preload("res://audio/sound_library.gd")

var _sounds: SoundLibrary

func setup(sounds: SoundLibrary) -> void:
	_sounds = sounds

func play(state: Dictionary, camera_pos: Vector3, emit: Callable) -> void:
	var hits: PackedFloat64Array = state.get("missile_hits", PackedFloat64Array())
	var rows: PackedFloat32Array = state.get("classified_explosions", PackedFloat32Array())
	var started := 0
	for offset in range(0, hits.size() - 8, 9):
		var pos := Vector3(hits[offset], hits[offset + 1], hits[offset + 2])
		if camera_pos.distance_squared_to(pos) > MAX_DISTANCE * MAX_DISTANCE:
			continue
		if started >= MAX_PER_FRAME:
			break
		emit.call(_sounds.bang, pos, -6.0, UNIT_SIZE, MAX_DISTANCE)
		started += 1
	for offset in range(0, rows.size() - 6, 7):
		if started >= MAX_PER_FRAME:
			break
		var pos := Vector3(rows[offset], rows[offset + 1], rows[offset + 2])
		if camera_pos.distance_squared_to(pos) > MAX_DISTANCE * MAX_DISTANCE:
			continue
		var incident := int(rows[offset + 5])
		var weapon := int(rows[offset + 6])
		if _duplicates_hit(pos, incident, weapon, hits):
			continue
		var stream := select_stream(rows[offset + 3], int(rows[offset + 4]), incident, weapon)
		if stream != null:
			emit.call(stream, pos, -6.0, UNIT_SIZE, MAX_DISTANCE)
			started += 1

func select_stream(size: float, surface: int, incident: int, weapon: int) -> AudioStreamWAV:
	if weapon in [5, 200] or incident == 5:
		return null
	if weapon in [3, 7, 9]:
		return _sounds.bomb_water if surface == 1 else _sounds.bomb_blast
	if weapon in [1, 2, 4, 6, 10]:
		return _sounds.blast
	if incident == 1 or weapon in [0, 12, 128]:
		# Bullets and dropped non-explosive objects need an impact rather than a heavy blast.
		return null if surface == 1 else _sounds.hit
	if incident == 4:
		return _sounds.crash_blast
	# Older recordings lack classification; use the current bank with size-based routing.
	if size < 6.0:
		return _sounds.legacy_bang
	if size < 15.0:
		return _sounds.legacy_blast
	return _sounds.crash_blast

func player_was_hit(state: Dictionary, player_key: int) -> bool:
	var hits: PackedFloat64Array = state.get("missile_hits", PackedFloat64Array())
	for offset in range(0, hits.size() - 8, 9):
		if int(hits[offset + 7]) == player_key:
			return true
	return false

func _duplicates_hit(pos: Vector3, incident: int, weapon: int, hits: PackedFloat64Array) -> bool:
	for offset in range(0, hits.size() - 8, 9):
		var hit_type := int(hits[offset + 6])
		if weapon == hit_type:
			var source := Vector3(hits[offset], hits[offset + 1], hits[offset + 2])
			if _same_point(pos, source):
				return true
		if incident == 4 and hits[offset + 8] > 0.5:
			var victim := Vector3(hits[offset + 3], hits[offset + 4], hits[offset + 5])
			if _same_point(pos, victim):
				return true
	return false

func _same_point(effect: Vector3, source: Vector3) -> bool:
	# Native low fireballs clamp Y to zero; do not widen X/Z matching.
	return Vector2(effect.x, effect.z).distance_squared_to(Vector2(source.x, source.z)) <= \
		MATCH_HORIZONTAL_METRES * MATCH_HORIZONTAL_METRES and absf(effect.y - source.y) <= 30.0
