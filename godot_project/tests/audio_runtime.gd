extends SceneTree

# Verify the normal scene's native feed, installed PCM and actual playing voices.
var _main: Node
var _checks := 0
var _failed := false

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	_checks += 1
	_failed = _failed or not ok
	print("AUDIO RUNTIME ", "PASS " if ok else "FAIL ", label)

func _frames(count: int) -> void:
	for frame in range(count):
		await process_frame

func _run() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	current_scene = _main
	await _frames(30)
	var manager: Node3D = _main.audio_manager
	var sounds = manager._sounds
	var streams := {
		"bang.wav": sounds.bang, "blast.wav": sounds.blast,
		"blast2.wav": sounds.bomb_blast, "blast2_water.wav": sounds.bomb_water,
		"burner.wav": sounds.burner, "cockpit_drone.wav": sounds.cockpit_drone,
		"stallhorn.wav": sounds.stallhorn,
		"extendldg.wav": sounds.extendldg, "retractldg.wav": sounds.retractldg,
	}
	for band in range(10):
		streams["engine%d.wav" % band] = sounds.engine_bands[band]
	streams.merge({"locked.wav": sounds.enemy_locked, "incoming.wav": sounds.incoming,
		"incoming_near.wav": sounds.incoming_near, "lock_on.wav": sounds.lock_on,
		"missile_lost.wav": sounds.missile_lost})
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://sound/sound_revamp_manifest.json"))
	var warnings: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://sound/missile_warning_manifest.json"))
	manifest.files.append_array(warnings.files)
	for entry in manifest.files:
		if entry.output == "notice.wav":
			continue # Superseded acquisition cue; provenance remains in the original bank manifest.
		var path: String = "res://sound/" + entry.output
		var bytes := FileAccess.get_file_as_bytes(path)
		var hash_context := HashingContext.new()
		hash_context.start(HashingContext.HASH_SHA256)
		hash_context.update(bytes)
		var actual_sha := hash_context.finish().hex_encode()
		_check(actual_sha == entry.sha256, entry.output + " matches prepared pack hash")
		var disk := AudioStreamWAV.load_from_file(ProjectSettings.globalize_path(path))
		var loaded: AudioStreamWAV = streams[entry.output]
		_check(loaded != null and disk != null and loaded.data == disk.data,
			entry.output + " PCM loaded by normal game scene")
	_check(sounds.crash_blast == sounds.bomb_blast and sounds.legacy_blast == sounds.blast,
		"crash and replay fallback use installed explosions")
	var controls: Node = _main.controls
	controls.current_throttle = 0.35
	controls._afterburner_lit = false
	_main.camera_rig.set_mode(2)
	await _frames(180)
	var voices = manager._engines
	var voice = voices.player_voice
	_check(voice.assigned_key >= 0, "native player aircraft assigned to engine voice")
	_check(voice.engine_player.playing or voice.upper_player.playing,
		"normal gameplay plays installed jet bands externally")
	_check(not voices.drone.playing, "exterior has no cockpit drone")
	var exterior_db: float = maxf(voice.engine_player.volume_db, voice.upper_player.volume_db)
	_main.camera_rig.set_mode(1)
	await _frames(30)
	_check(voices.drone.playing and voices.drone.stream == sounds.cockpit_drone,
		"F1 plays MP3-derived cockpit drone")
	var interior_db: float = maxf(voice.engine_player.volume_db, voice.upper_player.volume_db)
	_check(interior_db < exterior_db - 10.0, "F1 reduces normal engine by 12 dB")
	var engine_bus := AudioServer.get_bus_index("PlayerEngine")
	_check(AudioServer.is_bus_effect_enabled(engine_bus, 0), "F1 enables engine muffling")
	controls.current_throttle = 1.0
	controls._afterburner_lit = true
	await _frames(180)
	_check(voice.burner_player.playing and voice.burner_player.stream == sounds.burner,
		"native afterburner plays installed burner recording")
	_check(voice.burner_player.volume_db > maxf(voice.engine_player.volume_db,
		voice.upper_player.volume_db), "cockpit burner is stronger than normal engine")
	_main.camera_rig.set_mode(2)
	await _frames(30)
	_check(not voices.drone.playing and not AudioServer.is_bus_effect_enabled(engine_bus, 0),
		"F2 stops cockpit drone and removes engine muffling")
	_main.ysflight_sim.press_button("LANDINGGEAR")
	await _frames(3)
	var heard_gear := false
	for player in manager._oneshot_players:
		if player.playing and player.stream == sounds.extendldg:
			heard_gear = true
	_check(heard_gear, "native gear extension plays installed gear recording")
	var state: Dictionary = _main.ysflight_sim.get_audio_state()
	_check(state.has("classified_explosions") and state.has("missile_hits"),
		"active compiled DLL provides classified impacts and missile hits")
	_check(state.has("nearest_incoming_missile_m") and float(state.nearest_incoming_missile_m) == -1.0,
		"active compiled DLL provides warning distance with no false threat")
	_check(state.has("incoming_missiles_lost") and int(state.incoming_missiles_lost) == 0,
		"active compiled DLL provides missile-loss cue without a false event")
	_check(not AudioServer.is_bus_mute(AudioServer.get_bus_index("Master")),
		"saved player settings leave Master audible")
	_main.queue_free()
	_main = null
	await _frames(3)
	print("AUDIO RUNTIME RESULT ", "FAIL" if _failed else "PASS", " checks=", _checks)
	quit.call_deferred(1 if _failed else 0)
