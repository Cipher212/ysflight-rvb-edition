extends Node3D

# ==============================================================================
# YSFlight Godot Port - Audio Manager
# ==============================================================================
# Handles all game audio:
#   - Player and AI engine / afterburner / propeller loops with Doppler
#   - Player and AI gun loops
#   - 3D One-shot effects (launches, explosions, gear, damage, touchdown)
#   - Cockpit warning tones, lock-on tone, and over-G synthesized beeps
#   - Dynamic bus filtering and volume ducking based on interior/exterior view
#
# Data comes from ysflight_sim.get_audio_state() (C++), called once per frame from update().
# All tuning values (distance falloff, cockpit ducking, over-G limit) are the consts below.
# Full design notes, tuning history and ideas for later: logs/phase4_audio_log.md
# ==============================================================================

const OVER_G_LIMIT: float = 11.0

# Distance falloff (Godot inverse-distance model: full volume, capped at +3 dB, out to UNIT_SIZE, then
# -6 dB per doubling of distance, silent past MAX_DISTANCE). Jets are very loud: engines stay at full
# volume for the first ~600 m and are still clearly audible at 5 km (-18 dB) in exterior views.
# In the cockpit, other aircraft are pushed down on the "Others" bus instead (helmet + your own engine),
# see INTERIOR_OTHERS_DB in audio/audio_buses.gd.
# 2026-09-30 user: drop-off still too steep -> unit sizes and ranges raised (were 250 m / 8 km engines,
# 300 m / 2.5 km explosions, 120 m / 3 km guns, 150 m / 3 km launches). Explosions are still instant.
const ENGINE_UNIT_SIZE: float = 600.0
const ENGINE_MAX_DISTANCE: float = 15000.0
const GUN_UNIT_SIZE: float = 250.0
const GUN_MAX_DISTANCE: float = 5000.0
const LAUNCH_UNIT_SIZE: float = 300.0
const LAUNCH_MAX_DISTANCE: float = 6000.0
const EXPLOSION_UNIT_SIZE: float = 1000.0
const EXPLOSION_MAX_DISTANCE: float = 10000.0
const PLAYER_EVENT_UNIT_SIZE: float = 40.0

const BURNER_FADE_IN_TIME: float = 0.15
const BURNER_FADE_OUT_TIME: float = 0.5

const SoundLibrary := preload("res://audio/sound_library.gd")
const AudioBuses := preload("res://audio/audio_buses.gd")
const CameraViewAudioFade := preload("res://audio/camera_view_audio_fade.gd")

var _sounds: SoundLibrary = null
var _buses: AudioBuses = null
var _view_fade: CameraViewAudioFade = null
var _sim: Object = null
var _interior: bool = false

# Engine voice structure
class EngineVoice:
	var assigned_key: int = -1
	var engine_player: AudioStreamPlayer3D = null
	var burner_player: AudioStreamPlayer3D = null
	var burner_factor: float = 0.0
	var fade_weight: float = 0.0
	var state: int = 0
	var doppler_factor: float = 1.0
	var is_player: bool = false

const VOICE_STOPPED: int = 0
const VOICE_FADING_IN: int = 1
const VOICE_ACTIVE: int = 2
const VOICE_FADING_OUT: int = 3

var _player_engine_voice: EngineVoice = null
var _other_engine_voices: Array[EngineVoice] = []
var _others_reassign_timer: float = 0.0

# Pre-allocated arrays for top 6 selection
var _top6_keys: PackedInt32Array = [0, 0, 0, 0, 0, 0]
var _top6_d2: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
var _top6_count: int = 0

# Map of ac key -> row index in packed array (reused every frame)
var _ac_key_to_row: Dictionary = {}

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

# One-shots pool (20 pre-created players)
var _oneshot_players: Array[AudioStreamPlayer3D] = []
var _oneshot_start_times: PackedFloat64Array = []

# Cockpit warning players (2D)
var _alarm_player: AudioStreamPlayer = null
var _lock_beep_player: AudioStreamPlayer = null
var _over_g_player: AudioStreamPlayer = null
var _active_alarm_code: int = 0

