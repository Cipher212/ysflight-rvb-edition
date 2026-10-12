extends Node3D

# Collect the native feed once; coordinate bounded audio helpers and the existing gun/one-shot pools.
const GUN_UNIT_SIZE: float = 250.0
const GUN_MAX_DISTANCE: float = 5000.0
const LAUNCH_UNIT_SIZE: float = 300.0
const LAUNCH_MAX_DISTANCE: float = 6000.0
const PLAYER_EVENT_UNIT_SIZE: float = 40.0
const SoundLibrary := preload("res://audio/sound_library.gd")
const AudioBuses := preload("res://audio/audio_buses.gd")
const EngineAudio := preload("res://audio/engine_audio.gd")
const ImpactAudio := preload("res://audio/impact_audio.gd")
const WarningAudio := preload("res://audio/warning_audio.gd")

var _sounds: SoundLibrary
var _buses: AudioBuses
var _engines: EngineAudio
var _impacts: ImpactAudio
var _warnings: WarningAudio
var _sim: Object
var _ac_key_to_row: Dictionary = {}
var _oneshot_players: Array[AudioStreamPlayer3D] = []
var _oneshot_start_times: PackedFloat64Array = []
var _prev_cam_pos := Vector3.ZERO
var _has_prev_cam := false

# Gun voice structure
class GunVoice:
	var player: AudioStreamPlayer3D = null
	var assigned_key: int = -1
	var stop_timer: float = 0.0
	var doppler_factor: float = 1.0
	var is_player: bool = false

var _gun_voices: Array[GunVoice] = []

# Pre-allocated top nearest firing aircraft for gun voices
var _top_firing_keys: PackedInt32Array = [0, 0, 0, 0]
var _top_firing_d2: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
var _top_firing_count: int = 0

func setup(sim: Object) -> void:
	_sim = sim
	_buses = AudioBuses.new()
	_sounds = SoundLibrary.new()
	_engines = EngineAudio.new()
	_engines.setup(self, _sounds)
	_impacts = ImpactAudio.new()
	_impacts.setup(_sounds)
	_warnings = WarningAudio.new()
	_warnings.setup(self, _sounds)
	_setup_gun_voices()
	_setup_oneshots()
	var is_bench := "--benchmark" in OS.get_cmdline_user_args()
	if get_parent() != null and "benchmark_mode" in get_parent() and get_parent().benchmark_mode:
		is_bench = true
	if is_bench:
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), -80.0)

func rebase(delta: Vector3) -> void:
	for p in _oneshot_players:
		p.global_position -= delta
	_prev_cam_pos -= delta

func update(delta: float, camera: Camera3D, interior: bool, telemetry: Dictionary) -> void:
	if _sim == null or camera == null:
		return
	_buses.update(delta, interior)
	var state: Dictionary = _sim.get_audio_state()
	var player: Dictionary = state.get("player", {})
	var aircraft: PackedFloat32Array = state.get("aircraft", PackedFloat32Array())
	_ac_key_to_row.clear()
	for row in range(aircraft.size() / 11):
		_ac_key_to_row[int(aircraft[row * 11])] = row
	var cam_pos := camera.global_position
	var listener_vel := Vector3.ZERO
	if _has_prev_cam and delta > 0.0001:
		var displacement := cam_pos - _prev_cam_pos
		if displacement.length_squared() < 250000.0:
			listener_vel = displacement / delta
	_prev_cam_pos = cam_pos
	_has_prev_cam = true
	var player_key := int(player.get("key", -1))
	var alive := _ac_key_to_row.has(player_key) and bool(telemetry.get("is_alive", true))
	var player_pos := cam_pos
	if alive:
		var idx: int = int(_ac_key_to_row[player_key]) * 11
		player_pos = Vector3(aircraft[idx + 1], aircraft[idx + 2], aircraft[idx + 3])
	_engines.update(delta, cam_pos, listener_vel, aircraft, _ac_key_to_row, player_key if alive else -1, interior)
	_update_gun_voices(delta, cam_pos, listener_vel, aircraft, alive, player_key, player_pos)
	_process_one_shots(cam_pos, state, player_pos, alive, player_key)
	_warnings.update(delta, player, telemetry, alive, float(state.get("nearest_incoming_missile_m", -1.0)),
		int(state.get("incoming_missiles_lost", 0)))

func _setup_gun_voices() -> void:
	_gun_voices.clear()
	for i in range(4):
		var gv := GunVoice.new()
		gv.player = AudioStreamPlayer3D.new()
		gv.player.name = "GunVoice_%d" % i
		gv.player.bus = "Effects"
		gv.player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		gv.player.unit_size = GUN_UNIT_SIZE
		gv.player.max_distance = GUN_MAX_DISTANCE
		gv.player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		gv.player.stream = _sounds.gun
		add_child(gv.player)
		_gun_voices.append(gv)

func _setup_oneshots() -> void:
	_oneshot_players.clear()
	_oneshot_start_times.resize(20)
	_oneshot_start_times.fill(0.0)
	for i in range(20):
		var p := AudioStreamPlayer3D.new()
		p.name = "OneShot_%d" % i
		p.bus = "Effects"
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.unit_size = 40.0
		p.max_distance = 2500.0
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		add_child(p)
		_oneshot_players.append(p)

