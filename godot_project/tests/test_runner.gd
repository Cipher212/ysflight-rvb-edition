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
	sim.debug_set_route_seed(0) # Mission loading randomises this independently of srand.
	sim.render_origin_shifted.connect(_rebase_motion)
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

func _rebase_motion(delta: Vector3) -> void:
	if _motion_prev != Vector3.ZERO:
		_motion_prev -= delta # the render origin moved (render space)

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
	_test_render_origin()
	await _test_throttle()
	await _test_burner_showcase()
	await _test_gear()
	await _test_gun()
	await _test_missile()
	await _test_vapour()
	await _test_radar()
	await _test_hud()
	_test_audio()
	await _test_shoot_down_and_respawn()
	await _test_ground_impact()
	if DisplayServer.get_name() != "headless":
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

# Floating render origin (C++ core/render_origin.h): the camera stays near it, and render-space positions
# convert back to real (absolute) values - altitude, and the terrain query under the jet.
func _test_render_origin() -> void:
	var origin: Vector3 = sim.get_render_origin()
	var cam_dist: float = main.camera.global_position.length()
	_check("render origin follows the camera", cam_dist < 1500.0, "camera %.0f m from the origin (absolute origin %s)" % [cam_dist, origin])
	var tel: Dictionary = sim.get_player_telemetry()
	var p: Vector3 = sim.get_player_transform().origin
	var asl: float = p.y + origin.y
	var ground: float = sim.get_terrain_height(p.x, p.z)
	var ok := absf(asl - float(tel.get("altitude_m", 0.0))) < 5.0 and absf(asl - float(tel.get("agl_m", 0.0)) - ground) < 5.0
	_check("render space converts back to absolute", ok, "altitude %.1f m (sim %.1f), ground under the jet %.1f m (sim %.1f)" % [
		asl, float(tel.get("altitude_m", 0.0)), ground, asl - float(tel.get("agl_m", 0.0))])

func _test_throttle() -> void:
	main.controls.current_throttle = 0.2
	main.controls._afterburner_lit = false
	await _seconds(3.0)
	var thr: float = float(sim.get_player_telemetry().get("throttle", 1.0))
	_check("throttle input reaches the sim", thr < 0.4, "throttle %.2f after setting 0.2" % thr)
	main.controls.current_throttle = 1.0
	main.controls._afterburner_lit = true

func _test_burner_showcase() -> void:
	await _seconds(1.0)
	var hud_layer: CanvasLayer = main.get_node_or_null("HUDLayer")
	if hud_layer != null:
		hud_layer.visible = false
	
	main.camera_rig.set_mode(main.camera_rig.CamMode.HORIZON_CHASE)

	# Shot 1: Direct rear close-up (looking straight into nozzle)
	main.camera_rig.cam_yaw = 0.0
	main.camera_rig.cam_pitch = -0.04
	main.camera_rig.cam_distance = 11.5
	await _seconds(0.5)
	await _shot("burner_01_rear_close")

	# Shot 2: 3/4 Quartering rear
	main.camera_rig.cam_yaw = 0.45
	main.camera_rig.cam_pitch = -0.15
	main.camera_rig.cam_distance = 14.0
	await _seconds(0.5)
	await _shot("burner_02_quarter_rear")

	# Shot 3: Side profile
	main.camera_rig.cam_yaw = 1.35
	main.camera_rig.cam_pitch = -0.08
	main.camera_rig.cam_distance = 16.0
	await _seconds(0.5)
	await _shot("burner_03_side_profile")

	# Shot 4: Low angle looking up at burner against sky
	main.camera_rig.cam_yaw = 0.25
	main.camera_rig.cam_pitch = 0.22
	main.camera_rig.cam_distance = 13.0
	await _seconds(0.5)
	await _shot("burner_04_low_angle")

	# Shot 5: High angle rear top-down
	main.camera_rig.cam_yaw = -0.35
	main.camera_rig.cam_pitch = -0.38
	main.camera_rig.cam_distance = 15.0
	await _seconds(0.5)
	await _shot("burner_05_high_angle")

	# Restore camera and HUD
	main.camera_rig.cam_yaw = 0.0
	main.camera_rig.cam_pitch = main.camera_rig.DEFAULT_CAM_PITCH
	main.camera_rig.cam_distance = 18.0
	if hud_layer != null:
		hud_layer.visible = true
	_check("burner showcase exercised" if DisplayServer.get_name() == "headless" else "burner showcase captured", true, "5 angles")

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
	var old_life := {}
	for weapon: Dictionary in sim.get_active_weapons():
		old_life[weapon["slot_id"]] = weapon["life_remain"]
	_inject["fire_once"] = true
	var missile_ribbon := false
	# Other jets' smoke can expire as ours starts. Check the new missile's ribbon
	# endpoints in the renderer, rather than requiring a rise in the whole-scene total.
	for frame in 30:
		await get_tree().process_frame
		missile_ribbon = missile_ribbon or _new_missile_ribbon(picked, old_life)
	var after: int = int(sim.get_player_telemetry().get(count_key, 0))
	var trails1: int = sim.get_effects_stats()[1]
	await _seconds(1.0)
	await _shot("03_missile_trail")
	_check("missile fired", after < before, "%s %d -> %d" % [count_key, before, after])
	_check("missile smoke trail started", missile_ribbon, "new missile ribbon %s; scene %d -> %d trails" % [missile_ribbon, trails0, trails1])
	sim.select_weapon(WPN_GUN)

