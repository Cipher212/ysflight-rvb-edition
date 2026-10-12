extends SceneTree

const ControlsScript := preload("res://controls.gd")
const SettingsSchema := preload("res://controls/settings_schema.gd")
const CameraRigScript := preload("res://camera/camera_rig.gd")

func _init() -> void:
	print("--- BEGIN CAMERA OVERHAUL UNIT TESTS ---")
	test_camera_modes()
	test_f2_overhaul_cycling()
	test_f1_double_tap_look_down()
	test_online_lock()
	test_f3_session_view()
	test_padlock()
	test_mouse_drag_view()
	test_bombsight_ballistics()
	print("--- ALL CAMERA OVERHAUL UNIT TESTS PASSED ---")
	quit(0)

func test_camera_modes() -> void:
	print("Testing CamMode constants...")
	assert(CameraRigScript.CamMode.COCKPIT == 1, "COCKPIT must be 1")
	assert(CameraRigScript.CamMode.HORIZON_CHASE == 2, "HORIZON_CHASE must be 2")
	assert(CameraRigScript.CamMode.LOCKED_TAIL == 3, "LOCKED_TAIL must be 3")
	assert(CameraRigScript.CamMode.LOOK_DOWN == 9, "LOOK_DOWN must be 9")
	assert(CameraRigScript.F2SubMode.RIGID_AXIS == 0, "RIGID_AXIS must be 0")
	assert(CameraRigScript.F2SubMode.LOOSE_FOLLOW == 1, "LOOSE_FOLLOW must be 1")
	assert(CameraRigScript.F2SubMode.FIXED_ANGLE == 2, "FIXED_ANGLE must be 2")
	print("  PASS: Camera mode enums verified.")

func test_f2_overhaul_cycling() -> void:
	print("Testing F2 overhaul cycling...")
	var sim = YSFlightSimulation.new()
	var rig = CameraRigScript.new()
	root.add_child(sim)
	root.add_child(rig)
	rig.setup(sim, null, false, false)

	# Start in cockpit
	rig.set_mode(CameraRigScript.CamMode.COCKPIT)
	assert(rig.mode == CameraRigScript.CamMode.COCKPIT)

	# First F2 press -> enters F2 in RIGID_AXIS mode
	rig.press_exterior_view()
	assert(rig.mode == CameraRigScript.CamMode.HORIZON_CHASE, "Must enter HORIZON_CHASE")
	assert(rig.f2_sub_mode == CameraRigScript.F2SubMode.RIGID_AXIS, "Default F2 must be RIGID_AXIS")

	# Second F2 press -> cycles to LOOSE_FOLLOW
	rig.press_exterior_view()
	assert(rig.mode == CameraRigScript.CamMode.HORIZON_CHASE)
	assert(rig.f2_sub_mode == CameraRigScript.F2SubMode.LOOSE_FOLLOW, "Second press must cycle to LOOSE_FOLLOW")

	# Third F2 press -> cycles to FIXED_ANGLE
	rig.press_exterior_view()
	assert(rig.mode == CameraRigScript.CamMode.HORIZON_CHASE)
	assert(rig.f2_sub_mode == CameraRigScript.F2SubMode.FIXED_ANGLE, "Third press must cycle to FIXED_ANGLE")

	# Fourth F2 press -> cycles back to RIGID_AXIS
	rig.press_exterior_view()
	assert(rig.mode == CameraRigScript.CamMode.HORIZON_CHASE)
	assert(rig.f2_sub_mode == CameraRigScript.F2SubMode.RIGID_AXIS, "Fourth press must cycle back to RIGID_AXIS")

	rig.queue_free()
	sim.queue_free()
	print("  PASS: F2 3-mode cycle verified.")

