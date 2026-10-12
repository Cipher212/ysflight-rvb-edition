extends RefCounted

# Bounded jet/prop voices: player plus six nearest aircraft, with shared sample resources.
const ENGINE_UNIT_SIZE: float = 600.0
const ENGINE_MAX_DISTANCE: float = 15000.0
const VOICE_STOPPED: int = 0
const VOICE_FADING_IN: int = 1
const VOICE_ACTIVE: int = 2
const VOICE_FADING_OUT: int = 3
const SPOOL_RATE: float = 2.0
const VIEW_FADE_SECONDS: float = 0.15
const COCKPIT_ENGINE_DB: float = -12.0
const COCKPIT_BURNER_DB: float = -6.0
const DRONE_DB: float = -6.0
const PLAYER_ENGINE_DB: float = -6.0
const PLAYER_BURNER_DB: float = -4.0
const OTHERS_DB: float = -8.0
const VOICE_FADE_SECONDS: float = 0.3
const BURNER_IN_SECONDS: float = 0.15
const BURNER_OUT_SECONDS: float = 0.5
const SoundLibrary := preload("res://audio/sound_library.gd")

class EngineVoice:
	var assigned_key: int = -1
	var engine_player: AudioStreamPlayer3D
	var upper_player: AudioStreamPlayer3D
	var burner_player: AudioStreamPlayer3D
	var layers: Array[AudioStreamPlayer3D] = []
	var burner_factor: float = 0.0
	var fade_weight: float = 0.0
	var power: float = 0.0
	var state: int = 0
	var doppler_factor: float = 1.0
	var is_player: bool = false

var player_voice: EngineVoice
var _other_engine_voices: Array[EngineVoice] = []
var drone: AudioStreamPlayer
var _sounds: SoundLibrary
var _ac_key_to_row: Dictionary = {}
var _top6_keys: PackedInt32Array = [0, 0, 0, 0, 0, 0]
var _top6_d2: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
var _top6_count: int = 0
var _reassign_timer: float = 0.0
var _interior_mix: float = 0.0
var _drone_gain: float = 0.0

func setup(host: Node, sounds: SoundLibrary) -> void:
	_sounds = sounds
	player_voice = _create_voice(host, true)
	for i in range(6):
		_other_engine_voices.append(_create_voice(host, false))
	drone = AudioStreamPlayer.new()
	drone.name = "CockpitDrone"
	drone.bus = "VolEngines"
	drone.stream = sounds.cockpit_drone
	host.add_child(drone)

func _create_voice(host: Node, is_player: bool) -> EngineVoice:
	var v := EngineVoice.new()
	v.is_player = is_player
	v.engine_player = _create_player(host, is_player)
	v.upper_player = _create_player(host, is_player)
	v.burner_player = _create_player(host, is_player)
	v.layers = [v.engine_player, v.upper_player, v.burner_player]
	v.burner_player.stream = _sounds.burner
	return v

func _create_player(host: Node, is_player: bool) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = "PlayerEngine" if is_player else "Others"
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.unit_size = ENGINE_UNIT_SIZE
	p.max_distance = ENGINE_MAX_DISTANCE
	p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	host.add_child(p)
	return p

func update(delta: float, cam_pos: Vector3, listener_vel: Vector3, aircraft: PackedFloat32Array,
		rows: Dictionary, player_key: int, interior: bool) -> void:
	_ac_key_to_row = rows
	_interior_mix = move_toward(_interior_mix, 1.0 if interior else 0.0, delta / VIEW_FADE_SECONDS)
	if player_voice.assigned_key != player_key:
		_stop(player_voice)
		player_voice.assigned_key = player_key
		player_voice.state = VOICE_FADING_IN
	_update_engine_voice(player_voice, delta, cam_pos, listener_vel, aircraft)
	_reassign_timer += delta
	if _reassign_timer >= 0.25:
		_reassign_timer = 0.0
		_reassign_other_engine_voices(cam_pos, aircraft)
	for v in _other_engine_voices:
		_update_engine_voice(v, delta, cam_pos, listener_vel, aircraft)
	var jet_alive := player_key >= 0 and rows.has(player_key)
	if jet_alive:
		jet_alive = int(aircraft[int(rows[player_key]) * 11 + 7]) != 2
	if not jet_alive:
		_drone_gain = 0.0
	else:
		_drone_gain = move_toward(_drone_gain, 1.0 if interior else 0.0, delta / VIEW_FADE_SECONDS)
	_set_layer(drone, _sounds.cockpit_drone, db_to_linear(DRONE_DB) * _drone_gain, 1.0)