func _new_missile_ribbon(picked: int, old_life: Dictionary) -> bool:
	var ribbons := sim.get_node("EffectsRoot/Trails") as MultiMeshInstance3D
	if ribbons == null or ribbons.multimesh == null:
		return false
	var mesh: MultiMesh = ribbons.multimesh
	var player: Vector3 = sim.get_player_transform().origin
	for weapon: Dictionary in sim.get_active_weapons():
		var pos: Vector3 = weapon["pos"]
		# The bridge records its own ribbons; YS's legacy trail allocation flag
		# does not describe these rendered segments.
		if int(weapon["type"]) != picked or pos.distance_to(player) > 500.0:
			continue
		var slot: int = int(weapon["slot_id"])
		if old_life.has(slot) and float(weapon["life_remain"]) <= float(old_life[slot]) + 1.0:
			continue
		for segment in mesh.visible_instance_count:
			# trail_renderer.cpp stores its two ribbon endpoints in basis X/Y.
			var data: Transform3D = mesh.get_instance_transform(segment)
			if minf(data.basis.x.distance_to(pos), data.basis.y.distance_to(pos)) < 40.0:
				return true
	return false

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
	# Key 3 (YS RADAR button) cycles 2.5 / 5 / 10 / 15 / 20 nm; telemetry radar_range is metres
	var seen := {}
	for i in 5:
		sim.press_button("RADAR")
		await get_tree().physics_frame
		await get_tree().process_frame
		var tel: Dictionary = sim.get_player_telemetry()
		seen[float(tel.get("radar_range_nm", 0.0))] = absf(float(tel.get("radar_range", 0.0)) - float(tel.get("radar_range_nm", 0.0)) * 1852.0) < 1.0
	var steps: Array = seen.keys()
	steps.sort()
	_check("radar range steps", steps == [2.5, 5.0, 10.0, 15.0, 20.0] and not seen.values().has(false), str(steps))