# Camera Doppler tracking state
var _prev_cam_pos: Vector3 = Vector3.ZERO
var _has_prev_cam: bool = false

func setup(sim: Object) -> void:
	_sim = sim
	_buses = AudioBuses.new()
	_sounds = SoundLibrary.new()
	_view_fade = CameraViewAudioFade.new()
	_setup_engine_voices()
	_view_fade.setup(_sounds, _player_engine_voice, false)
	_setup_gun_voices()
	_setup_oneshots()
	_setup_cockpit_players()

	# Mute in benchmark mode if active
	var is_bench: bool = ("--benchmark" in OS.get_cmdline_user_args())
	if get_parent() != null and "benchmark_mode" in get_parent() and get_parent().benchmark_mode:
		is_bench = true
	if is_bench:
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), -80.0)

# The render origin moved by delta (main.gd): one-shots keep playing where they started, and the camera
# history is moved too, so the listener does not get a false Doppler jump.
func rebase(delta: Vector3) -> void:
	for p in _oneshot_players:
		p.global_position -= delta
	_prev_cam_pos -= delta

func update(delta: float, camera: Camera3D, interior: bool, telemetry: Dictionary) -> void:
	if _sim == null or camera == null:
		return

	_interior = interior

	# Bus routing & filtering
	_buses.update(delta, interior)

	# Fetch audio state EXACTLY ONCE per frame
	var state: Dictionary = _sim.get_audio_state()
	var player_dict: Dictionary = state.get("player", {})
	var onetime: PackedInt32Array = state.get("onetime", PackedInt32Array())
	var aircraft: PackedFloat32Array = state.get("aircraft", PackedFloat32Array())
	var launches: PackedFloat32Array = state.get("launches", PackedFloat32Array())
	var explosions: PackedFloat32Array = state.get("explosions", PackedFloat32Array())

	# Build key->row index map (reusing dictionary object)
	_build_ac_key_map(aircraft)

	# Calculate listener velocity for Doppler
	var cam_pos := camera.global_position
	var listener_vel := Vector3.ZERO
	if _has_prev_cam:
		var cam_disp := cam_pos - _prev_cam_pos
		if cam_disp.length_squared() < 250000.0 and delta > 0.0001:
			listener_vel = cam_disp / delta
	_prev_cam_pos = cam_pos
	_has_prev_cam = true

	# Update player engine voice
	var player_key := int(player_dict.get("key", -1))
	var player_pos := cam_pos
	var player_alive := false
	if player_key != -1 and _ac_key_to_row.has(player_key):
		player_alive = true
		var prow := int(_ac_key_to_row[player_key])
		player_pos = Vector3(aircraft[prow * 11 + 1], aircraft[prow * 11 + 2], aircraft[prow * 11 + 3])
		_player_engine_voice.assigned_key = player_key
	else:
		_player_engine_voice.assigned_key = -1

	_update_engine_voice(_player_engine_voice, delta, cam_pos, listener_vel, aircraft)

	# Update others engine voices
	_others_reassign_timer += delta
	if _others_reassign_timer >= 0.25:
		_others_reassign_timer = 0.0
		_reassign_other_engine_voices(cam_pos, aircraft)

	for v in _other_engine_voices:
		_update_engine_voice(v, delta, cam_pos, listener_vel, aircraft)

	# Update gun voices
	_update_gun_voices(delta, cam_pos, listener_vel, aircraft, player_alive, player_key, player_pos)

	# Update one-shots
	_process_one_shots(cam_pos, launches, explosions, onetime, player_pos, player_alive)

	# Update cockpit warnings
	_update_cockpit_warnings(player_dict, telemetry, player_alive)