func _update_gun_voices(
	delta: float,
	cam_pos: Vector3,
	listener_vel: Vector3,
	aircraft: PackedFloat32Array,
	player_alive: bool,
	player_key: int,
	player_pos: Vector3
) -> void:
	# 1. Player priority
	var player_firing := false
	var player_vel := Vector3.ZERO
	if player_alive and _ac_key_to_row.has(player_key):
		var prow: int = _ac_key_to_row[player_key]
		player_firing = (aircraft[prow * 11 + 9] > 0.5)
		player_vel = Vector3(aircraft[prow * 11 + 4], aircraft[prow * 11 + 5], aircraft[prow * 11 + 6])

	var player_voice_idx := -1
	for i in range(4):
		if _gun_voices[i].assigned_key == player_key and _gun_voices[i].is_player:
			player_voice_idx = i
			break

	if player_firing:
		if player_voice_idx == -1:
			player_voice_idx = 0
			_gun_voices[player_voice_idx].assigned_key = player_key
			_gun_voices[player_voice_idx].is_player = true
			_gun_voices[player_voice_idx].doppler_factor = 1.0

		var gv := _gun_voices[player_voice_idx]
		gv.player.bus = "Effects"
		gv.player.volume_db = -6.0
		gv.player.global_position = player_pos
		gv.stop_timer = 0.05
		if not gv.player.playing:
			gv.player.play()

		var diff := cam_pos - player_pos
		var dist := diff.length()
		var dir := diff / dist if dist > 0.001 else Vector3.ZERO
		var v_rel := (player_vel - listener_vel).dot(dir)
		var target_doppler: float = clampf(343.0 / (343.0 - 0.35 * v_rel), 0.75, 1.35)
		gv.doppler_factor = lerp(gv.doppler_factor, target_doppler, min(1.0, delta * 8.0))
		gv.player.pitch_scale = gv.doppler_factor
	elif player_voice_idx != -1:
		var gv := _gun_voices[player_voice_idx]
		gv.stop_timer -= delta
		if gv.stop_timer <= 0.0:
			gv.player.stop()
			gv.assigned_key = -1
			gv.is_player = false
		else:
			gv.player.global_position = player_pos

	# 2. Remaining voices to nearest other firing aircraft within 1500 m
	var max_gun_d2 := GUN_MAX_DISTANCE * GUN_MAX_DISTANCE
	var ac_count := aircraft.size() / 11
	_top_firing_count = 0

	for row in range(ac_count):
		var idx := row * 11
		if aircraft[idx + 10] > 0.5: # player
			continue
		if aircraft[idx + 9] <= 0.5: # not firing
			continue
		var dx := aircraft[idx + 1] - cam_pos.x
		var dy := aircraft[idx + 2] - cam_pos.y
		var dz := aircraft[idx + 3] - cam_pos.z
		var d2 := dx * dx + dy * dy + dz * dz
		if d2 > max_gun_d2:
			continue
		var key := int(aircraft[idx])
		if _top_firing_count < 4:
			_top_firing_d2[_top_firing_count] = d2
			_top_firing_keys[_top_firing_count] = key
			_top_firing_count += 1
			var j := _top_firing_count - 1
			while j > 0 and _top_firing_d2[j] < _top_firing_d2[j - 1]:
				var td := _top_firing_d2[j]; _top_firing_d2[j] = _top_firing_d2[j - 1]; _top_firing_d2[j - 1] = td
				var tk := _top_firing_keys[j]; _top_firing_keys[j] = _top_firing_keys[j - 1]; _top_firing_keys[j - 1] = tk
				j -= 1
		elif d2 < _top_firing_d2[3]:
			_top_firing_d2[3] = d2
			_top_firing_keys[3] = key
			var j := 3
			while j > 0 and _top_firing_d2[j] < _top_firing_d2[j - 1]:
				var td := _top_firing_d2[j]; _top_firing_d2[j] = _top_firing_d2[j - 1]; _top_firing_d2[j - 1] = td
				var tk := _top_firing_keys[j]; _top_firing_keys[j] = _top_firing_keys[j - 1]; _top_firing_keys[j - 1] = tk
				j -= 1

	# Keep existing other firing voices, count down stopping voices
	for i in range(4):
		if i == player_voice_idx:
			continue
		var gv := _gun_voices[i]
		if gv.assigned_key != -1:
			var still_firing := false
			for k in range(_top_firing_count):
				if _top_firing_keys[k] == gv.assigned_key:
					still_firing = true
					break
			if still_firing and _ac_key_to_row.has(gv.assigned_key):
				gv.stop_timer = 0.05
				var row: int = _ac_key_to_row[gv.assigned_key]
				var base := row * 11
				var pos := Vector3(aircraft[base + 1], aircraft[base + 2], aircraft[base + 3])
				var vel := Vector3(aircraft[base + 4], aircraft[base + 5], aircraft[base + 6])
				gv.player.global_position = pos

				var diff := cam_pos - pos
				var dist := diff.length()
				var dir := diff / dist if dist > 0.001 else Vector3.ZERO
				var v_rel := (vel - listener_vel).dot(dir)
				var target_doppler: float = clampf(343.0 / (343.0 - 0.35 * v_rel), 0.75, 1.35)
				gv.doppler_factor = lerp(gv.doppler_factor, target_doppler, min(1.0, delta * 8.0))
				gv.player.pitch_scale = gv.doppler_factor
			else:
				gv.stop_timer -= delta
				if gv.stop_timer <= 0.0:
					gv.player.stop()
					gv.assigned_key = -1
				elif _ac_key_to_row.has(gv.assigned_key):
					var row: int = _ac_key_to_row[gv.assigned_key]
					var base := row * 11
					gv.player.global_position = Vector3(aircraft[base + 1], aircraft[base + 2], aircraft[base + 3])

	# Assign newly firing aircraft to free voices
	for k in range(_top_firing_count):
		var key := _top_firing_keys[k]
		var already_assigned := false
		for i in range(4):
			if _gun_voices[i].assigned_key == key:
				already_assigned = true
				break
		if already_assigned:
			continue

		var free_idx := -1
		for i in range(4):
			if i == player_voice_idx:
				continue
			if _gun_voices[i].assigned_key == -1 or not _gun_voices[i].player.playing:
				free_idx = i
				break

		if free_idx != -1 and _ac_key_to_row.has(key):
			var gv := _gun_voices[free_idx]
			gv.assigned_key = key
			gv.is_player = false
			gv.player.bus = "Others"
			gv.player.volume_db = -8.0
			gv.stop_timer = 0.05
			gv.doppler_factor = 1.0

			var row: int = _ac_key_to_row[key]
			var base := row * 11
			var pos := Vector3(aircraft[base + 1], aircraft[base + 2], aircraft[base + 3])
			var vel := Vector3(aircraft[base + 4], aircraft[base + 5], aircraft[base + 6])
			gv.player.global_position = pos

			var diff := cam_pos - pos
			var dist := diff.length()
			var dir := diff / dist if dist > 0.001 else Vector3.ZERO
			var v_rel := (vel - listener_vel).dot(dir)
			gv.doppler_factor = clampf(343.0 / (343.0 - 0.35 * v_rel), 0.75, 1.35)
			gv.player.pitch_scale = gv.doppler_factor
			gv.player.play()