func _stop(v: EngineVoice) -> void:
	if v.engine_player.playing:
		v.engine_player.stop()
	if v.upper_player.playing:
		v.upper_player.stop()
	if v.burner_player.playing:
		v.burner_player.stop()
	v.fade_weight = 0.0
	v.burner_factor = 0.0
	v.power = 0.0
	v.state = VOICE_STOPPED

func _reassign_other_engine_voices(cam_pos: Vector3, aircraft: PackedFloat32Array) -> void:
	var max_dist_sq := ENGINE_MAX_DISTANCE * ENGINE_MAX_DISTANCE
	var ac_count := aircraft.size() / 11
	_top6_count = 0

	for row in range(ac_count):
		var idx := row * 11
		if aircraft[idx + 10] > 0.5: # is_player
			continue
		var dx := aircraft[idx + 1] - cam_pos.x
		var dy := aircraft[idx + 2] - cam_pos.y
		var dz := aircraft[idx + 3] - cam_pos.z
		var d2 := dx * dx + dy * dy + dz * dz
		if d2 > max_dist_sq:
			continue
		var key := int(aircraft[idx])
		if _top6_count < 6:
			_top6_d2[_top6_count] = d2
			_top6_keys[_top6_count] = key
			_top6_count += 1
			var j := _top6_count - 1
			while j > 0 and _top6_d2[j] < _top6_d2[j - 1]:
				var td := _top6_d2[j]; _top6_d2[j] = _top6_d2[j - 1]; _top6_d2[j - 1] = td
				var tk := _top6_keys[j]; _top6_keys[j] = _top6_keys[j - 1]; _top6_keys[j - 1] = tk
				j -= 1
		elif d2 < _top6_d2[5]:
			_top6_d2[5] = d2
			_top6_keys[5] = key
			var j := 5
			while j > 0 and _top6_d2[j] < _top6_d2[j - 1]:
				var td := _top6_d2[j]; _top6_d2[j] = _top6_d2[j - 1]; _top6_d2[j - 1] = td
				var tk := _top6_keys[j]; _top6_keys[j] = _top6_keys[j - 1]; _top6_keys[j - 1] = tk
				j -= 1

	# Keep existing assignments still in chosen set, release others
	for v in _other_engine_voices:
		if v.assigned_key != -1:
			var found := false
			for i in range(_top6_count):
				if _top6_keys[i] == v.assigned_key:
					found = true
					break
			if found:
				if v.state == VOICE_FADING_OUT:
					v.state = VOICE_FADING_IN
			else:
				v.state = VOICE_FADING_OUT

	# Assign newly chosen keys
	for i in range(_top6_count):
		var key := _top6_keys[i]
		var already_assigned := false
		for v in _other_engine_voices:
			if v.assigned_key == key:
				already_assigned = true
				break
		if already_assigned:
			continue

		var best_voice: EngineVoice = null
		var lowest_weight := INF
		for v in _other_engine_voices:
			if v.state == VOICE_STOPPED or v.assigned_key == -1:
				best_voice = v
				break
			elif v.state == VOICE_FADING_OUT and v.fade_weight < lowest_weight:
				lowest_weight = v.fade_weight
				best_voice = v

		if best_voice != null:
			_stop(best_voice)
			best_voice.assigned_key = key
			best_voice.state = VOICE_FADING_IN
			best_voice.fade_weight = 0.0
			best_voice.burner_factor = 0.0
			best_voice.doppler_factor = 1.0

