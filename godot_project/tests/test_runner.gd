extends Node

# Automated game test (main.gd starts it with "-- --run-tests"; tools/run_tests.py runs it and prints the
# result). Plays through the 16v16 mission with scripted inputs and checks that each system still works:
# mission load, motion smoothness, throttle, gear, gun + tracers, missile + smoke trail, wingtip vapour lines,
# radar, HUD, audio, shoot-down (death smoke/fire), respawn and frame time. Screenshots of every step go
# to crashlog/tests/<time>/ so effects can be checked by eye. Writes results.json and quits with the number
# of failed checks as the exit code.
# Inputs are injected after controls.gd (physics priority 50; the sim steps at 100), so they win.

const WPN_GUN := 0
const WPN_AIM9 := 1
const WPN_AIM120 := 6
const WPN_AIM9X := 10

var main: Node = null
var sim: YSFlightSimulation = null
var out_dir: String = ""

var _results: Array[Dictionary] = []
var _inject := {} # "elevator", "gun", "fire_once" -> values used in _physics_process
var _frame_ms: PackedFloat32Array = PackedFloat32Array()
var _last_usec: int = 0

func setup(p_main: Node) -> void:
	main = p_main
	sim = main.ysflight_sim
	process_priority = 10 # after main.gd: may move the camera it placed
	process_physics_priority = 50
	var dt := Time.get_datetime_dict_from_system()
	out_dir = ProjectSettings.globalize_path("res://").path_join("../crashlog/tests/%04d%02d%02d_%02d%02d%02d" % [
		dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]).simplify_path()
	DirAccess.make_dir_recursive_absolute(out_dir)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run.call_deferred()

func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		_frame_ms.append((now - _last_usec) / 1000.0)
	_last_usec = now
	if _motion_frames > 0:
		_sample_motion(delta)

# Displayed player movement per frame vs speed * frame time (0 = perfectly smooth). Sampled here, after the
# sim's _process, like every real consumer (camera, HUD).
var _motion_frames: int = 0
var _motion_prev := Vector3.ZERO
var _motion_errors := PackedFloat32Array()

func _sample_motion(delta: float) -> void:
	var pos: Vector3 = sim.get_player_transform().origin
	var speed: float = float(sim.get_player_telemetry().get("speed_ms", 0.0))
	if _motion_prev != Vector3.ZERO and speed > 30.0 and delta > 0.0:
		_motion_errors.append(absf(pos.distance_to(_motion_prev) - speed * delta) / (speed * delta))
	_motion_prev = pos
	_motion_frames -= 1

func _physics_process(_delta: float) -> void:
	if _inject.has("elevator"):
		sim.set_player_flight_inputs(_inject["elevator"], 0.0, 0.0, 1.0, true, 0.0)
	if _inject.has("gun") or _inject.has("fire_once"):
		sim.set_player_weapon_inputs(false, _inject.get("fire_once", false), _inject.get("gun", false), false, false)
		_inject.erase("fire_once")

# ------------------------------------------------------------------------------
func _run() -> void:
	await _seconds(2.0)
	await _test_startup()
	await _test_motion()
	await _test_throttle()
	await _test_gear()
	await _test_gun()
	await _test_missile()
	await _test_vapour()
	_test_radar()
	await _test_hud()
	_test_audio()
	await _test_shoot_down_and_respawn()
	_test_frame_time()
	_finish()

func _test_startup() -> void:
	var air: Dictionary = sim.get_airplane_transforms()
	var tel: Dictionary = sim.get_player_telemetry()
	_check("mission loads 32 aircraft", air.size() >= 32, "%d aircraft" % air.size())
	_check("player aircraft alive", bool(tel.get("is_alive", false)), str(tel.get("identifier", "?")))
	await _shot("01_start")