func _play_oneshot(stream: AudioStreamWAV, pos: Vector3, vol_db: float, unit_sz: float, max_dist: float) -> void:
	if stream == null:
		return
	var now := float(Time.get_ticks_usec())
	var best_idx := -1

	for i in range(20):
		if not _oneshot_players[i].playing:
			best_idx = i
			break

	if best_idx == -1:
		var oldest_time := INF
		for i in range(20):
			if _oneshot_start_times[i] < oldest_time:
				oldest_time = _oneshot_start_times[i]
				best_idx = i
		_oneshot_players[best_idx].stop()

	var p := _oneshot_players[best_idx]
	p.stream = stream
	p.volume_db = vol_db
	p.unit_size = unit_sz
	p.max_distance = max_dist
	p.pitch_scale = 1.0
	p.global_position = pos
	p.play()
	_oneshot_start_times[best_idx] = now

func _process_one_shots(cam_pos: Vector3, state: Dictionary, player_pos: Vector3,
		player_alive: bool, player_key: int) -> void:
	var launches: PackedFloat32Array = state.get("launches", PackedFloat32Array())
	var onetime: PackedInt32Array = state.get("onetime", PackedInt32Array())
	_impacts.play(state, cam_pos, _play_oneshot)
	# 1. Launches
	var max_launch_d2 := LAUNCH_MAX_DISTANCE * LAUNCH_MAX_DISTANCE
	var launch_count := launches.size() / 6
	for i in range(launch_count):
		var base := i * 6
		var kind := int(launches[base])
		var pos := Vector3(launches[base + 1], launches[base + 2], launches[base + 3])
		if cam_pos.distance_squared_to(pos) <= max_launch_d2:
			match kind:
				0: _play_oneshot(_sounds.missile, pos, -4.0, LAUNCH_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
				1: _play_oneshot(_sounds.rocket, pos, -4.0, LAUNCH_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
				2: _play_oneshot(_sounds.bombsaway, pos, -6.0, LAUNCH_UNIT_SIZE, LAUNCH_MAX_DISTANCE)

	# 3. Player onetime events
	if player_alive:
		for ev in onetime:
			if ev in [1, 6] and _impacts.player_was_hit(state, player_key):
				continue
			match ev:
				5: _play_oneshot(_sounds.touchdwn, player_pos, 0.0, PLAYER_EVENT_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
				8: _play_oneshot(_sounds.retractldg, player_pos, 0.0, PLAYER_EVENT_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
				9: _play_oneshot(_sounds.extendldg, player_pos, 0.0, PLAYER_EVENT_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
				1: _play_oneshot(_sounds.damage, player_pos, 0.0, PLAYER_EVENT_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
				6: _play_oneshot(_sounds.hit, player_pos, 0.0, PLAYER_EVENT_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
