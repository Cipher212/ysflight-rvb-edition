extends SceneTree

var _sim: Object
var _player_key := -1
var _failed := false
var _checks := 0

func _reset_fixture(friendly: bool = false) -> Array[int]:
	_sim.initialize_simulation()
	_sim.load_yfs(OS.get_cmdline_user_args()[1 if friendly else 0])
	_sim.set_ai_respawn_enabled(false)
	var shooters: Array[int] = []
	for key in _sim.get_airplane_transforms():
		if _sim.get_airplane_transforms()[key].get("is_player", false):
			_player_key = int(key)
		else:
			shooters.append(int(key))
			_sim.debug_set_combat_turner(int(key), 250.0)
			_sim.debug_move_airplane(int(key), -80000, 4000, -12000)
	_sim.get_audio_state()
	return shooters

func _loss_scenarios() -> void:
	var shooters := _reset_fixture()
	_sim.debug_move_airplane(shooters[0], -100000, 4000, -600)
	_check(_sim.debug_fire_missile(shooters[0], 1, _player_key, true), "loss fixture launched")
	_distance_check("before genuine target loss", 1)
	_sim.debug_move_airplane(_player_key, -100000, 4000, -4000)
	var losses := 0
	for frame in range(15):
		await process_frame
		losses += int(_sim.get_audio_state().get("incoming_missiles_lost", -100))
	_check(losses == 1, "native missile losing target produces exactly one end cue")
	_check(int(_sim.get_audio_state().get("incoming_missiles_lost", -1)) == 0, "loss queue drains once")
	_check(float(_sim.get_audio_state().nearest_incoming_missile_m) < 0, "genuine loss clears native incoming track")

	shooters = _reset_fixture()
	_sim.debug_move_airplane(shooters[0], -100000, 4000, -600)
	_sim.debug_fire_missile(shooters[0], 1, _player_key, true)
	_sim.get_audio_state()
	var hits := 0
	losses = 0
	for frame in range(120):
		# Exercise the real collision segment and accepted damage, rather than synthetic audio events.
		for weapon in _sim.get_active_weapons():
			if int(weapon.type) == 1:
				var point: Vector3 = weapon.pos + _sim.get_render_origin()
				_sim.debug_move_airplane(_player_key, point.x, point.y, -point.z)
				break
		await process_frame
		var state: Dictionary = _sim.get_audio_state()
		hits += state.get("missile_hits", PackedFloat64Array()).size() / 9
		losses += int(state.incoming_missiles_lost)
		if hits > 0:
			break
	_check(hits == 1, "native player impact exercised")
	_check(losses == 0, "player impact does not produce evasion beeps")

	shooters = _reset_fixture(true)
	_sim.debug_move_airplane(shooters[0], -100000, 4000, -600)
	_sim.debug_fire_missile(shooters[0], 1, _player_key, true)
	_sim.get_audio_state()
	losses = 0
	var friendly_ended := false
	for frame in range(120):
		for weapon in _sim.get_active_weapons():
			if int(weapon.type) == 1:
				var point: Vector3 = weapon.pos + _sim.get_render_origin()
				_sim.debug_move_airplane(_player_key, point.x, point.y, -point.z)
				break
		await process_frame
		var state: Dictionary = _sim.get_audio_state()
		losses += int(state.incoming_missiles_lost)
		if float(state.nearest_incoming_missile_m) < 0:
			friendly_ended = true
			break
	_check(friendly_ended and losses == 0, "player contact excludes evasion cue even for same-team missile")

	shooters = _reset_fixture()
	_sim.debug_move_airplane(shooters[0], -100000, 4000, -600)
	_sim.debug_fire_missile(shooters[0], 1, _player_key, true)
	_sim.get_audio_state()
	losses = 0
	var other_hit := false
	for frame in range(120):
		for weapon in _sim.get_active_weapons():
			if int(weapon.type) == 1:
				var point: Vector3 = weapon.pos + _sim.get_render_origin()
				_sim.debug_move_airplane(shooters[1], point.x, point.y, -point.z)
				break
		await process_frame
		var state: Dictionary = _sim.get_audio_state()
		losses += int(state.incoming_missiles_lost)
		var impacts: PackedFloat64Array = state.get("missile_hits", PackedFloat64Array())
		for offset in range(0, impacts.size(), 9):
			other_hit = other_hit or int(impacts[offset + 7]) == shooters[1]
		if losses > 0:
			break
	_check(other_hit, "native collision with another aircraft exercised")
	_check(losses == 1, "missile hitting another object produces one end cue")

	shooters = _reset_fixture()
	_sim.debug_move_airplane(shooters[0], -100000, 4000, -1200)
	_sim.debug_fire_missile(shooters[0], 1, _player_key, true)
	_sim.get_audio_state()
	_sim.set_player_weapon_inputs(false, false, false, false, true)
	losses = 0
	var diverted_while_target_retained := false
	for frame in range(30):
		await process_frame
		var state: Dictionary = _sim.get_audio_state()
		losses += int(state.incoming_missiles_lost)
		if int(state.incoming_missiles_lost) > 0:
			diverted_while_target_retained = float(state.nearest_incoming_missile_m) > 0
			break
	_sim.set_player_weapon_inputs(false, false, false, false, false)
	_check(losses == 1 and diverted_while_target_retained,
		"real flare diversion produces cue even while legacy warning retains original target")
	var reset_shooters := _reset_fixture()
	_check(reset_shooters.size() == 2 and int(_sim.get_audio_state().incoming_missiles_lost) == 0,
		"mission reset produces no stale end cue")

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	_checks += 1
	_failed = _failed or not ok
	print("MISSILE WARNING ", "PASS " if ok else "FAIL ", label)