func test_f1_double_tap_look_down() -> void:
	print("Testing F1 Cockpit <-> Look-down view cycling...")
	var sim = YSFlightSimulation.new()
	var rig = CameraRigScript.new()
	root.add_child(sim)
	root.add_child(rig)
	rig.setup(sim, null, false, false)

	# Enter exterior first
	rig.set_mode(CameraRigScript.CamMode.HORIZON_CHASE)
	assert(rig.mode == CameraRigScript.CamMode.HORIZON_CHASE)

	# 1. Pressing F1 externally -> enters COCKPIT
	rig.press_cockpit_view()
	assert(rig.mode == CameraRigScript.CamMode.COCKPIT, "First F1 press externally must enter COCKPIT")

	# 2. Pressing F1 again -> enters LOOK_DOWN (bombsight)
	rig.press_cockpit_view()
	assert(rig.mode == CameraRigScript.CamMode.LOOK_DOWN, "Second F1 press must enter LOOK_DOWN")

	# 3. Pressing F1 a third time -> returns to COCKPIT
	rig.press_cockpit_view()
	assert(rig.mode == CameraRigScript.CamMode.COCKPIT, "Third F1 press must return to COCKPIT")

	# 4. Pressing F1 a fourth time -> enters LOOK_DOWN again
	rig.press_cockpit_view()
	assert(rig.mode == CameraRigScript.CamMode.LOOK_DOWN, "Fourth F1 press must toggle to LOOK_DOWN")

	# 5. Switch to F2 exterior, then press F1 -> must always enter COCKPIT first
	rig.press_exterior_view()
	assert(rig.mode == CameraRigScript.CamMode.HORIZON_CHASE)
	rig.press_cockpit_view()
	assert(rig.mode == CameraRigScript.CamMode.COCKPIT, "F1 from exterior must enter COCKPIT view first")

	rig.queue_free()
	sim.queue_free()
	print("  PASS: F1 Cockpit <-> Look-down cycling verified.")

func test_online_lock() -> void:
	print("Testing online mode camera lock...")
	var sim = YSFlightSimulation.new()
	var rig = CameraRigScript.new()
	root.add_child(sim)
	root.add_child(rig)
	rig.setup(sim, null, false, false)
	rig.is_online = true

	# Cockpit, Look-down, and F2 should be allowed
	rig.set_mode(CameraRigScript.CamMode.COCKPIT)
	assert(rig.mode == CameraRigScript.CamMode.COCKPIT)

	rig.set_mode(CameraRigScript.CamMode.HORIZON_CHASE)
	assert(rig.mode == CameraRigScript.CamMode.HORIZON_CHASE)

	rig.set_mode(CameraRigScript.CamMode.LOOK_DOWN)
	assert(rig.mode == CameraRigScript.CamMode.LOOK_DOWN)

	# Spectator, Tower, Action mounts, Fly-by MUST be blocked online
	rig.set_mode(CameraRigScript.CamMode.FLY_BY)
	assert(rig.mode == CameraRigScript.CamMode.LOOK_DOWN, "FLY_BY must be blocked online")

	rig.set_mode(CameraRigScript.CamMode.TOWER)
	assert(rig.mode == CameraRigScript.CamMode.LOOK_DOWN, "TOWER must be blocked online")

	rig.set_mode(CameraRigScript.CamMode.SPECTATOR_AI)
	assert(rig.mode == CameraRigScript.CamMode.LOOK_DOWN, "SPECTATOR_AI must be blocked online")

	rig.queue_free()
	sim.queue_free()
	print("  PASS: Online camera lock verified.")

func test_f3_session_view() -> void:
	print("Testing F3 session flight view...")
	var sim = YSFlightSimulation.new()
	var controls = ControlsScript.new()
	var rig = CameraRigScript.new()
	root.add_child(sim)
	root.add_child(controls)
	root.add_child(rig)
	controls.setup(null, sim)
	rig.setup(sim, controls, false, false)

	# 1. Flying alone -> F3 does nothing
	rig._last_airplanes = {}
	rig._press_f3_session_view()
	assert(rig.mode != CameraRigScript.CamMode.LOCKED_TAIL, "F3 must not engage when alone")

	# 2. Other airplanes exist, but all_camera_views is false -> F3 does nothing
	controls.set_value("all_camera_views", false)
	rig._last_airplanes = {
		10: {"is_player": false, "is_alive": true, "iff": 1, "pos": Vector3(100, 100, 100), "transform": Transform3D()}
	}
	rig._press_f3_session_view()
	assert(rig.mode != CameraRigScript.CamMode.LOCKED_TAIL, "F3 must not engage when all_camera_views is false")

	# 3. all_camera_views is true -> F3 engages
	controls.set_value("all_camera_views", true)
	rig._press_f3_session_view()
	assert(rig.mode == CameraRigScript.CamMode.LOCKED_TAIL, "F3 must engage when all_camera_views is true and other aircraft exist")

	rig.queue_free()
	controls.queue_free()
	sim.queue_free()
	print("  PASS: F3 session view conditions verified.")

