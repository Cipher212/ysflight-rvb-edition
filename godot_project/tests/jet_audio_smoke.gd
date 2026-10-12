extends SceneTree

# Exercise the real manager, players and bus graph silently, using deterministic native-format events.
const AudioManagerScript := preload("res://audio_manager.gd")
const AudioVolumeScript := preload("res://audio/audio_volume.gd")
class FakeSim extends RefCounted:
	var call_count: int = 0
	var player_key: int = 1
	var alarm: int = 0
	var aircraft_data: PackedFloat32Array = PackedFloat32Array()
	var onetime_data: PackedInt32Array = PackedInt32Array()
	var launches_data: PackedFloat32Array = PackedFloat32Array()
	var classified_data: PackedFloat32Array = PackedFloat32Array()
	var hits_data: PackedFloat64Array = PackedFloat64Array()
	var explosions_data: PackedFloat32Array = PackedFloat32Array()
	var nearest_incoming_m: float = -1.0
	var incoming_missiles_lost: int = 0

	func get_audio_state() -> Dictionary:
		call_count += 1
		return {
			"player": {"key": player_key, "alarm": alarm},
			"aircraft": aircraft_data,
			"onetime": onetime_data,
			"launches": launches_data,
			"explosions": explosions_data,
			"classified_explosions": classified_data,
			"missile_hits": hits_data,
			"nearest_incoming_missile_m": nearest_incoming_m,
			"incoming_missiles_lost": incoming_missiles_lost,
		}

	func set_aircraft_list(list: Array) -> void:
		aircraft_data.clear()
		aircraft_data.resize(list.size() * 11)
		for i in range(list.size()):
			var ac: Dictionary = list[i]
			var base := i * 11
			aircraft_data[base + 0] = float(ac.get("key", i + 1))
			var pos: Vector3 = ac.get("pos", Vector3.ZERO)
			aircraft_data[base + 1] = pos.x
			aircraft_data[base + 2] = pos.y
			aircraft_data[base + 3] = pos.z
			var vel: Vector3 = ac.get("vel", Vector3.ZERO)
			aircraft_data[base + 4] = vel.x
			aircraft_data[base + 5] = vel.y
			aircraft_data[base + 6] = vel.z
			aircraft_data[base + 7] = float(ac.get("engine_kind", 0))
			aircraft_data[base + 8] = float(ac.get("power", 0.8))
			aircraft_data[base + 9] = float(ac.get("gun_firing", 0.0))
			aircraft_data[base + 10] = float(ac.get("is_player", 0.0))

class FakeControls extends Node:
	signal changed(key: String)
	var values: Dictionary = {}
	func get_value(key: String, fallback: float) -> float:
		return float(values.get(key, fallback))

var _sim: FakeSim
var _mgr: Node3D
var _cam: Camera3D
var _checks: int = 0
var _failed: bool = false
var _telemetry: Dictionary = {"is_alive": true, "g_force": 1.0, "weapon_type": 0}

func _initialize() -> void:
	_run.call_deferred()