func _distance_check(label: String, expected_count: int) -> float:
	var rows: Array = _sim.get_ai_combat_state()
	var player_position: Array[float] = [0.0, 0.0, 0.0]
	for row in rows:
		if int(row.key) == _player_key:
			player_position = [float(row.x), float(row.y), float(row.z)]
	var expected := -1.0
	var count := 0
	for missile in rows[0].get("missiles", []):
		if int(missile.target) == _player_key and float(missile.life) > 0.000001:
			count += 1
			var dx: float = missile.x - player_position[0]
			var dy: float = missile.y - player_position[1]
			var dz: float = missile.z - player_position[2]
			var distance := sqrt(dx * dx + dy * dy + dz * dz)
			expected = distance if expected < 0.0 else minf(expected, distance)
	var state: Dictionary = _sim.get_audio_state()
	var actual := float(state.get("nearest_incoming_missile_m", -999.0))
	_check(count == expected_count, label + " matching missile count")
	_check(absf(actual - expected) < 0.00001, label + " exact native 3D minimum distance")
	return actual

func _run() -> void:
	_sim = ClassDB.instantiate("YSFlightSimulation")
	root.add_child(_sim)
	_sim.initialize_simulation()
	_sim.load_yfs(OS.get_cmdline_user_args()[0])
	_sim.set_ai_respawn_enabled(false)
	_sim.set_render_origin_threshold(1.0)
	for frame in range(3):
		await process_frame
	var shooters: Array[int] = []
	for key in _sim.get_airplane_transforms():
		if _sim.get_airplane_transforms()[key].get("is_player", false):
			_player_key = int(key)
		else:
			shooters.append(int(key))
	_check(_player_key >= 0 and shooters.size() == 2, "player and two launchers loaded")
	_distance_check("no incoming", 0)
	_sim.debug_move_airplane(shooters[0], -100000, 4000, -12000)
	_check(_sim.debug_fire_missile(shooters[0], 1, _player_key, true), "real far missile launched")
	_check(_distance_check("far only", 1) > 8046.72, "far missile exceeds five ordinary miles")
	_sim.debug_move_airplane(shooters[1], -100000, 4000, -600)
	_check(_sim.debug_fire_missile(shooters[1], 1, _player_key, true), "real near missile launched")
	_check(_distance_check("far plus near", 2) < 8046.72, "near missile wins over distant missile")
	_check(_sim.debug_fire_missile(_player_key, 1, shooters[0], true), "unrelated outbound missile launched")
	_distance_check("outbound missile excluded", 2)
	_sim.debug_move_airplane(_player_key, -100000, 14000, 0)
	_check(_distance_check("vertical separation", 2) > 8046.72, "classification uses 3D rather than horizontal range")
	var origin_before: Vector3 = _sim.get_render_origin()
	_sim.debug_move_airplane(_player_key, -100050, 4000, 0)
	for frame in range(3):
		await process_frame
	_check(_sim.get_render_origin() != origin_before, "real render origin shift exercised")
	_distance_check("after origin shift", 2)
	_sim.initialize_simulation()
	_sim.load_yfs(OS.get_cmdline_user_args()[0])
	_check(float(_sim.get_audio_state().get("nearest_incoming_missile_m", -999.0)) == -1.0,
		"mission reset clears incoming distance")
	await _loss_scenarios()
	_sim.queue_free()
	_sim = null
	for frame in range(3):
		await process_frame
	print("MISSILE WARNING RESULT ", "FAIL" if _failed else "PASS", " checks=", _checks)
	quit.call_deferred(1 if _failed else 0)