# ------------------------------------------------------------------------------
# Voice Creation
# ------------------------------------------------------------------------------
func _create_engine_voice(bus_name: StringName, is_player: bool) -> EngineVoice:
	var v := EngineVoice.new()
	v.is_player = is_player

	v.engine_player = AudioStreamPlayer3D.new()
	v.engine_player.bus = bus_name
	v.engine_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	v.engine_player.unit_size = ENGINE_UNIT_SIZE
	v.engine_player.max_distance = ENGINE_MAX_DISTANCE
	v.engine_player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	v.engine_player.stream = _sounds.jet_external
	add_child(v.engine_player)

	v.burner_player = AudioStreamPlayer3D.new()
	v.burner_player.bus = bus_name
	v.burner_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	v.burner_player.unit_size = ENGINE_UNIT_SIZE
	v.burner_player.max_distance = ENGINE_MAX_DISTANCE
	v.burner_player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	v.burner_player.stream = _sounds.jet_external
	add_child(v.burner_player)

	return v

func _setup_engine_voices() -> void:
	_player_engine_voice = _create_engine_voice("PlayerEngine", true)
	_other_engine_voices.clear()
	for i in range(6):
		var v := _create_engine_voice("Others", false)
		_other_engine_voices.append(v)

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

func _setup_cockpit_players() -> void:
	_alarm_player = AudioStreamPlayer.new()
	_alarm_player.name = "AlarmPlayer"
	_alarm_player.bus = "Cockpit"
	_alarm_player.volume_db = -8.0
	add_child(_alarm_player)

	_lock_beep_player = AudioStreamPlayer.new()
	_lock_beep_player.name = "LockBeepPlayer"
	_lock_beep_player.bus = "Cockpit"
	_lock_beep_player.volume_db = -10.0
	_lock_beep_player.stream = _sounds.lock_beep
	add_child(_lock_beep_player)

	_over_g_player = AudioStreamPlayer.new()
	_over_g_player.name = "OverGPlayer"
	_over_g_player.bus = "Cockpit"
	_over_g_player.volume_db = -8.0
	_over_g_player.stream = _sounds.over_g
	add_child(_over_g_player)

# ------------------------------------------------------------------------------
# Per-Frame Updates
# ------------------------------------------------------------------------------
func _build_ac_key_map(aircraft: PackedFloat32Array) -> void:
	_ac_key_to_row.clear()
	var count := aircraft.size() / 11
	for row in range(count):
		var base_idx := row * 11
		var key := int(aircraft[base_idx])
		_ac_key_to_row[key] = row

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
			best_voice.assigned_key = key
			best_voice.state = VOICE_FADING_IN
			best_voice.fade_weight = 0.0
			best_voice.burner_factor = 0.0
			best_voice.doppler_factor = 1.0