func _test_motion() -> void:
	_motion_frames = 240
	while _motion_frames > 0:
		await get_tree().process_frame
	var mean := 0.0
	for e in _motion_errors:
		mean += e
	mean /= maxi(_motion_errors.size(), 1)
	_check("motion interpolation smooth", _motion_errors.size() > 100 and mean < 0.05,
		"mean error %.1f%% over %d frames" % [mean * 100.0, _motion_errors.size()])

func _test_throttle() -> void:
	main.controls.current_throttle = 0.2
	main.controls._afterburner_lit = false
	await _seconds(3.0)
	var thr: float = float(sim.get_player_telemetry().get("throttle", 1.0))
	_check("throttle input reaches the sim", thr < 0.4, "throttle %.2f after setting 0.2" % thr)
	main.controls.current_throttle = 1.0
	main.controls._afterburner_lit = true

func _test_gear() -> void:
	var before: float = float(sim.get_player_telemetry().get("gear", 0.0))
	sim.press_button("LANDINGGEAR")
	await _seconds(3.0)
	var after: float = float(sim.get_player_telemetry().get("gear", 0.0))
	_check("gear button (YS button function)", absf(after - before) > 0.2, "gear %.2f -> %.2f" % [before, after])
	sim.press_button("LANDINGGEAR")

func _test_gun() -> void:
	var ammo0: int = int(sim.get_player_telemetry().get("gun_ammo", 0))
	_inject["gun"] = true
	var max_tracers := 0
	for i in 60:
		await get_tree().process_frame
		max_tracers = maxi(max_tracers, sim.get_effects_stats()[2])
	await _shot("02_gun")
	_inject.erase("gun")
	var ammo1: int = int(sim.get_player_telemetry().get("gun_ammo", 0))
	_check("gun fires", ammo1 < ammo0, "ammo %d -> %d" % [ammo0, ammo1])
	_check("tracers drawn", max_tracers > 0, "max %d tracers" % max_tracers)

func _test_missile() -> void:
	var picked := -1
	for t in [WPN_AIM9, WPN_AIM9X, WPN_AIM120]:
		if sim.select_weapon(t):
			picked = t
			break
	_check("missile selectable", picked >= 0, "type %d" % picked)
	var count_key: String = {WPN_AIM9: "aim9_count", WPN_AIM9X: "aim9x_count", WPN_AIM120: "aim120_count"}.get(picked, "aim9_count")
	var before: int = int(sim.get_player_telemetry().get(count_key, 0))
	var trails0: int = sim.get_effects_stats()[1]
	_inject["fire_once"] = true
	await _seconds(0.5)
	var after: int = int(sim.get_player_telemetry().get(count_key, 0))
	var trails1: int = sim.get_effects_stats()[1]
	await _seconds(1.0)
	await _shot("03_missile_trail")
	_check("missile fired", after < before, "%s %d -> %d" % [count_key, before, after])
	_check("missile smoke trail started", trails1 > trails0, "%d -> %d trails" % [trails0, trails1])
	sim.select_weapon(WPN_GUN)

func _test_vapour() -> void:
	# Hard pull at speed: YS reports vapour, the renderer draws two wingtip lines
	var seen := false
	_inject["elevator"] = 1.0
	for i in 120:
		await get_tree().process_frame
		if _player_fx_value(9) > 0.5:
			seen = true
		if i == 90:
			await _shot("04_wingtip_vapour")
	_inject.erase("elevator")
	_check("wingtip vapour at high G", seen, "vapour flag seen" if seen else "no vapour in 2 s of full pull")

func _test_radar() -> void:
	var r: Dictionary = sim.get_radar_contacts(20000.0)
	var n: int = r.get("contacts", PackedFloat32Array()).size() / 8
	_check("radar contacts", n > 0, "%d aircraft within 20 km" % n)

func _test_hud() -> void:
	main.camera_rig.set_mode(1)
	await _seconds(1.0)
	await _shot("05_cockpit_hud")
	_check("HUD gets the cockpit view", main.hud.cam_mode == 1 and main.hud.is_visible_in_tree(), "")
	main.camera_rig.set_mode(2)
	await _seconds(0.5)