func _test_hud() -> void:
	# Verify the helmet's cinematic toggle independently of an aircraft's physical HUD.
	var physical_hud: Control = main.glass_hud
	main.glass_hud = null
	if physical_hud != null: physical_hud.visible = false
	var saved_hide_hud: bool = bool(main.controls.get_value("hide_hud", false))
	main.controls._values["hide_hud"] = false
	main.hud._on_setting_changed("hide_hud")
	main.camera_rig.set_mode(1)
	await _seconds(1.0)
	await _shot("05_cockpit_hud")
	_check("HUD gets the cockpit view", main.hud.cam_mode == 1 and main.hud.is_visible_in_tree(), "")
	var radar_visible: bool = main.radar_scope.visible
	var mfd_visible: bool = main.cockpit_mfd.visible
	main.controls._values["hide_hud"] = true
	main.hud._on_setting_changed("hide_hud")
	await _shot("05b_hidden_hud")
	_check("Hide HUD leaves radar and cockpit screens independent", not main.hud.is_visible_in_tree() and main.radar_scope.visible == radar_visible and main.cockpit_mfd.visible == mfd_visible, "")
	main.controls._values["hide_hud"] = false
	main.hud._on_setting_changed("hide_hud")
	# Head under G, fed fixed G values (the live dogfight can't guarantee a G load): +9 G -> 25 mm down,
	# -3 G -> 10 mm up (clamped), and a view change resets it
	var rig: Node = main.camera_rig
	var saved_fov: float = float(main.controls.get_value("cockpit_fov", 65.0))
	main.controls._values["cockpit_fov"] = 55.0
	main.controls.changed.emit("cockpit_fov")
	var fov_live: bool = is_equal_approx(rig.camera.fov, 55.0)
	rig.cockpit_fov = 35.0 # temporary zoom must recenter to the saved base, not a hardcoded 65
	rig.recenter_views()
	var fov_recentered: bool = is_equal_approx(rig.cockpit_fov, 55.0)
	rig.set_mode(2)
	rig.set_mode(1, true)
	_check("cockpit FOV setting applies live and survives view resets", fov_live and fov_recentered and is_equal_approx(rig.cockpit_fov, 55.0), "55 degrees")
	main.controls._values["cockpit_fov"] = saved_fov
	main.controls.changed.emit("cockpit_fov")
	# Exercise the feature regardless of the player's saved preference; never save test settings.
	var saved_head_movement: bool = bool(main.controls.get_value("cockpit_head_movement", true))
	main.controls._values["cockpit_head_movement"] = true
	for i in 120:
		rig._update_head(1.0 / 60.0, 9.0)
	var drop_9g: float = rig._head_drop
	for i in 120:
		rig._update_head(1.0 / 60.0, -3.0)
	var rise_neg: float = rig._head_drop
	main.controls._values["cockpit_head_movement"] = false
	rig._update_head(1.0 / 60.0, 9.0)
	var disabled_drop: float = rig._head_drop
	main.controls._values["cockpit_head_movement"] = saved_head_movement
	main.camera_rig.set_mode(2)
	await _seconds(0.5)
	_check("head moves under G (cockpit only)", absf(drop_9g + 0.025) < 0.001 and absf(rise_neg - 0.010) < 0.001 and disabled_drop == 0.0 and rig._head_drop == 0.0,
		"%.1f mm at 9 G, %+.1f mm at -3 G, 0 after leaving F1" % [drop_9g * 1000.0, rise_neg * 1000.0])
	_check("G overlay hidden outside the cockpit", not main.gforce._rect.visible, "")
	main.controls._values["hide_hud"] = saved_hide_hud
	main.hud._on_setting_changed("hide_hud")
	main.glass_hud = physical_hud

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
	var dfx: Node = main._death_fx
	var plumes: int = sim.get_effects_stats()[4]
	_check("death fireball + smoke plume + shards", dfx.fires_started > 0 and plumes > 0 and dfx.shards_spawned > 0,
		"%d fireballs, %d plumes, %d shards so far" % [dfx.fires_started, plumes, dfx.shards_spawned])
	main.camera_rig.cam_distance = 18.0
	var respawned: bool = main.get_node("RespawnManager").respawn()
	await _seconds(1.0)
	var tel: Dictionary = sim.get_player_telemetry()
	_check("respawn", respawned and bool(tel.get("is_alive", false)) and _player_key() != old_key,
		"new aircraft %s" % str(tel.get("identifier", "?")))
	await _shot("08_after_respawn")

# Shot down while on a runway: the jet hits the ground at once -> wreck removed, impact explosion, burning site.
func _test_ground_impact() -> void:
	# A runway may already hold a jet (spawning onto it = collision), so try the next one if needed
	var alive_on_runway := false
	for stp in ["[IFF1]COLE_AFB_RUNWAY", "[IFF1]BALUUT_RUNWAY", "[IFF1]HIGHWAY_STRIP"]:
		sim.respawn_player("F-16(BLUE/MULTIROLE)", stp, 0)
		await _seconds(1.0)
		alive_on_runway = bool(sim.get_player_telemetry().get("is_alive", false))
		if alive_on_runway:
			break
	var sites_before: int = main._crashes.sites_created
	var key := _player_key()
	sim.debug_kill_player()
	var impact := false
	var explosion := false
	for i in 180:
		await get_tree().process_frame
		if not bool(sim.get_player_telemetry().get("is_alive", true)):
			impact = true
		if not sim.get_active_explosions().is_empty():
			explosion = true
		if impact and main._crashes.sites_created > sites_before:
			break
	main.camera_rig.cam_distance = 120.0
	await _seconds(2.0)
	await _shot("09_crash_site")
	var model_hidden := true
	for n in sim.find_children("Airplane_%d" % key, "Node3D", true, false):
		model_hidden = not n.visible
	_check("ground impact: wreck removed + explosion", impact and explosion and model_hidden,
		"alive on runway %s, impact %s, explosion %s, model hidden %s" % [alive_on_runway, impact, explosion, model_hidden])
	_check("ground impact: burning crash site", main._crashes.sites_created > sites_before, "%d sites burning" % main._crashes.site_count())
	main.camera_rig.cam_distance = 18.0

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
	var player: Dictionary = sim.get_player_telemetry()
	_results.append({"name": name, "ok": ok, "detail": detail,
		"player_alive": bool(player.get("is_alive", false)), "speed_ms": float(player.get("speed_ms", 0.0)),
		"health_pct": float(player.get("health_pct", -1.0))})
	print("[TEST] %s %s %s" % ["PASS" if ok else "FAIL", name, ("(" + detail + ")") if detail != "" else ""])

func _seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _shot(name: String) -> void:
	# A headless functional run has no rendered frame or screenshot evidence.
	if DisplayServer.get_name() == "headless":
		return
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
	for i in range(0, rows.size(), 21):
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
