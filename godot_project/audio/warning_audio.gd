extends RefCounted

const OVER_G_LIMIT: float = 11.0
const G_BREATH_THRESHOLD: float = 7.5
const G_BREATH_MAX: float = 10.5
const NEAR_MISSILE_METRES: float = 5.0 * 1609.344
const ENEMY_LOCK_INTERVAL: float = 5.0
const LOCK_VOLUME_DB: float = -10.0
const LOCK_UNDER_WARNING_DB: float = -18.0
const SoundLibrary := preload("res://audio/sound_library.gd")

var alarm_player: AudioStreamPlayer
var lock_player: AudioStreamPlayer
var enemy_lock_player: AudioStreamPlayer
var over_g_player: AudioStreamPlayer
var g_breath_player: AudioStreamPlayer
var buffet_player: AudioStreamPlayer
var missile_lost_player: AudioStreamPlayer
var _sounds: SoundLibrary
var _alarm_code: int = 0
var _player_key: int = -1
var _lock_key: int = -1
var _lock_kind: int = 0
var _enemy_lock_remaining: float = 0.0
var _g_breath_hold: float = 0.0
var _buffet_gain: float = 0.0

func setup(host: Node, sounds: SoundLibrary) -> void:
	_sounds = sounds
	alarm_player = _create(host, "AlarmPlayer", "Cockpit", -8.0)
	lock_player = _create(host, "WeaponLock", "VolWarnings", LOCK_VOLUME_DB)
	lock_player.stream = sounds.lock_on
	enemy_lock_player = _create(host, "EnemyLock", "Cockpit", -8.0)
	enemy_lock_player.stream = sounds.enemy_locked
	missile_lost_player = _create(host, "MissileLost", "Cockpit", -8.0)
	missile_lost_player.stream = sounds.missile_lost
	over_g_player = _create(host, "OverGPlayer", "Cockpit", -8.0)
	over_g_player.stream = sounds.over_g
	g_breath_player = _create(host, "GForceBreath", "Cockpit", -11.0)
	g_breath_player.stream = sounds.g_breath
	buffet_player = _create(host, "StallBuffet", "Cockpit", -80.0)
	buffet_player.stream = sounds.stall_buffet