func _test_audio() -> void:
	var n := 0
	for node in main.audio_manager.find_children("*", "", true, false):
		if node is AudioStreamPlayer or node is AudioStreamPlayer3D:
			n += 1
	_check("audio players created", n > 0, "%d players" % n)
	var sounds = main.audio_manager._sounds
	_check("sounds loaded", sounds.engine0 != null and sounds.missile != null and sounds.lock_beep != null, "")

func _test_shoot_down_and_respawn() -> void:
	var old_key := _player_key()
	sim.debug_kill_player()
	var dying := false
	for i in 30:
		await get_tree().process_frame
		if _player_fx_value(8) > 0.5:
			dying = true
	_check("shot-down aircraft falls (dying state)", dying, "")
	main.camera_rig.cam_distance = 60.0
	await _seconds(1.5)
	await _shot("06_death_smoke_fire")
	main.camera_rig.cam_distance = 150.0
	await _seconds(2.0)
	await _shot("07_death_smoke_far")
	var trails: PackedInt32Array = sim.get_effects_stats()
	_check("death smoke + fire trails", trails[1] >= 2, "%d trails, %d segments" % [trails[1], trails[0]])
	main.camera_rig.cam_distance = 18.0
	var respawned: bool = main.get_node("RespawnManager").respawn()
	await _seconds(1.0)
	var tel: Dictionary = sim.get_player_telemetry()
	_check("respawn", respawned and bool(tel.get("is_alive", false)) and _player_key() != old_key,
		"new aircraft %s" % str(tel.get("identifier", "?")))
	await _shot("08_after_respawn")

func _test_frame_time() -> void:
	var sorted := _frame_ms.duplicate()
	sorted.sort()
	var avg := 0.0
	for v in _frame_ms:
		avg += v
	avg /= maxi(_frame_ms.size(), 1)
	var p99: float = sorted[int(sorted.size() * 0.99)] if sorted.size() > 0 else 0.0
	_check("frame time", avg < 16.7, "avg %.2f ms (%.0f FPS), p99 %.2f ms over %d frames (test run, uncapped)" % [
		avg, 1000.0 / maxf(avg, 0.001), p99, _frame_ms.size()])

# ------------------------------------------------------------------------------
func _check(name: String, ok: bool, detail: String) -> void:
	_results.append({"name": name, "ok": ok, "detail": detail})
	print("[TEST] %s %s %s" % ["PASS" if ok else "FAIL", name, ("(" + detail + ")") if detail != "" else ""])

func _seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_jpg(out_dir.path_join(name + ".jpg"), 0.85)

func _player_key() -> int:
	var air: Dictionary = sim.get_airplane_transforms()
	for k in air:
		if air[k].get("is_player", false):
			return int(k)
	return -1

# Value at `offset` in the player's row of get_aircraft_fx_state() (8 = dying, 9 = vapour); -1 if absent.
func _player_fx_value(offset: int) -> float:
	var key := _player_key()
	var rows: PackedFloat32Array = sim.get_aircraft_fx_state()["aircraft"]
	for i in range(0, rows.size(), 18):
		if int(rows[i]) == key:
			return rows[i + offset]
	return -1.0

func _finish() -> void:
	var failed := 0
	for r in _results:
		if not r["ok"]:
			failed += 1
	var f := FileAccess.open(out_dir.path_join("results.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"failed": failed, "total": _results.size(), "results": _results, "dir": out_dir}, "\t"))
		f.close()
	sim.log_to_crashlog("Tests finished: %d/%d passed (%s)" % [_results.size() - failed, _results.size(), out_dir])
	print("[TEST] DONE %d/%d passed -> %s" % [_results.size() - failed, _results.size(), out_dir])
	get_tree().quit(failed)