func _update_engine_voice(v: EngineVoice, delta: float, cam_pos: Vector3,
		listener_vel: Vector3, aircraft: PackedFloat32Array) -> void:
	if v.assigned_key == -1 or not _ac_key_to_row.has(v.assigned_key):
		_stop(v)
		v.assigned_key = -1
		return
	var idx: int = int(_ac_key_to_row[v.assigned_key]) * 11
	var pos := Vector3(aircraft[idx + 1], aircraft[idx + 2], aircraft[idx + 3])
	var vel := Vector3(aircraft[idx + 4], aircraft[idx + 5], aircraft[idx + 6])
	var kind := int(aircraft[idx + 7])
	v.power = move_toward(v.power, clampf(aircraft[idx + 8], 0.0, 1.0), delta * SPOOL_RATE)
	for p in v.layers:
		if p.global_position != pos:
			p.global_position = pos
	var target_burner := 1.0 if kind == 1 else 0.0
	v.burner_factor = move_toward(v.burner_factor, target_burner,
		delta / (BURNER_IN_SECONDS if kind == 1 else BURNER_OUT_SECONDS))
	if v.state == VOICE_FADING_OUT and not v.is_player:
		v.fade_weight = move_toward(v.fade_weight, 0.0, delta / VOICE_FADE_SECONDS)
		if v.fade_weight <= 0.0:
			_stop(v)
			v.assigned_key = -1
			return
	else:
		v.fade_weight = move_toward(v.fade_weight, 1.0, delta / VOICE_FADE_SECONDS)
		if v.fade_weight >= 1.0:
			v.state = VOICE_ACTIVE
	var diff := cam_pos - pos
	var dir := diff.normalized()
	var v_rel := (vel - listener_vel).dot(dir)
	var doppler := clampf(343.0 / (343.0 - 0.35 * v_rel), 0.75, 1.35)
	v.doppler_factor = lerpf(v.doppler_factor, doppler, minf(1.0, delta * 8.0))
	var view_mix := _interior_mix if v.is_player else 0.0
	var base_db := PLAYER_ENGINE_DB if v.is_player else OTHERS_DB
	var engine_gain := db_to_linear(base_db + COCKPIT_ENGINE_DB * view_mix) * v.fade_weight
	if kind == 2:
		v.burner_factor = 0.0
		var prop_gain := db_to_linear(base_db) * v.fade_weight
		_set_layer(v.engine_player, _sounds.prop0, prop_gain, (1.0 + 0.37 * v.power) * v.doppler_factor)
		if v.upper_player.playing:
			v.upper_player.stop()
		if v.burner_player.playing:
			v.burner_player.stop()
		return
	# Alternating slots preserve each loop across adjacent throttle-band boundaries.
	var band := v.power * 9.0
	var low := int(floorf(band))
	var high := mini(low + 1, 9)
	var blend := band - low
	var lower_player := v.engine_player if low % 2 == 0 else v.upper_player
	var higher_player := v.upper_player if low % 2 == 0 else v.engine_player
	engine_gain *= lerpf(1.0, 0.25, v.burner_factor)
	_set_layer(lower_player, _sounds.engine_bands[low], engine_gain * sqrt(1.0 - blend), v.doppler_factor)
	_set_layer(higher_player, _sounds.engine_bands[high], engine_gain * sqrt(blend), v.doppler_factor)
	var burner_db := (PLAYER_BURNER_DB if v.is_player else OTHERS_DB) + COCKPIT_BURNER_DB * view_mix
	_set_layer(v.burner_player, _sounds.burner, db_to_linear(burner_db) * v.burner_factor * v.fade_weight, v.doppler_factor)

func _set_layer(player: Node, stream: AudioStreamWAV, gain: float, pitch: float) -> void:
	if gain <= 0.0001 or stream == null:
		if player.playing:
			player.stop()
		return
	if player.stream != stream:
		if player.playing:
			player.stop()
		player.stream = stream
	var volume := linear_to_db(gain)
	if not is_equal_approx(player.volume_db, volume):
		player.volume_db = volume
	if not is_equal_approx(player.pitch_scale, pitch):
		player.pitch_scale = pitch
	if not player.playing:
		player.play()