func _create(host: Node, label: String, bus: StringName, volume: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = label
	p.bus = bus
	p.volume_db = volume
	host.add_child(p)
	return p

func update(delta: float, player: Dictionary, telemetry: Dictionary, alive: bool,
		nearest_incoming_m: float = -1.0, incoming_missiles_lost: int = 0) -> void:
	alive = alive and bool(telemetry.get("is_alive", true))
	var key := int(player.get("key", -1)) if alive else -1
	if key != _player_key:
		_player_key = key
		_lock_key = -1
		_lock_kind = 0
		_enemy_lock_remaining = 0.0
		_g_breath_hold = 0.0
		lock_player.stop()
		enemy_lock_player.stop()
		missile_lost_player.stop()
		if g_breath_player != null:
			g_breath_player.stop()
		if buffet_player != null:
			buffet_player.stop()
		_buffet_gain = 0.0
		incoming_missiles_lost = 0
	# Multiple endings in one frame share a cue; another live missile keeps its warning.
	if alive and incoming_missiles_lost > 0 and not missile_lost_player.playing:
		missile_lost_player.play()
	var alarm := int(player.get("alarm", 0)) if alive else 0
	_update_alarm(alarm, nearest_incoming_m)
	_update_enemy_lock(delta, alive and bool(telemetry.get("is_locked_by_enemy", false)), alarm == 2)
	var lock_db := LOCK_UNDER_WARNING_DB if alarm == 2 else LOCK_VOLUME_DB
	if not is_equal_approx(lock_player.volume_db, lock_db):
		lock_player.volume_db = lock_db
	var over_g := alive and float(telemetry.get("g_force", 1.0)) >= OVER_G_LIMIT
	if over_g and not over_g_player.playing:
		over_g_player.play()
	elif not over_g and over_g_player.playing:
		over_g_player.stop()
	_update_g_breath(delta, telemetry, alive)
	_update_buffet(delta, telemetry, alive)
	_update_weapon_lock(telemetry, alive)

func _update_buffet(delta: float, telemetry: Dictionary, alive: bool) -> void:
	if buffet_player == null or _sounds.stall_buffet == null:
		return
	if not alive:
		if buffet_player.playing:
			buffet_player.stop()
		_buffet_gain = 0.0
		return
	var speed: float = float(telemetry.get("speed_ms", 0.0))
	var aoa: float = float(telemetry.get("aoa_deg", 0.0))
	var g: float = float(telemetry.get("g_force", 1.0))
	var target_gain: float = 0.0
	if speed >= 25.0:
		var aoa_frac := clampf((aoa - 13.0) / 9.0, 0.0, 1.0)
		var g_frac := clampf((g - 6.2) / 3.0, 0.0, 1.0)
		target_gain = maxf(aoa_frac, g_frac)
	_buffet_gain = move_toward(_buffet_gain, target_gain, delta / 0.15)
	if _buffet_gain > 0.005:
		buffet_player.pitch_scale = lerpf(0.92, 1.15, clampf(speed / 250.0, 0.0, 1.0))
		buffet_player.volume_db = lerpf(-32.0, -17.5, _buffet_gain)
		if not buffet_player.playing:
			buffet_player.play()
	elif buffet_player.playing:
		buffet_player.stop()

func _update_g_breath(delta: float, telemetry: Dictionary, alive: bool) -> void:
	if g_breath_player == null or _sounds.g_breath == null:
		return
	if not alive:
		if g_breath_player.playing:
			g_breath_player.stop()
		_g_breath_hold = 0.0
		return
	var g: float = float(telemetry.get("g_force", 1.0))
	if g >= G_BREATH_THRESHOLD:
		_g_breath_hold = 1.6
		var frac := clampf((g - G_BREATH_THRESHOLD) / (G_BREATH_MAX - G_BREATH_THRESHOLD), 0.0, 1.0)
		var target_db := lerpf(-11.0, -3.5, frac)
		g_breath_player.volume_db = lerpf(g_breath_player.volume_db, target_db, minf(1.0, delta * 12.0))
		if not g_breath_player.playing:
			g_breath_player.play()
	elif _g_breath_hold > 0.0:
		_g_breath_hold = maxf(0.0, _g_breath_hold - delta)
		var fade_db := lerpf(-16.0, -8.5, clampf(_g_breath_hold / 1.6, 0.0, 1.0))
		g_breath_player.volume_db = move_toward(g_breath_player.volume_db, fade_db, delta * 10.0)
		if _g_breath_hold <= 0.0 and g_breath_player.playing:
			g_breath_player.stop()
	elif g_breath_player.playing:
		g_breath_player.stop()

func _update_alarm(alarm: int, distance: float) -> void:
	var stream: AudioStreamWAV = null
	match alarm:
		1: stream = _sounds.stallhorn
		2: stream = _sounds.incoming_near if distance >= 0.0 and distance <= NEAR_MISSILE_METRES else _sounds.incoming
		3: stream = _sounds.gearhorn
	# Preserve the native alarm selection; distance changes only the missile recording.
	if alarm != _alarm_code or alarm_player.stream != stream:
		_alarm_code = alarm
		alarm_player.stop()
		alarm_player.stream = stream
		if stream != null:
			alarm_player.play()

func _update_enemy_lock(delta: float, locked: bool, incoming: bool) -> void:
	if not locked or incoming:
		enemy_lock_player.stop()
		_enemy_lock_remaining = 0.0
		return
	_enemy_lock_remaining -= delta
	if _enemy_lock_remaining <= 0.0:
		enemy_lock_player.play()
		_enemy_lock_remaining = ENEMY_LOCK_INTERVAL

func _update_weapon_lock(telemetry: Dictionary, alive: bool) -> void:
	var weapon := int(telemetry.get("weapon_type", 0))
	var next_key := -1
	var next_kind := 0
	if alive:
		if weapon in [1, 6, 10]:
			next_key = int(telemetry.get("locked_air_target_key", -1))
			next_kind = 1
		elif weapon == 2:
			next_key = int(telemetry.get("locked_ground_target_key", -1))
			next_kind = 2
	if next_key < 0:
		lock_player.stop()
	elif next_key != _lock_key or next_kind != _lock_kind:
		# AudioStreamWAV plays the intro once, then loops only its sustained-tone region.
		lock_player.play()
	_lock_key = next_key
	_lock_kind = next_kind