func _update_engine_voice(
	v: EngineVoice,
	delta: float,
	cam_pos: Vector3,
	listener_vel: Vector3,
	aircraft: PackedFloat32Array
) -> void:
	if v.assigned_key == -1:
		if v.engine_player.playing: v.engine_player.stop()
		if v.burner_player.playing: v.burner_player.stop()
		if v.is_player and _view_fade != null:
			_view_fade.reset_stopped(_sounds, v, _interior)
		return

	if not _ac_key_to_row.has(v.assigned_key):
		v.assigned_key = -1
		v.state = VOICE_STOPPED
		v.fade_weight = 0.0
		if v.engine_player.playing: v.engine_player.stop()
		if v.burner_player.playing: v.burner_player.stop()
		if v.is_player and _view_fade != null:
			_view_fade.reset_stopped(_sounds, v, _interior)
		return

	var row: int = _ac_key_to_row[v.assigned_key]
	var idx := row * 11
	var pos := Vector3(aircraft[idx + 1], aircraft[idx + 2], aircraft[idx + 3])
	var vel := Vector3(aircraft[idx + 4], aircraft[idx + 5], aircraft[idx + 6])
	var engine_kind := int(aircraft[idx + 7])
	var power := aircraft[idx + 8]

	v.engine_player.global_position = pos
	v.burner_player.global_position = pos

	# Crossfade engine and burner: quick light-up, slower die-down
	if engine_kind == 1:
		v.burner_factor = move_toward(v.burner_factor, 1.0, delta / BURNER_FADE_IN_TIME)
	else:
		v.burner_factor = move_toward(v.burner_factor, 0.0, delta / BURNER_FADE_OUT_TIME)

	# Fade in/out for other aircraft over 0.3 s
	if not v.is_player:
		if v.state == VOICE_FADING_IN:
			v.fade_weight = move_toward(v.fade_weight, 1.0, delta / 0.3)
			if v.fade_weight >= 1.0:
				v.state = VOICE_ACTIVE
		elif v.state == VOICE_FADING_OUT:
			v.fade_weight = move_toward(v.fade_weight, 0.0, delta / 0.3)
			if v.fade_weight <= 0.0:
				v.state = VOICE_STOPPED
				v.assigned_key = -1
				if v.engine_player.playing: v.engine_player.stop()
				if v.burner_player.playing: v.burner_player.stop()
				return
	else:
		v.fade_weight = 1.0
		v.state = VOICE_ACTIVE

	# Doppler
	var diff := cam_pos - pos
	var dist := diff.length()
	var dir := diff / dist if dist > 0.001 else Vector3.ZERO
	var v_rel := (vel - listener_vel).dot(dir)
	var target_doppler: float = clampf(343.0 / (343.0 - 0.35 * v_rel), 0.75, 1.35)
	v.doppler_factor = lerp(v.doppler_factor, target_doppler, min(1.0, delta * 8.0))

	# Stream and pitch
	if engine_kind == 2:
		var prop_pitch: float = 1.0 + 0.37 * power
		v.engine_player.pitch_scale = prop_pitch * v.doppler_factor
		if v.engine_player.stream != _sounds.prop0:
			v.engine_player.stream = _sounds.prop0
			if v.engine_player.playing: v.engine_player.play()
		if v.burner_player.playing:
			v.burner_player.stop()
		if v.is_player and _view_fade != null:
			_view_fade.reset_for_prop(_interior)
	else:
		var jet_pitch: float = 1.0 + 0.0625 * clamp(power * 10.0, 0.0, 9.0)
		v.engine_player.pitch_scale = jet_pitch * v.doppler_factor
		v.burner_player.pitch_scale = 1.0 * v.doppler_factor
		if v.is_player:
			if _view_fade != null:
				_view_fade.update(delta, _sounds, v, _interior)
		else:
			if v.engine_player.stream != _sounds.jet_external:
				v.engine_player.stream = _sounds.jet_external
				if v.engine_player.playing: v.engine_player.play()
			if v.burner_player.stream != _sounds.jet_external:
				v.burner_player.stream = _sounds.jet_external
				if v.burner_player.playing: v.burner_player.play()

	# Volumes
	if v.is_player:
		var base_eng_linear := db_to_linear(-6.0) * (1.0 - v.burner_factor)
		var base_brn_linear := db_to_linear(-4.0) * v.burner_factor if engine_kind != 2 else 0.0
		var fg := _view_fade.fade_gain if (engine_kind != 2 and _view_fade != null) else 1.0
		var eng_linear := base_eng_linear * fg
		var brn_linear := base_brn_linear * fg

		if base_eng_linear > 0.0001:
			v.engine_player.volume_db = linear_to_db(maxf(eng_linear, 0.00001))
			if not v.engine_player.playing: v.engine_player.play()
		else:
			if v.engine_player.playing: v.engine_player.stop()

		if base_brn_linear > 0.0001:
			v.burner_player.volume_db = linear_to_db(maxf(brn_linear, 0.00001))
			if not v.burner_player.playing: v.burner_player.play()
		else:
			if v.burner_player.playing: v.burner_player.stop()
	else:
		var base_linear := db_to_linear(-8.0) * v.fade_weight
		var eng_linear := base_linear * (1.0 - v.burner_factor)
		var brn_linear := base_linear * v.burner_factor if engine_kind != 2 else 0.0
		if eng_linear > 0.0001:
			v.engine_player.volume_db = linear_to_db(eng_linear)
			if not v.engine_player.playing: v.engine_player.play()
		else:
			if v.engine_player.playing: v.engine_player.stop()

		if brn_linear > 0.0001:
			v.burner_player.volume_db = linear_to_db(brn_linear)
			if not v.burner_player.playing: v.burner_player.play()
		else:
			if v.burner_player.playing: v.burner_player.stop()

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