func _assert(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failed = true
		print("SMOKE FAIL: ", label)

func _tick(interior: bool = false, frames: int = 1) -> void:
	for i in range(frames):
		_mgr.update(1.0 / 60.0, _cam, interior, _telemetry)

func _air(kind: int = 0, power: float = 0.8) -> void:
	_sim.set_aircraft_list([
		{"key": 1, "engine_kind": kind, "power": power, "is_player": 1.0},
		{"key": 2, "engine_kind": 0, "power": 0.8, "pos": Vector3(50, 0, 0)},
	])

func _clear_events() -> void:
	_sim.classified_data.clear()
	_sim.hits_data.clear()
	_sim.onetime_data.clear()
	_sim.launches_data.clear()
	for p in _mgr._oneshot_players:
		p.stop()

func _playing_streams() -> Array:
	var streams: Array = []
	for p in _mgr._oneshot_players:
		if p.playing:
			streams.append(p.stream)
	return streams

func _impact(weapon: int, incident: int, surface: int = 0, pos: Vector3 = Vector3.ZERO) -> void:
	_clear_events()
	_sim.classified_data = PackedFloat32Array([pos.x, pos.y, pos.z, 30, surface, incident, weapon])
	_tick()

func _run() -> void:
	_sim = FakeSim.new()
	_cam = Camera3D.new()
	root.add_child(_cam)
	_mgr = AudioManagerScript.new()
	root.add_child(_mgr)
	_mgr.setup(_sim)
	var sounds = _mgr._sounds
	_assert(sounds.engine_bands.size() == 10, "all ten engine bands loaded")
	for stream in sounds.engine_bands + [sounds.burner, sounds.cockpit_drone, sounds.stallhorn,
		sounds.incoming, sounds.incoming_near, sounds.lock_on]:
		_assert(stream != null and not stream.stereo and stream.mix_rate == 44100
			and stream.loop_mode == AudioStreamWAV.LOOP_FORWARD, "loop format and flags")
	for stream in [sounds.bang, sounds.blast, sounds.bomb_blast, sounds.bomb_water,
		sounds.enemy_locked, sounds.missile_lost, sounds.retractldg, sounds.extendldg]:
		_assert(stream != null and stream.loop_mode == AudioStreamWAV.LOOP_DISABLED, "one-shot never loops")
	_assert(sounds.bomb_water.data != sounds.bomb_blast.data, "water uses filtered source")
	_assert(sounds.incoming_near.get_length() < 6.5 and sounds.missile_lost.get_length() == 2.0,
		"near warning excludes ending two seconds and end cue is separate")
	_air()
	_tick(false, 60)
	var calls := _sim.call_count
	_tick()
	_assert(_sim.call_count == calls + 1, "native feed collected exactly once per update")
	var voices = _mgr._engines
	var pv = voices.player_voice
	_assert(voices._other_engine_voices.size() == 6, "nearest-other engine pool bounded at six")
	for band in range(10):
		_air(0, float(band) / 9.0)
		_tick(false, 60)
		var selected: AudioStreamPlayer3D = pv.engine_player if band % 2 == 0 else pv.upper_player
		_assert(selected.stream == sounds.engine_bands[band] and selected.playing, "throttle reaches band %d" % band)
		_assert(is_equal_approx(selected.pitch_scale, 1.0), "bands not pitched twice")
	_air(0, 0.5)
	_tick(false, 60)
	_assert(pv.engine_player.playing and pv.upper_player.playing, "adjacent bands crossfade")
	var playback = pv.engine_player.get_stream_playback()
	_tick(false, 10)
	_assert(pv.engine_player.get_stream_playback() == playback, "stable throttle preserves running loop")
	var exterior_db: float = pv.engine_player.volume_db
	_tick(true, 20)
	_assert(is_equal_approx(pv.engine_player.volume_db, exterior_db - 12.0), "cockpit normal engine quieter")
	_assert(voices.drone.playing and is_equal_approx(voices.drone.pitch_scale, 1.0), "cockpit drone constant pitch")
	_assert(voices.drone.bus == &"VolEngines", "drone follows engine slider")
	var player_bus := AudioServer.get_bus_index("PlayerEngine")
	_assert(AudioServer.is_bus_effect_enabled(player_bus, 0), "cockpit low-pass enabled")
	_assert(AudioServer.get_bus_effect(player_bus, 0).cutoff_hz <= 700.0, "cockpit engine strongly muffled")
	_air(1, 1.0)
	_tick(true, 40)
	_assert(pv.burner_player.playing and pv.burner_player.stream == sounds.burner, "real burner source selected")
	_assert(pv.burner_player.volume_db > pv.engine_player.volume_db, "burner more prominent in cockpit")
	_tick(false, 20)
	_assert(not voices.drone.playing and not AudioServer.is_bus_effect_enabled(player_bus, 0), "exterior stops drone and muffling")
	_air(2)
	_tick(true, 1)
	_assert(pv.engine_player.stream == sounds.prop0 and not pv.burner_player.playing
		and not pv.upper_player.playing and not voices.drone.playing, "prop isolated even after burner")
	_air()
	_tick(true, 40)
	_sim.player_key = -1
	_telemetry.is_alive = false
	_tick(true)
	_assert(not pv.engine_player.playing and not pv.upper_player.playing and not pv.burner_player.playing
		and not voices.drone.playing, "death stops all player engine layers")
	_sim.player_key = 1
	_telemetry.is_alive = true
	_tick(true, 40)
	_assert(pv.engine_player.playing and voices.drone.playing, "respawn restores cockpit sound")
	for weapon in [3, 7, 9]:
		_impact(weapon, 3)
		_assert(_playing_streams() == [sounds.bomb_blast], "bomb land/target selects blast2")
		_impact(weapon, 3, 1)
		_assert(_playing_streams() == [sounds.bomb_water], "bomb water selects muffled blast2")
	for weapon in [1, 2, 4, 6, 10]:
		_impact(weapon, 2 if weapon in [1, 6, 10] else 3)
		_assert(_playing_streams() == [sounds.blast], "missile/rocket nearby selects smaller blast")
	for weapon in [5, 200]:
		for surface in [0, 1]:
			_impact(weapon, 3, surface)
			_assert(_playing_streams().is_empty(), "flare impact silent on land/water")
	_impact(-1, 5)
	_assert(_playing_streams().is_empty(), "continuing wreck fire silent")
	_impact(-1, 4)
	_assert(_playing_streams() == [sounds.crash_blast], "aircraft crash retains heavy blast")
	_assert(sounds.crash_blast == sounds.bomb_blast, "aircraft crash uses installed blast2")
	_assert(sounds.legacy_bang == sounds.bang and sounds.legacy_blast == sounds.blast,
		"unclassified replay events use installed pack sounds")
	_impact(0, 1)
	_assert(_playing_streams() == [sounds.hit], "gun strike uses impact source")
	_impact(3, 3, 0, Vector3(20000, 0, 0))
	_assert(_playing_streams().is_empty(), "far impact does not allocate a voice")
	# A lethal hit emits both weapon and destruction explosions, and player damage counters.
	_clear_events()
	_sim.hits_data = PackedFloat64Array([0, 0, 0, 1, 0, 0, 1, 1, 1])
	_sim.classified_data = PackedFloat32Array([0, 15, 0, 30, 0, 2, 1, 1, 15, 0, 30, 0, 4, -1,
		100, 0, 0, 30, 0, 3, 3])
	_sim.onetime_data = PackedInt32Array([1, 6])
	_tick()
	_assert(_playing_streams() == [sounds.bang, sounds.bomb_blast], "hit dedup retains unrelated simultaneous bomb")
	var active: AudioStreamPlayer3D = _mgr._oneshot_players[0]
	var before := active.global_position
	_mgr.rebase(Vector3(1000, 0, 0))
	_assert(active.global_position == before - Vector3(1000, 0, 0), "pooled one-shot follows origin shift")
	_clear_events()
	_sim.onetime_data = PackedInt32Array([8, 9])
	_tick()
	_assert(_playing_streams() == [sounds.retractldg, sounds.extendldg], "native gear events select new sources")
	_clear_events()
	_sim.alarm = 1
	_tick(true)
	_assert(_mgr._warnings.alarm_player.stream == sounds.stallhorn and _mgr._warnings.alarm_player.playing, "stall uses revamp horn")
	_sim.alarm = 2
	_tick(true)
	_assert(_mgr._warnings.alarm_player.stream == sounds.incoming, "native missile alarm priority preserved")
	_sim.nearest_incoming_m = 8046.73
	_tick(true)
	_assert(_mgr._warnings.alarm_player.stream == sounds.incoming, "beyond five ordinary miles uses distant recording")
	_sim.nearest_incoming_m = 8046.72
	_tick(true)
	_assert(_mgr._warnings.alarm_player.stream == sounds.incoming_near, "exact five ordinary mile boundary uses near recording")
	playback = _mgr._warnings.alarm_player.get_stream_playback()
	_sim.nearest_incoming_m = 100.0
	_tick(true, 20)
	_assert(_mgr._warnings.alarm_player.get_stream_playback() == playback, "same urgency does not restart incoming clip")
	_sim.nearest_incoming_m = 9000.0
	_tick(true)
	_assert(_mgr._warnings.alarm_player.stream == sounds.incoming, "remaining far missile downgrades warning")
	var lost_player: AudioStreamPlayer = _mgr._warnings.missile_lost_player
	_assert(not lost_player.playing, "crossing distance boundary never plays ending beeps")
	_sim.incoming_missiles_lost = 2
	_tick(true)
	_assert(lost_player.playing and lost_player.stream == sounds.missile_lost,
		"native lost-track event plays separate ending beeps")
	_assert(_mgr._warnings.alarm_player.playing and _mgr._warnings.alarm_player.stream == sounds.incoming,
		"another incoming missile retains its warning during lost-track cue")
	playback = lost_player.get_stream_playback()
	_tick(true)
	_assert(lost_player.get_stream_playback() == playback, "simultaneous lost tracks do not stack or restart beeps")
	_sim.incoming_missiles_lost = 0
	lost_player.stop()
	_sim.alarm = 0
	_tick(true)
	_assert(not _mgr._warnings.alarm_player.playing, "warning ends when native alarm clears")
	_assert(not lost_player.playing, "alarm clearing alone never plays ending beeps")
	_sim.incoming_missiles_lost = 1
	_tick(true)
	_assert(lost_player.playing, "last incoming track loss plays ending beeps")
	_telemetry.is_alive = false
	_tick(true)
	_assert(not lost_player.playing, "death stops and suppresses ending cue")
	_telemetry.is_alive = true
	_sim.player_key = 99
	_tick(true)
	_assert(not lost_player.playing, "player change suppresses stale ending cue")
	_sim.player_key = 1
	_sim.incoming_missiles_lost = 0
	_tick(true)
	_sim.nearest_incoming_m = 1.0
	_tick(true)
	_assert(not _mgr._warnings.alarm_player.playing, "distance alone never creates a new native warning")
	_telemetry.is_locked_by_enemy = true
	_tick(true)
	var enemy_lock: AudioStreamPlayer = _mgr._warnings.enemy_lock_player
	_assert(enemy_lock.playing and enemy_lock.stream == sounds.enemy_locked,
		"existing enemy-lock flag plays locked recording immediately")
	playback = enemy_lock.get_stream_playback()
	_tick(true, 299)
	_assert(enemy_lock.get_stream_playback() == playback, "enemy-lock cue does not restart before five seconds")
	_tick(true, 2)
	_assert(enemy_lock.get_stream_playback() != playback, "enemy-lock cue repeats after five seconds")
	_sim.alarm = 2
	_tick(true)
	_assert(not enemy_lock.playing and _mgr._warnings.alarm_player.stream == sounds.incoming_near,
		"incoming warning suppresses periodic enemy-lock cue")
	_sim.alarm = 0
	_tick(true)
	_assert(enemy_lock.playing, "enemy-lock cue resumes if lock remains after incoming clears")
	_telemetry.is_locked_by_enemy = false
	_tick(true)
	_assert(not enemy_lock.playing, "enemy-lock cue stops when original flag clears")
	_telemetry.weapon_type = 1
	_telemetry.locked_air_target_key = 10
	_tick(false)
	var lock_player: AudioStreamPlayer = _mgr._warnings.lock_player
	_assert(lock_player.stream == sounds.lock_on and lock_player.playing and lock_player.bus == &"VolWarnings", "weapon lock audible in exterior")
	_assert(sounds.lock_on.loop_mode == AudioStreamWAV.LOOP_FORWARD and sounds.lock_on.loop_begin > 40000,
		"weapon lock loop excludes acquisition beeps")
	var decoder: AudioStreamPlayback = sounds.lock_on.instantiate_playback()
	decoder.start()
	decoder.mix_audio(1.0, int(AudioServer.get_mix_rate() * 10.0))
	var loop_pos := decoder.get_playback_position()
	_assert(loop_pos >= float(sounds.lock_on.loop_begin) / sounds.lock_on.mix_rate
		and loop_pos < sounds.lock_on.get_length(), "real WAV decoder wraps into tone region after intro and full clip")
	decoder.stop()
	playback = lock_player.get_stream_playback()
	_tick(true, 20)
	_assert(lock_player.get_stream_playback() == playback, "same lock and camera change do not replay")
	_telemetry.locked_air_target_key = 11
	_tick()
	_assert(lock_player.get_stream_playback() != playback, "changed target replays acquisition intro")
	playback = lock_player.get_stream_playback()
	_telemetry.locked_air_target_key = -1
	_tick()
	_assert(not lock_player.playing, "lost weapon lock stops sustained tone immediately")
	_telemetry.locked_air_target_key = 11
	_tick()
	_assert(lock_player.get_stream_playback() != playback, "lost/reacquired target replays acquisition intro")
	_telemetry.weapon_type = 2
	_telemetry.locked_ground_target_key = 11
	playback = lock_player.get_stream_playback()
	_tick()
	_assert(lock_player.get_stream_playback() != playback, "ground/air lock identities distinct")
	var controls := FakeControls.new()
	root.add_child(controls)
	var volume := AudioVolumeScript.new()
	root.add_child(volume)
	volume.setup(controls)
	controls.values = {"volume_engines": 0.0, "volume_warnings": 0.0, "volume_effects": 0.0}
	volume.apply()
	for bus in ["VolEngines", "VolWarnings", "VolEffects"]:
		_assert(AudioServer.is_bus_mute(AudioServer.get_bus_index(bus)), "category slider mute " + bus)
	_assert(AudioServer.get_bus_send(player_bus) == &"VolEngines", "engine category routing preserved")
	var nodes := _mgr.get_child_count()
	var buses := AudioServer.bus_count
	for i in range(100):
		_tick(i % 2 == 0)
	_assert(_mgr.get_child_count() == nodes and AudioServer.bus_count == buses, "rapid toggles never grow players/buses")
	_assert(nodes == 51, "fixed 51-player total")
	_sim.set_aircraft_list([])
	_tick(false, 30)
	for v in [pv] + voices._other_engine_voices:
		_assert(not v.engine_player.playing and not v.upper_player.playing and not v.burner_player.playing, "empty mission stops voice")
	_mgr.queue_free()
	_cam.queue_free()
	volume.queue_free()
	controls.queue_free()
	await process_frame
	print("JET AUDIO SMOKE ", "FAIL" if _failed else "OK", " checks=", _checks)
	quit(1 if _failed else 0)