func test_padlock() -> void:
	print("Testing padlock nearest enemy and cycling...")
	var sim = YSFlightSimulation.new()
	var rig = CameraRigScript.new()
	root.add_child(sim)
	root.add_child(rig)
	rig.setup(sim, null, false, false)

	rig._last_player_pos = Vector3.ZERO
	rig._last_player_iff = 0
	rig._last_airplanes = {
		1: {"is_player": true, "is_alive": true, "iff": 0, "pos": Vector3.ZERO},
		2: {"is_player": false, "is_alive": true, "iff": 1, "pos": Vector3(0, 0, 5000), "identifier": "MIG-29"},   # 5 km
		3: {"is_player": false, "is_alive": true, "iff": 1, "pos": Vector3(0, 0, 2000), "identifier": "SU-27"},    # 2 km (closest!)
		4: {"is_player": false, "is_alive": true, "iff": 0, "pos": Vector3(0, 0, 1000), "identifier": "ALLY_F16"}  # Ally (ignored)
	}

	rig.set_mode(CameraRigScript.CamMode.COCKPIT)
	assert(not rig._padlock_active)

	# First press -> locks closest enemy (key 3, SU-27 at 2km)
	rig.toggle_or_cycle_padlock()
	assert(rig._padlock_active, "Padlock must be active")
	assert(rig._padlock_target_key == 3, "Must padlock closest bandit (key 3)")

	# Second press -> cycles to next enemy (key 2, MIG-29 at 5km)
	rig.toggle_or_cycle_padlock()
	assert(rig._padlock_active)
	assert(rig._padlock_target_key == 2, "Must cycle to next bandit (key 2)")

	# Third press -> wraps back to key 3
	rig.toggle_or_cycle_padlock()
	assert(rig._padlock_target_key == 3, "Must wrap back to first bandit (key 3)")

	# Recenter -> cancels padlock
	rig.recenter_views()
	assert(not rig._padlock_active, "Recenter must cancel padlock")

	rig.queue_free()
	sim.queue_free()
	print("  PASS: Padlock nearest enemy and cycling verified.")

func test_mouse_drag_view() -> void:
	print("Testing mouse click-drag view setting and input...")
	var sim = YSFlightSimulation.new()
	var controls = ControlsScript.new()
	root.add_child(sim)
	root.add_child(controls)
	controls.setup(null, sim)

	controls.reset_to_defaults()
	assert(controls.get_value("mouse_click_drag_view") == false, "Default must be false")

	controls.set_value("mouse_click_drag_view", true)
	assert(controls.get_value("mouse_click_drag_view") == true)

	controls.queue_free()
	sim.queue_free()
	print("  PASS: Mouse click-drag view setting verified.")

func test_bombsight_ballistics() -> void:
	print("Testing bombsight ballistics calculation...")
	var sim = YSFlightSimulation.new()
	var rig = CameraRigScript.new()
	root.add_child(sim)
	root.add_child(rig)
	rig.setup(sim, null, false, false)

	# Level flight at 200 m/s forward (-Z in Godot), 1000m AGL
	var player_pos := Vector3(0, 1000, 0)
	var tel := {
		"velocity": Vector3(0, 0, -200),
		"agl_m": 1000.0
	}
	# Time to fall 1000m: t = sqrt(2 * 1000 / 9.80665) = ~14.28 sec
	# Expected forward displacement = -200 * 14.28 = -2856m
	var impact := rig._compute_bomb_impact(player_pos, tel)
	assert(impact.y == 0.0, "Impact Y must be ground level (0m)")
	assert(impact.z < -2800.0 and impact.z > -2900.0, "Impact Z must match ballistic fall distance ~-2856m, got %f" % impact.z)

	rig.queue_free()
	sim.queue_free()
	print("  PASS: Bombsight ballistics formula verified.")