func _process_one_shots(
	cam_pos: Vector3,
	launches: PackedFloat32Array,
	explosions: PackedFloat32Array,
	onetime: PackedInt32Array,
	player_pos: Vector3,
	player_alive: bool
) -> void:
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

	# 2. Explosions: max 6 per frame, skip > 2500 m BEFORE taking a voice
	var max_exp_d2 := EXPLOSION_MAX_DISTANCE * EXPLOSION_MAX_DISTANCE
	var exp_count := explosions.size() / 5
	var exp_started := 0
	for i in range(exp_count):
		if exp_started >= 6:
			break
		var base := i * 5
		var pos := Vector3(explosions[base], explosions[base + 1], explosions[base + 2])
		if cam_pos.distance_squared_to(pos) > max_exp_d2:
			continue
		var radius := explosions[base + 3]
		var s: AudioStreamWAV = null
		if radius < 6.0:
			s = _sounds.bang
		elif radius < 15.0:
			s = _sounds.blast
		else:
			s = _sounds.blast2
		_play_oneshot(s, pos, -6.0, EXPLOSION_UNIT_SIZE, EXPLOSION_MAX_DISTANCE) # -6 dB: stacked explosions clipped the master at 0 dB
		exp_started += 1

	# 3. Player onetime events
	if player_alive:
		for ev in onetime:
			match ev:
				5: _play_oneshot(_sounds.touchdwn, player_pos, 0.0, PLAYER_EVENT_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
				8: _play_oneshot(_sounds.retractldg, player_pos, 0.0, PLAYER_EVENT_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
				9: _play_oneshot(_sounds.extendldg, player_pos, 0.0, PLAYER_EVENT_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
				1: _play_oneshot(_sounds.damage, player_pos, 0.0, PLAYER_EVENT_UNIT_SIZE, LAUNCH_MAX_DISTANCE)
				6: _play_oneshot(_sounds.hit, player_pos, 0.0, PLAYER_EVENT_UNIT_SIZE, LAUNCH_MAX_DISTANCE)

func _update_cockpit_warnings(player_dict: Dictionary, telemetry: Dictionary, player_alive: bool) -> void:
	var is_alive: bool = telemetry.get("is_alive", true) and player_alive

	# 1. Alarm handling
	var alarm: int = int(player_dict.get("alarm", 0))
	if not is_alive or alarm == 0:
		if _alarm_player.playing:
			_alarm_player.stop()
		_active_alarm_code = 0
	else:
		if alarm != _active_alarm_code:
			_active_alarm_code = alarm
			var s: AudioStreamWAV = null
			match alarm:
				1: s = _sounds.stallhorn
				2: s = _sounds.warning
				3: s = _sounds.gearhorn
			if s != null:
				_alarm_player.stream = s
				_alarm_player.volume_db = -8.0
				_alarm_player.play()
			else:
				_alarm_player.stop()

	# 2. Over-G warning: g_force >= 11.0
	var g_force: float = float(telemetry.get("g_force", 1.0))
	var is_over_g: bool = is_alive and (g_force >= OVER_G_LIMIT)
	if is_over_g:
		if not _over_g_player.playing:
			_over_g_player.play()
	else:
		if _over_g_player.playing:
			_over_g_player.stop()

	# 3. Lock-on beeping: suppressed while over-G plays
	var wpn_type: int = int(telemetry.get("weapon_type", 0))
	var locked_air: int = int(telemetry.get("locked_air_target_key", -1))
	var locked_gnd: int = int(telemetry.get("locked_ground_target_key", -1))
	var has_lock: bool = is_alive and not is_over_g and (
		((wpn_type == 1 or wpn_type == 6 or wpn_type == 10) and locked_air >= 0) or
		(wpn_type == 2 and locked_gnd >= 0)
	)
	if has_lock:
		if not _lock_beep_player.playing:
			_lock_beep_player.play()
	else:
		if _lock_beep_player.playing:
			_lock_beep_player.stop()
