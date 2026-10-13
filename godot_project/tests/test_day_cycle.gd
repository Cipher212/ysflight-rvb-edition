extends SceneTree

# Focused automated verification for DayCycle:
# 1. Palette bounds & artistic criteria (Dawn, Daylight, Sunset, Night)
# 2. STATIC mode remaining fixed at daylight
# 3. DYNAMIC mode progressing with event elapsed time
# 4. Duplicate-time calls doing no work (deterministic caching)
# 5. Restart / reset behavior (new event resets to dawn, respawn/menu does not)
# 6. Manual time-of-day presets & live switching
# 7. Simulation sun-state binding & sun tracking

const DayCycleScript = preload("res://world/day_cycle.gd")
const SkyEnvironmentScript = preload("res://world/sky_environment.gd")
const SunGlareScript = preload("res://fx/sun_glare.gd")

func _init() -> void:
	var failed := 0
	print("[DayCycleTest] Starting verification...")

	# 1. Palette integrity & keyframe checks
	var p_dawn: Dictionary = DayCycleScript.evaluate_palette(DayCycleScript.START_HOUR)
	var p_day: Dictionary = DayCycleScript.evaluate_palette(DayCycleScript.STATIC_HOUR)
	var p_sunset: Dictionary = DayCycleScript.evaluate_palette(18.5)
	var p_night: Dictionary = DayCycleScript.evaluate_palette(DayCycleScript.END_HOUR)

	if p_dawn["sun_energy"] <= 0.0 or p_dawn["daylight_strength"] <= 0.0:
		print("FAIL: Dawn should have positive sun energy and daylight strength")
		failed += 1
	else:
		print("PASS: Dawn palette valid (sun_energy: %.2f, daylight: %.2f)" % [p_dawn["sun_energy"], p_dawn["daylight_strength"]])

	if p_day["sun_energy"] < 0.8 or p_day["daylight_strength"] < 1.0:
		print("FAIL: Daylight should have full sun energy and strength 1.0")
		failed += 1
	else:
		print("PASS: Daylight palette valid (sun_energy: %.2f, daylight: %.2f)" % [p_day["sun_energy"], p_day["daylight_strength"]])

	if p_sunset["daylight_strength"] >= 1.0 or p_sunset["daylight_strength"] <= 0.1:
		print("FAIL: Sunset daylight strength should be intermediate")
		failed += 1
	else:
		print("PASS: Sunset palette valid (sun_energy: %.2f, daylight: %.2f)" % [p_sunset["sun_energy"], p_sunset["daylight_strength"]])

	# Night checks: minimal sun energy, no daylight strength, but readable ambient fill (avoid pure-black)
	var night_sky: Color = p_night["sky_top"]
	var night_amb: Color = p_night["ambient_color"]
	var night_amb_energy: float = float(p_night["ambient_energy"])
	if p_night["sun_energy"] > 0.15 or p_night["daylight_strength"] != 0.0:
		print("FAIL: Night should have near-zero sun energy and 0 daylight strength")
		failed += 1
	elif night_amb_energy < 0.50:
		print("FAIL: Night ambient fill is too dark (pure-black gameplay risk)")
		failed += 1
	elif night_sky.r > 0.15 or night_sky.g > 0.15 or night_sky.b > 0.25:
		print("FAIL: Night sky is not dark navy")
		failed += 1
	else:
		print("PASS: Night palette valid (ambient_energy: %.2f, navy sky: %s)" % [night_amb_energy, night_sky])

	# 2. Node setup & STATIC mode verification
	var root := Node3D.new()
	get_root().add_child(root)
	var camera := Camera3D.new()
	root.add_child(camera)
	var sun := DirectionalLight3D.new()
	root.add_child(sun)
	var sky_env := WorldEnvironment.new()
	root.add_child(sky_env)
	var sun_glare := MeshInstance3D.new()
	sun_glare.set_script(SunGlareScript)
	sun_glare.setup(camera, sun)

	var dc: Node = DayCycleScript.new()
	root.add_child(dc)
	dc.setup(sky_env, sun, sun_glare, "STATIC")

	if absf(dc.get_time_of_day() - DayCycleScript.STATIC_HOUR) > 0.01:
		print("FAIL: STATIC mode did not start at STATIC_HOUR")
		failed += 1
	else:
		print("PASS: STATIC mode initialized at hour %.1f" % dc.get_time_of_day())

	# In STATIC mode, event state updates must NOT alter time of day
	dc._last_update_msec = -999999
	dc._on_event_state({"elapsed": 1800.0})
	if absf(dc.get_time_of_day() - DayCycleScript.STATIC_HOUR) > 0.01:
		print("FAIL: STATIC mode changed time of day on event state update")
		failed += 1
	else:
		print("PASS: STATIC mode remained fixed despite event progress")

	# 3. Duplicate-time caching
	var prev_hour: float = dc.get_time_of_day()
	dc.set_time_of_day(prev_hour)
	if dc.get_time_of_day() != prev_hour:
		print("FAIL: set_time_of_day changed value on duplicate call")
		failed += 1
	else:
		print("PASS: Duplicate set_time_of_day call handled cleanly")

	# 4. DYNAMIC mode verification
	dc.setup(sky_env, sun, sun_glare, "DYNAMIC")
	if absf(dc.get_time_of_day() - DayCycleScript.START_HOUR) > 0.01:
		print("FAIL: DYNAMIC mode did not start at START_HOUR (06:00)")
		failed += 1
	else:
		print("PASS: DYNAMIC mode initialized at dawn (06:00)")

	# Shorter match test (15 minutes = 900 seconds): progresses to ~10:00 (daylight, no sunset)
	dc._last_update_msec = -999999
	dc._on_event_state({"elapsed": 900.0})
	var hour_15m: float = float(dc.get_time_of_day())
	if hour_15m < 9.5 or hour_15m > 10.5:
		print("FAIL: 15-minute match reached unexpected hour: %.2f (expected ~10.0)" % hour_15m)
		failed += 1
	else:
		print("PASS: 15-minute match progress rate correct (hour: %.2f, no sunset)" % hour_15m)

	# Full match progression: 45 min (sunset) and 60 min (night)
	dc._last_update_msec = -999999
	dc._on_event_state({"elapsed": 2700.0}) # 45 min
	var hour_sunset: float = float(dc.get_time_of_day())
	if hour_sunset < 17.5 or hour_sunset > 18.5:
		print("FAIL: 45 min did not reach sunset range (got %.2f)" % hour_sunset)
		failed += 1
	else:
		print("PASS: 45 min reached sunset (hour: %.2f)" % hour_sunset)

	dc._last_update_msec = -999999
	dc._on_event_state({"elapsed": 3600.0}) # 60 min
	var hour_night: float = float(dc.get_time_of_day())
	if absf(hour_night - DayCycleScript.END_HOUR) > 0.01:
		print("FAIL: 60 min did not reach END_HOUR (got %.2f)" % hour_night)
		failed += 1
	else:
		print("PASS: 60 min reached full night (hour: %.2f)" % hour_night)

	# Clamp check beyond 60 min
	dc._last_update_msec = -999999
	dc._on_event_state({"elapsed": 7200.0}) # 120 min
	if dc.get_time_of_day() != DayCycleScript.END_HOUR:
		print("FAIL: >60 min did not clamp at END_HOUR")
		failed += 1
	else:
		print("PASS: Match time beyond 60 min clamps safely at END_HOUR")

	# Safe handling of empty/invalid state
	dc._last_update_msec = -999999
	dc._on_event_state({})
	if dc.get_time_of_day() != DayCycleScript.END_HOUR:
		print("FAIL: Empty state corrupted time of day")
		failed += 1
	else:
		print("PASS: Empty state handled safely")

	# 5. Restart / Reset behavior
	# A new event has elapsed = 0.0 -> must reset to dawn (06:00)
	dc._last_update_msec = -999999
	dc._on_event_state({"elapsed": 0.0})
	if absf(dc.get_time_of_day() - DayCycleScript.START_HOUR) > 0.01:
		print("FAIL: New event (elapsed: 0.0) did not reset cycle to dawn")
		failed += 1
	else:
		print("PASS: New event resets cycle to dawn (06:00)")

	# 6. Manual time-of-day presets & live switching
	var presets := {
		"DAWN": 6.0,
		"MORNING": 8.5,
		"DAYLIGHT": 12.0,
		"AFTERNOON": 16.0,
		"SUNSET": 18.5,
		"DUSK": 19.75,
		"NIGHT": 22.0,
		"Sunset (18:30)": 18.5,
		"Night (22:00)": 22.0,
	}
	for mode_label in presets.keys():
		var expected_h := float(presets[mode_label])
		dc.set_time_mode(mode_label)
		if absf(dc.get_time_of_day() - expected_h) > 0.01:
			print("FAIL: Preset '%s' applied hour %.2f (expected %.2f)" % [mode_label, dc.get_time_of_day(), expected_h])
			failed += 1
		else:
			print("PASS: Preset '%s' applied hour %.2f" % [mode_label, dc.get_time_of_day()])

	# 7. Simulation sun-state binding & sun tracking
	var stub := SimStub.new()
	root.add_child(stub)
	dc.bind_simulation(stub)
	if stub.call_count == 0:
		print("FAIL: bind_simulation did not immediately apply sun state to sim")
		failed += 1
	else:
		print("PASS: bind_simulation immediately forwarded sun state")

	dc.set_time_mode("DAWN")
	var dawn_sun: Vector3 = stub.last_to_sun
	var dawn_light: float = stub.last_daylight
	var dawn_unit_ok: bool = absf(dawn_sun.length() - 1.0) < 0.01
	var dawn_light_ok: bool = absf(dawn_light - 0.70) < 0.05
	var dawn_y_ok: bool = dawn_sun.y > 0.0
	if not (dawn_unit_ok and dawn_light_ok and dawn_y_ok):
		print("FAIL: DAWN sun state invalid (daylight: %.2f expected ~0.70, to_sun: %s, len: %.2f, y > 0: %s)" % [
			dawn_light, dawn_sun, dawn_sun.length(), str(dawn_y_ok)
		])
		failed += 1
	else:
		print("PASS: DAWN forwarded daylight ~0.70 (got %.2f) and unit to_sun with y > 0 (%s)" % [dawn_light, dawn_sun])

	dc.set_time_mode("SUNSET")
	var sunset_sun: Vector3 = stub.last_to_sun
	var swung: bool = (dawn_sun.x * sunset_sun.x < 0.0) or (dawn_sun.z * sunset_sun.z < 0.0)
	if not swung:
		print("FAIL: SUNSET to_sun horizontal component did not swing from DAWN (dawn: %s, sunset: %s)" % [dawn_sun, sunset_sun])
		failed += 1
	else:
		print("PASS: SUNSET to_sun has opposite-sign horizontal component from DAWN (dawn: %s, sunset: %s)" % [dawn_sun, sunset_sun])

	dc.set_time_mode("NIGHT")
	var night_light: float = stub.last_daylight
	if absf(night_light - 0.0) > 0.01:
		print("FAIL: NIGHT did not forward daylight 0.0 (got %.2f)" % night_light)
		failed += 1
	else:
		print("PASS: NIGHT forwarded daylight 0.0")

	# Clean up test nodes
	root.queue_free()

	print("\n[DayCycleTest] Results: %d failures." % failed)
	quit(failed)

class SimStub extends Node:
	var call_count: int = 0
	var last_to_sun: Vector3 = Vector3.ZERO
	var last_daylight: float = -1.0

	func set_sun_state(to_sun: Vector3, daylight: float) -> void:
		call_count += 1
		last_to_sun = to_sun
		last_daylight = daylight

