extends RefCounted

# Exterior Sonic Boom: triggers a DCS-style sharp supersonic double-crack snap followed by
# rolling atmospheric thunder when an aircraft's Mach cone sweeps across the listener/camera position.
# Follows supersonic shock cone geometry (Mach angle mu = asin(1 / M)).

const SPEED_OF_SOUND_MS := 340.0
const MIN_SUPERSONIC_SPEED_MS := 340.0 # Mach >= 1.0
const MAX_AUDIBLE_BOOM_DIST_M := 4000.0
const BOOM_COOLDOWN_S := 3.5

# Aircraft tracking: key -> { "f": float, "cooldown": float }
var _tracks := {}

func update(
	delta: float,
	cam_pos: Vector3,
	interior: bool,
	player_key: int,
	aircraft: PackedFloat32Array,
	play_oneshot_fn: Callable,
	boom_stream: AudioStreamWAV
) -> void:
	if aircraft.is_empty() or play_oneshot_fn.is_null() or boom_stream == null:
		_tracks.clear()
		return

	# Decrement cooldowns
	var active_keys := {}
	for k in _tracks.keys():
		var tr: Dictionary = _tracks[k]
		var cd: float = float(tr.get("cooldown", 0.0))
		if cd > 0.0:
			tr["cooldown"] = maxf(0.0, cd - delta)

	var count := aircraft.size() / 11
	for row in count:
		var idx := row * 11
		var key := int(aircraft[idx])
		active_keys[key] = true

		# Pilots inside their own cockpit do not hear their own exterior shock cone
		if interior and key == player_key:
			_tracks.erase(key)
			continue

		var pos := Vector3(aircraft[idx + 1], aircraft[idx + 2], aircraft[idx + 3])
		var vel := Vector3(aircraft[idx + 4], aircraft[idx + 5], aircraft[idx + 6])
		var speed := vel.length()

		if speed < MIN_SUPERSONIC_SPEED_MS:
			_tracks.erase(key)
			continue

		var r := cam_pos - pos
		var dist := r.length()
		if dist > MAX_AUDIBLE_BOOM_DIST_M or dist < 2.0:
			_tracks.erase(key)
			continue

		var mach: float = speed / SPEED_OF_SOUND_MS
		var v_dir := vel / speed
		# Distance along the flight track (positive if camera is in front of jet)
		var s: float = r.dot(v_dir)
		# Perpendicular distance to the track
		var r_perp: float = sqrt(maxf(0.0, dist * dist - s * s))
		# Signed distance from the shock wave surface (positive = in front of cone, negative = behind cone)
		var mach_cot: float = sqrt(maxf(0.0, mach * mach - 1.0))
		var f: float = s + r_perp * mach_cot

		if not _tracks.has(key):
			_tracks[key] = {"f": f, "cooldown": 0.0}
			continue

		var tr: Dictionary = _tracks[key]
		var f_prev: float = float(tr.get("f", f))
		var cooldown: float = float(tr.get("cooldown", 0.0))
		tr["f"] = f

		# Mach cone swept past the camera when f crossed from positive to negative
		if f_prev > 0.0 and f <= 0.0 and cooldown <= 0.0:
			tr["cooldown"] = BOOM_COOLDOWN_S
			# Volume attenuates with distance from the shock front
			var dist_norm: float = clampf(dist / MAX_AUDIBLE_BOOM_DIST_M, 0.0, 1.0)
			var vol_db: float = lerpf(2.0, -12.0, dist_norm)
			play_oneshot_fn.call(boom_stream, pos, vol_db, 250.0, MAX_AUDIBLE_BOOM_DIST_M)

	# Prune tracks for destroyed/despawned aircraft
	for k in _tracks.keys():
		if not active_keys.has(k):
			_tracks.erase(k)
