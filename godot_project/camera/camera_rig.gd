extends Node

# The game camera: view modes, head look / orbit / zoom input, and placing the Camera3D every frame.
# Normal play uses F1 (cockpit) and F2 (exterior), as RvB is flown; F3-F8 are the replay / spectator cameras,
# available in --ai-player mode (and used by the benchmark's camera script) or in normal play with the Display
# setting "All Camera Views" (F3-F8 and [ ] only: the mouse and Tab stay the stick and afterburner).
# Positions come from the sim's interpolated transforms, the same ones the models are drawn with, in render
# space (relative to the floating render origin); rebase() moves the stored ones when the origin shifts.
# Spectator extras: F1 after Tab shows the spectated aircraft's cockpit; F11 is the free ghost camera
# (camera/ghost_cam.gd).

const GhostCamScript = preload("res://camera/ghost_cam.gd")
const SettingsSchema = preload("res://controls/settings_schema.gd")

enum CamMode {
	COCKPIT = 1,        # F1: cockpit, free look + zoom
	HORIZON_CHASE = 2,  # F2: roll-stabilised orbit chase overhaul (Rigid / Loose / Fixed)
	LOCKED_TAIL = 3,    # F3: session / flight view (was locked tail)
	FLY_BY = 4,         # F4: fly-by, repositions ahead of the jet, telephoto
	PADLOCK_THREAT = 5, # F5: frames the player jet while looking at a bandit
	SPECTATOR_AI = 6,   # F6: orbit another aircraft
	TOWER = 7,          # F7: airfield tower with automatic zoom
	ACTION_MOUNT = 8,   # F8: cameras fixed to the airframe
	LOOK_DOWN = 9,      # F1 double-tap: nose-gear look-down at bomb impact point
	GHOST = 10,         # F11 (spectator): free camera flown with the stick / mouse
}

enum F2SubMode {
	RIGID_AXIS = 0,   # Strictly follows aircraft position and rotation axes
	LOOSE_FOLLOW = 1, # Smoothly slerps rotation behind aircraft
	FIXED_ANGLE = 2,  # Translates with aircraft, world angle/axis fixed
}

const ACTION_MOUNTS := [
	{"name": "WINGTIP INWARD", "pos": Vector3(5.6, 0.35, 1.1), "look_target": Vector3(-1.5, 0.4, -2.2), "fov": 72.0},
	{"name": "TAIL FIN TOP", "pos": Vector3(0.0, 3.35, 6.2), "look_target": Vector3(0.0, 0.4, -12.0), "fov": 70.0},
	{"name": "OVER-THE-SHOULDER", "pos": Vector3(-0.85, 1.35, 0.4), "look_target": Vector3(0.0, 0.5, -15.0), "fov": 65.0},
	{"name": "BELLY / GEAR BAY", "pos": Vector3(0.0, -1.35, 4.5), "look_target": Vector3(0.0, -0.7, -15.0), "fov": 72.0},
]
const DEFAULT_CAM_PITCH := -0.18

# Pilot head under G (cockpit view only, setting "cockpit_head_movement"): the eye sinks linearly from 0 at
# 1 G to HEAD_DROP_AT_9G_M at +9 G (rises at most HEAD_RISE_MAX_M under negative G), and the head tilts
# down a little (neck flexion). Follows the G load with a HEAD_LAG_S time constant so it lags the stick.
const HEAD_DROP_AT_9G_M := 0.025
const HEAD_RISE_MAX_M := 0.010
const HEAD_TILT_AT_9G_DEG := -1.25
const HEAD_LAG_S := 0.2

var camera: Camera3D = null
var mode: int = CamMode.HORIZON_CHASE
var status_text: String = ""

var is_online: bool = false
var f2_sub_mode: int = F2SubMode.RIGID_AXIS
var _f2_loose_basis := Basis.IDENTITY
var _f2_loose_basis_valid := false
var _lookdown_target := Vector3.ZERO
var _lookdown_target_valid := false
var _last_f1_press_msec: int = 0
var _has_mouse_dragged_cockpit := false
var _has_mouse_dragged_ext := false

# Padlock state
var _padlock_active := false
var _padlock_target_key: int = -1
var _last_player_pos := Vector3.ZERO
var _last_player_iff: int = 0
var _last_airplanes: Dictionary = {}
var _f3_session_key: int = -1

var cam_yaw: float = 0.0
var cam_pitch: float = DEFAULT_CAM_PITCH
var cam_distance: float = 18.0
var head_yaw: float = 0.0
var head_pitch: float = 0.0
var cockpit_fov: float = SettingsSchema.COCKPIT_FOV_DEFAULT

var _sim: YSFlightSimulation = null
var _controls: Node = null
var _spectator_input := false # --ai-player: mouse orbit + F1-F8
var _player_input := true     # normal play: look keys / right stick / hat (off when the AI flies)
var _session_spectator_iff := -1
var _launch_spectator := false
var _launch_player := true
var _dragging := false
var _locked_basis := Basis.IDENTITY
var _locked_basis_valid := false
var _flyby_pos := Vector3.ZERO
var _flyby_valid := false
var _flyby_side: float = 1.0
# F5 / F6 targets are locked by aircraft key: deaths and respawns never switch the camera to another jet.
var _padlock_key: int = -1
var _spectator_key: int = -1
var _pending_step := {} # mode -> step from F5/F6 repeat or Tab / [ ] (applied with the next frame's list)
var _held_pos := Vector3.ZERO # last position of an F6 target that is gone (the camera holds there)
var _tower_index: int = 0
var _tower_zoom: float = 1.0
var _mount_index: int = 0
var _head_drop: float = 0.0 # metres along the aircraft's up axis (negative = down)
var _head_tilt: float = 0.0 # radians of extra pitch (negative = nose-down)
var _cockpit_key: int = -1 # F1 shows this aircraft's cockpit (spectator after Tab); -1 = the player
var _ghost = GhostCamScript.new()

# ai_mode: the AI flies the player jet. benchmark: no camera input at all (fixed camera script).
func setup(sim: YSFlightSimulation, controls: Node, ai_mode: bool, benchmark: bool) -> void:
	_sim = sim
	_controls = controls
	_spectator_input = ai_mode and not benchmark
	_player_input = not ai_mode
	_launch_spectator = _spectator_input
	_launch_player = _player_input
	camera = Camera3D.new()
	camera.near = 1.5
	camera.far = 80000.0
	camera.fov = 60.0
	add_child(camera)
	_controls.changed.connect(_on_setting_changed)
	_on_setting_changed("cockpit_fov")

func _cockpit_base_fov() -> float:
	return clampf(float(_controls.get_value("cockpit_fov", SettingsSchema.COCKPIT_FOV_DEFAULT)),
		SettingsSchema.COCKPIT_FOV_MIN, SettingsSchema.COCKPIT_FOV_MAX)

func _on_setting_changed(key: String) -> void:
	if key == "cockpit_fov" or key.is_empty():
		cockpit_fov = _cockpit_base_fov()
		if mode == CamMode.COCKPIT:
			camera.fov = cockpit_fov

# The render origin moved by delta (main.gd): every stored render-space position moves with it.
func rebase(delta: Vector3) -> void:
	camera.global_position -= delta
	_flyby_pos -= delta
	_held_pos -= delta
	_lookdown_target -= delta
	_last_player_pos -= delta
	_ghost.rebase(delta)

func is_cockpit() -> bool:
	return mode == CamMode.COCKPIT

# The camera rides with the player's jet (not fly-by, spectator or tower): airflow effects apply.
func is_at_player() -> bool:
	if _cockpit_key >= 0:
		return false
	return mode in [CamMode.COCKPIT, CamMode.HORIZON_CHASE, CamMode.LOCKED_TAIL, CamMode.PADLOCK_THREAT,
		CamMode.ACTION_MOUNT, CamMode.LOOK_DOWN]

func is_mouse_dragging() -> bool:
	return _dragging

# A new player aircraft (respawn): modes that keep state from the previous jet start fresh.
func reset_for_new_aircraft() -> void:
	_locked_basis_valid = false
	_f2_loose_basis_valid = false
	_lookdown_target_valid = false
	_flyby_valid = false
	_padlock_active = false
	_padlock_target_key = -1
	_reset_head()

func set_mode(new_mode: int, same_key_pressed: bool = false) -> void:
	if is_online and new_mode != CamMode.COCKPIT and new_mode != CamMode.HORIZON_CHASE and new_mode != CamMode.LOOK_DOWN:
		return
	var prev := mode
	mode = new_mode
	if mode != CamMode.COCKPIT:
		_set_cockpit_key(-1)
	if mode == CamMode.GHOST and prev != CamMode.GHOST:
		_ghost.start(camera.global_transform)
	_reset_head() # every camera cut starts with the head centred
	var cockpit := mode == CamMode.COCKPIT
	_sim.set_cockpit_cull_mode(cockpit)
	if cockpit:
		camera.near = 0.15
		if same_key_pressed:
			head_yaw = 0.0
			head_pitch = 0.0
			cockpit_fov = _cockpit_base_fov()
			_has_mouse_dragged_cockpit = false
	elif mode == CamMode.LOOK_DOWN:
		camera.near = 0.2
		camera.fov = 65.0
		_lookdown_target_valid = false
	else:
		camera.near = 1.5
		camera.fov = 60.0
	match mode:
		CamMode.HORIZON_CHASE:
			if same_key_pressed:
				f2_sub_mode = (f2_sub_mode + 1) % 3
				_f2_loose_basis_valid = false
				cam_yaw = 0.0
				cam_pitch = DEFAULT_CAM_PITCH
				_has_mouse_dragged_ext = false
		CamMode.LOCKED_TAIL:
			if prev != CamMode.LOCKED_TAIL:
				_locked_basis_valid = false
			if same_key_pressed:
				_pending_step[mode] = 1
		CamMode.FLY_BY:
			_flyby_valid = false # every F4 press sets up a fresh fly-by
		CamMode.PADLOCK_THREAT, CamMode.SPECTATOR_AI:
			if same_key_pressed:
				_pending_step[mode] = 1
		CamMode.TOWER:
			if prev != CamMode.TOWER:
				_select_nearest_tower()
				_tower_zoom = 1.0
			elif same_key_pressed:
				_tower_index += 1
		CamMode.ACTION_MOUNT:
			if same_key_pressed:
				_mount_index = (_mount_index + 1) % ACTION_MOUNTS.size()

func press_cockpit_view() -> void:
	if mode == CamMode.COCKPIT:
		set_mode(CamMode.LOOK_DOWN)
	elif mode == CamMode.LOOK_DOWN:
		set_mode(CamMode.COCKPIT)
	else:
		set_mode(CamMode.COCKPIT)

func press_exterior_view() -> void:
	set_mode(CamMode.HORIZON_CHASE, mode == CamMode.HORIZON_CHASE)

func toggle_or_cycle_padlock() -> void:
	if mode != CamMode.COCKPIT and mode != CamMode.HORIZON_CHASE:
		return
	var enemies := _get_sorted_enemy_keys()
	if enemies.is_empty():
		status_text = "PADLOCK: NO TARGET"
		_padlock_active = false
		_padlock_target_key = -1
		return
	if not _padlock_active or _padlock_target_key < 0:
		_padlock_active = true
		_padlock_target_key = enemies[0]
	else:
		var cur_idx: int = enemies.find(_padlock_target_key)
		if cur_idx < 0:
			_padlock_target_key = enemies[0]
		else:
			_padlock_target_key = enemies[(cur_idx + 1) % enemies.size()]

func _get_sorted_enemy_keys() -> Array:
	var out: Array = []
	for k in _last_airplanes.keys():
		var st: Dictionary = _last_airplanes[k]
		if st.get("is_player", false) or not bool(st.get("is_alive", true)):
			continue
		if int(st.get("iff", -1)) != _last_player_iff:
			var d2: float = _last_player_pos.distance_squared_to(st.get("pos", Vector3.ZERO))
			out.append({"key": k, "dist2": d2})
	out.sort_custom(func(a, b) -> bool: return a["dist2"] < b["dist2"])
	var keys: Array = []
	for item in out:
		keys.append(item["key"])
	return keys

# ------------------------------------------------------------------------------
# Input
# ------------------------------------------------------------------------------

# Spectator (--ai-player) camera: mouse drag orbits / looks, wheel zooms, F1-F8 switch, Tab / [ ] cycle targets.
func _unhandled_input(event: InputEvent) -> void:
	if not _spectator_input:
		_player_camera_input(event)
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var zoom_in: bool = event.button_index == MOUSE_BUTTON_WHEEL_UP
			if mode == CamMode.COCKPIT:
				cockpit_fov = clampf(cockpit_fov + (-4.0 if zoom_in else 4.0), 22.0, 85.0)
			elif mode == CamMode.TOWER:
				_tower_zoom = clampf(_tower_zoom * (0.85 if zoom_in else 1.18), 0.2, 4.0)
			else:
				cam_distance = maxf(3.5, cam_distance * 0.88) if zoom_in else minf(2000.0, cam_distance * 1.14)
	elif event is InputEventMouseMotion and _dragging:
		if mode == CamMode.COCKPIT:
			head_yaw = clampf(head_yaw - event.relative.x * 0.006, -2.65, 2.65)
			head_pitch = clampf(head_pitch - event.relative.y * 0.006, -1.25, 1.35)
		else:
			cam_yaw -= event.relative.x * 0.008
			cam_pitch = clampf(cam_pitch - event.relative.y * 0.008, -1.45, 1.45)
	elif event is InputEventKey and event.pressed and not event.echo:
		if mode == CamMode.GHOST and _ghost.press_key(event.keycode):
			return
		if event.keycode == KEY_F1 and (mode == CamMode.SPECTATOR_AI or _cockpit_key >= 0) and _spectator_key >= 0:
			_view_target_cockpit(_spectator_key)
		elif event.keycode >= KEY_F1 and event.keycode <= KEY_F8:
			var m: int = CamMode.COCKPIT + (event.keycode - KEY_F1)
			set_mode(m, mode == m)
		elif event.keycode == KEY_F11:
			set_mode(CamMode.GHOST)
		elif event.keycode == KEY_C:
			recenter_views()
		elif event.keycode == KEY_TAB or event.keycode == KEY_BRACKETRIGHT:
			_cycle_target(1)
		elif event.keycode == KEY_BRACKETLEFT:
			_cycle_target(-1)

func _player_camera_input(event: InputEvent) -> void:
	# 1. Click-drag mouse look when enabled in settings
	var mouse_look_enabled: bool = _controls != null and bool(_controls.get_value("mouse_click_drag_view", false))
	if mouse_look_enabled:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				_dragging = event.pressed
				if _dragging:
					_padlock_active = false
			elif event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				var zoom_in: bool = event.button_index == MOUSE_BUTTON_WHEEL_UP
				if mode == CamMode.COCKPIT:
					cockpit_fov = clampf(cockpit_fov + (-4.0 if zoom_in else 4.0), 22.0, 85.0)
				else:
					cam_distance = maxf(3.5, cam_distance * 0.88) if zoom_in else minf(2000.0, cam_distance * 1.14)
		elif event is InputEventMouseMotion and _dragging:
			if mode == CamMode.COCKPIT:
				head_yaw = clampf(head_yaw - event.relative.x * 0.006, -2.65, 2.65)
				head_pitch = clampf(head_pitch - event.relative.y * 0.006, -1.25, 1.35)
				_has_mouse_dragged_cockpit = true
			elif mode == CamMode.HORIZON_CHASE:
				cam_yaw -= event.relative.x * 0.008
				cam_pitch = clampf(cam_pitch - event.relative.y * 0.008, -1.45, 1.45)
				_has_mouse_dragged_ext = true

	# 2. Key events
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_C:
			recenter_views()
			return
		if _controls == null:
			if event.keycode == KEY_F1:
				press_cockpit_view()
				return
			elif event.keycode == KEY_F2:
				press_exterior_view()
				return
		if event.keycode == KEY_F3:
			_press_f3_session_view()
			return
		if not is_online and _controls != null and bool(_controls.get_value("all_camera_views", false)):
			if event.keycode >= KEY_F4 and event.keycode <= KEY_F8:
				var m: int = CamMode.COCKPIT + (event.keycode - KEY_F1)
				set_mode(m, mode == m)
			elif event.keycode == KEY_BRACKETRIGHT:
				_cycle_target(1)
			elif event.keycode == KEY_BRACKETLEFT:
				_cycle_target(-1)

func _press_f3_session_view() -> void:
	if is_online:
		return
	if _controls == null or not bool(_controls.get_value("all_camera_views", false)):
		return
	var other := _other_keys(_last_airplanes, _last_player_iff)
	if other.is_empty():
		return # Alone in session, F3 does nothing
	if mode == CamMode.LOCKED_TAIL:
		_pending_step[CamMode.LOCKED_TAIL] = 1
	else:
		set_mode(CamMode.LOCKED_TAIL)

func recenter_views() -> void:
	head_yaw = 0.0
	head_pitch = 0.0
	cockpit_fov = _cockpit_base_fov()
	cam_yaw = 0.0
	cam_pitch = DEFAULT_CAM_PITCH
	_tower_zoom = 1.0
	_has_mouse_dragged_cockpit = false
	_has_mouse_dragged_ext = false
	_padlock_active = false

# F1 while spectating: sit in that aircraft's cockpit (its cockpit model, its own culled exterior).
func _view_target_cockpit(key: int) -> void:
	set_mode(CamMode.COCKPIT, mode == CamMode.COCKPIT)
	_set_cockpit_key(key)

func _set_cockpit_key(key: int) -> void:
	if key != _cockpit_key:
		_cockpit_key = key
		_sim.set_cockpit_airplane(key)

func _cycle_target(step: int) -> void:
	if _cockpit_key >= 0 and mode == CamMode.COCKPIT:
		_pending_step[CamMode.SPECTATOR_AI] = step
		_spectator_key = _locked_target(CamMode.SPECTATOR_AI, _spectator_key, _last_airplanes, _last_player_iff)
		_set_cockpit_key(_spectator_key)
		return
	match mode:
		CamMode.LOCKED_TAIL, CamMode.PADLOCK_THREAT:
			_pending_step[mode] = step
		CamMode.TOWER:
			_tower_index = maxi(0, _tower_index + step)
		CamMode.ACTION_MOUNT:
			_mount_index = (_mount_index + step + ACTION_MOUNTS.size()) % ACTION_MOUNTS.size()
		_:
			if mode != CamMode.SPECTATOR_AI:
				set_mode(CamMode.SPECTATOR_AI)
				if _spectator_key >= 0:
					return # The first Tab only switches to F6 on the current target
			_pending_step[CamMode.SPECTATOR_AI] = step

# Player camera input (normal play): zoom keys, head look (cockpit) and orbit (exterior) from the look keys,
# the gamepad right stick or a joystick hat.
func _player_look_input(delta: float) -> void:
	if not _player_input or _controls == null:
		return
	var held := func(action: String) -> bool: return _controls.is_action_held(action)
	if held.call("zoom_in"):
		if mode == CamMode.COCKPIT:
			cockpit_fov = clampf(cockpit_fov - 40.0 * delta, 20.0, 100.0)
		else:
			cam_distance = maxf(3.5, cam_distance * (1.0 - 0.8 * delta))
	if held.call("zoom_out"):
		if mode == CamMode.COCKPIT:
			cockpit_fov = clampf(cockpit_fov + 40.0 * delta, 20.0, 100.0)
		else:
			cam_distance = minf(2000.0, cam_distance * (1.0 + 0.8 * delta))

	var joy_id: int = _controls.get_joy_device()
	var rx: float = Input.get_joy_axis(joy_id, JOY_AXIS_RIGHT_X)
	var ry: float = Input.get_joy_axis(joy_id, JOY_AXIS_RIGHT_Y)
	if absf(rx) < 0.15:
		rx = 0.0
	if absf(ry) < 0.15:
		ry = 0.0
	if _controls.get_active_stick_device_name() == "Joystick": # POV hat
		if Input.is_joy_button_pressed(joy_id, JOY_BUTTON_DPAD_UP):
			ry = -1.0
		elif Input.is_joy_button_pressed(joy_id, JOY_BUTTON_DPAD_DOWN):
			ry = 1.0
		if Input.is_joy_button_pressed(joy_id, JOY_BUTTON_DPAD_LEFT):
			rx = -1.0
		elif Input.is_joy_button_pressed(joy_id, JOY_BUTTON_DPAD_RIGHT):
			rx = 1.0

	if mode == CamMode.COCKPIT:
		var target_yaw := 0.0
		var target_pitch := 0.0
		var looking := false
		if held.call("look_back"):
			target_yaw = 2.967 # ~170 degrees
			looking = true
		elif held.call("look_left"):
			target_yaw = 1.571
			looking = true
		elif held.call("look_right"):
			target_yaw = -1.571
			looking = true
		if held.call("look_up"):
			target_pitch = 1.047
			looking = true
		elif held.call("look_down"):
			target_pitch = -0.524
			looking = true
		if held.call("look_forward"):
			target_yaw = 0.0
			target_pitch = 0.0
			looking = true
		if absf(rx) > 0.01 or absf(ry) > 0.01:
			target_yaw = -rx * 1.571
			target_pitch = -ry * (1.047 if ry < 0.0 else 0.524)
			looking = true
		if looking:
			_padlock_active = false
			_has_mouse_dragged_cockpit = false
			head_yaw = move_toward(head_yaw, target_yaw, 5.0 * delta)
			head_pitch = move_toward(head_pitch, target_pitch, 4.0 * delta)
		elif not _has_mouse_dragged_cockpit and not _padlock_active:
			head_yaw = move_toward(head_yaw, 0.0, 4.5 * delta)
			head_pitch = move_toward(head_pitch, 0.0, 4.0 * delta)
	elif mode == CamMode.HORIZON_CHASE:
		var looking_ext := false
		if held.call("look_left"):
			cam_yaw += 2.0 * delta
			looking_ext = true
		if held.call("look_right"):
			cam_yaw -= 2.0 * delta
			looking_ext = true
		if held.call("look_up"):
			cam_pitch = clampf(cam_pitch + 1.5 * delta, -1.45, 1.45)
			looking_ext = true
		if held.call("look_down"):
			cam_pitch = clampf(cam_pitch - 1.5 * delta, -1.45, 1.45)
			looking_ext = true
		if held.call("look_forward"):
			cam_yaw = 0.0
			cam_pitch = DEFAULT_CAM_PITCH
			looking_ext = true
		if held.call("look_back"):
			cam_yaw = PI
			looking_ext = true
		if absf(rx) > 0.01:
			cam_yaw -= rx * 2.5 * delta
			looking_ext = true
		if absf(ry) > 0.01:
			cam_pitch = clampf(cam_pitch - ry * 2.0 * delta, -1.45, 1.45)
			looking_ext = true
		if looking_ext:
			_padlock_active = false

# ------------------------------------------------------------------------------
# Per-frame placement
# ------------------------------------------------------------------------------

func update(delta: float, player_tfm: Transform3D, tel: Dictionary, airplanes: Dictionary) -> void:
	_player_look_input(delta)
	var player_pos: Vector3 = player_tfm.origin
	var player_iff: int = int(tel.get("iff", 0))
	_last_player_pos = player_pos
	_last_player_iff = player_iff
	_last_airplanes = airplanes

	match mode:
		CamMode.COCKPIT when _cockpit_key >= 0:
			_update_target_cockpit(airplanes, player_iff)
		CamMode.GHOST:
			camera.fov = 60.0
			camera.global_transform = _ghost.update(delta, get_viewport(), _controls.get_joy_device() if _controls != null else 0,
				float(_controls.get_value("ghost_cam_smoothing", 0.5)) if _controls != null else 0.5)
			status_text = _ghost.status()
		CamMode.COCKPIT:
			camera.fov = cockpit_fov
			_update_head(delta, float(tel.get("g_force", 1.0)))
			var eye: Vector3 = (tel.get("cockpit_local", Vector3(0.0, 0.9, -3.15)) as Vector3) + Vector3(0.0, _head_drop, 0.0)
			camera.global_position = player_tfm * eye
			if _padlock_active and _padlock_target_key >= 0 and airplanes.has(_padlock_target_key) and bool(airplanes[_padlock_target_key].get("is_alive", true)):
				var tgt_pos: Vector3 = airplanes[_padlock_target_key]["pos"]
				_look_at(tgt_pos, player_tfm.basis.y)
				var dist_km := player_pos.distance_to(tgt_pos) / 1000.0
				var ident: String = str(airplanes[_padlock_target_key].get("identifier", "BANDIT"))
				status_text = "F1: PADLOCK [%s | %.1f km]" % [ident, dist_km]
			else:
				if _padlock_active:
					_padlock_active = false
					_padlock_target_key = -1
				camera.global_basis = (player_tfm.basis * Basis.from_euler(Vector3(head_pitch + _head_tilt, head_yaw, 0.0))).orthonormalized()
				status_text = "F1: COCKPIT VIEW (FOV %d°)" % int(round(cockpit_fov))

		CamMode.HORIZON_CHASE:
			if _padlock_active and _padlock_target_key >= 0 and airplanes.has(_padlock_target_key) and bool(airplanes[_padlock_target_key].get("is_alive", true)):
				var tgt_pos: Vector3 = airplanes[_padlock_target_key]["pos"]
				var to_tgt := (tgt_pos - player_pos).normalized()
				camera.global_position = player_pos - to_tgt * cam_distance + player_tfm.basis.y * 2.5
				_look_at(tgt_pos, Vector3.UP)
				var dist_km := player_pos.distance_to(tgt_pos) / 1000.0
				var ident: String = str(airplanes[_padlock_target_key].get("identifier", "BANDIT"))
				status_text = "F2: PADLOCK [%s | %.1f km]" % [ident, dist_km]
			else:
				if _padlock_active:
					_padlock_active = false
					_padlock_target_key = -1
				match f2_sub_mode:
					F2SubMode.RIGID_AXIS:
						var rot_offset := Basis.from_euler(Vector3(cam_pitch, cam_yaw, 0.0))
						var offset := rot_offset * Vector3(0.0, 2.2, cam_distance)
						camera.global_position = player_pos + player_tfm.basis * offset
						_look_at(player_pos + player_tfm.basis * Vector3(0.0, 0.6, -3.0), player_tfm.basis.y)
						status_text = "F2: CHASE - RIGID (%.0fm)" % cam_distance
					F2SubMode.LOOSE_FOLLOW:
						var cur_b := player_tfm.basis.orthonormalized()
						_f2_loose_basis = _f2_loose_basis.orthonormalized().slerp(cur_b, clampf(delta * 4.5, 0.0, 1.0)) if _f2_loose_basis_valid else cur_b
						_f2_loose_basis_valid = true
						var rot_offset := Basis.from_euler(Vector3(cam_pitch, cam_yaw, 0.0))
						var offset := rot_offset * Vector3(0.0, 2.2, cam_distance)
						camera.global_position = player_pos + _f2_loose_basis * offset
						_look_at(player_pos + _f2_loose_basis * Vector3(0.0, 0.6, -3.0), _f2_loose_basis.y)
						status_text = "F2: CHASE - LOOSE (%.0fm)" % cam_distance
					F2SubMode.FIXED_ANGLE:
						var fixed_rot := Basis.from_euler(Vector3(cam_pitch, cam_yaw, 0.0))
						var offset := fixed_rot * Vector3(0.0, 2.2, cam_distance)
						camera.global_position = player_pos + offset
						_look_at(player_pos + Vector3(0.0, 0.6, 0.0), Vector3.UP)
						status_text = "F2: CHASE - FIXED ANGLE (%.0fm)" % cam_distance

		CamMode.LOOK_DOWN:
			camera.fov = 65.0
			var nose_local: Vector3 = tel.get("nose_gear_pos", Vector3(0.0, -1.0, -3.5))
			var eye_pos: Vector3 = player_tfm * (nose_local + Vector3(0.0, -0.2, -0.8))
			camera.global_position = eye_pos
			var impact_pos := _compute_bomb_impact(player_pos, tel)
			if not _lookdown_target_valid:
				_lookdown_target = impact_pos
				_lookdown_target_valid = true
			else:
				_lookdown_target = _lookdown_target.lerp(impact_pos, clampf(delta * 8.0, 0.0, 1.0))
			_look_at(_lookdown_target, player_tfm.basis.y)
			status_text = "F1: BOMBSIGHT LOOK-DOWN (AGL %.0fm)" % float(tel.get("agl_m", 0.0))

		CamMode.LOCKED_TAIL:
			_f3_session_key = _locked_target(CamMode.LOCKED_TAIL, _f3_session_key, airplanes, player_iff)
			if not airplanes.has(_f3_session_key) or not bool(airplanes[_f3_session_key].get("is_alive", true)):
				_fallback_view(player_pos, "F3: SESSION FLIGHT [NO TARGET - F3 / Tab to cycle]")
			else:
				var st: Dictionary = airplanes[_f3_session_key]
				var t: Transform3D = st["transform"]
				var target_pos: Vector3 = t.origin
				var b := t.basis.orthonormalized()
				_locked_basis = _locked_basis.orthonormalized().slerp(b, clampf(delta * 10.0, 0.0, 1.0)) if _locked_basis_valid else b
				_locked_basis_valid = true
				var offset := Basis.from_euler(Vector3(cam_pitch * 0.4, cam_yaw, 0.0)) * Vector3(0.0, 2.8, cam_distance * 0.85)
				camera.global_position = target_pos + _locked_basis * offset
				_look_at(target_pos + t.basis * Vector3(0.0, 0.8, -8.0), _locked_basis.y)
				var keys := _other_keys(airplanes, player_iff)
				status_text = "F3: SESSION FLIGHT [%d/%d %s: %s]" % [keys.find(_f3_session_key) + 1, keys.size(),
					_side_name(st, player_iff), st.get("identifier", "AI")]
		CamMode.FLY_BY:
			_update_flyby(player_tfm, tel.get("velocity", -player_tfm.basis.z * 100.0))
		CamMode.PADLOCK_THREAT:
			_padlock_key = _locked_target(CamMode.PADLOCK_THREAT, _padlock_key, airplanes, player_iff)
			if not airplanes.has(_padlock_key) or not bool(airplanes[_padlock_key].get("is_alive", true)):
				_fallback_view(player_pos, "F5: PADLOCK [NO TARGET - Tab / [ ] for next]")
			else:
				var tgt: Dictionary = airplanes[_padlock_key]
				var tgt_pos: Vector3 = tgt["pos"]
				var to_tgt := tgt_pos - player_pos
				var dist_m := to_tgt.length()
				camera.global_position = player_pos - to_tgt / maxf(dist_m, 0.001) * (cam_distance * 0.9) + player_tfm.basis.y * 3.2
				_look_at(tgt_pos, Vector3.UP)
				status_text = "F5: PADLOCK [%s: %s | %.1f km]" % [_side_name(tgt, player_iff), tgt.get("identifier", "TARGET"), dist_m / 1000.0]
		CamMode.SPECTATOR_AI:
			_spectator_key = _locked_target(CamMode.SPECTATOR_AI, _spectator_key, airplanes, player_iff)
			if not airplanes.has(_spectator_key) or not bool(airplanes[_spectator_key].get("is_alive", true)):
				# Target destroyed: hold where it was until the user picks the next one.
				camera.global_position = _held_pos + _orbit_offset(Basis.IDENTITY)
				_look_at(_held_pos, Vector3.UP)
				status_text = "F6: SPECTATOR [TARGET GONE - Tab / [ ] for next]"
			else:
				var st: Dictionary = airplanes[_spectator_key]
				var t: Transform3D = st["transform"]
				_held_pos = t.origin
				camera.global_position = t.origin + _orbit_offset(t.basis)
				_look_at(t.origin, Vector3.UP)
				var keys := _other_keys(airplanes, player_iff)
				status_text = "F6: SPECTATOR [%d/%d %s: %s]" % [keys.find(_spectator_key) + 1, keys.size(),
					_side_name(st, player_iff), st.get("identifier", "AI")]
		CamMode.TOWER:
			_update_tower(player_pos)
		CamMode.ACTION_MOUNT:
			var mount: Dictionary = ACTION_MOUNTS[_mount_index % ACTION_MOUNTS.size()]
			camera.fov = float(mount["fov"])
			camera.global_position = player_tfm * (mount["pos"] as Vector3)
			_look_at(player_tfm * (mount["look_target"] as Vector3), player_tfm.basis.y)
			status_text = "F8: ACTION MOUNT [%s]" % mount["name"]

func _update_target_cockpit(airplanes: Dictionary, player_iff: int) -> void:
	if not airplanes.has(_cockpit_key) or not bool(airplanes[_cockpit_key].get("is_alive", true)):
		# The spectated jet is gone: back to orbiting where it was until the next Tab.
		set_mode(CamMode.SPECTATOR_AI)
		camera.global_position = _held_pos + _orbit_offset(Basis.IDENTITY)
		_look_at(_held_pos, Vector3.UP)
		return
	var st: Dictionary = airplanes[_cockpit_key]
	var t: Transform3D = st["transform"]
	_held_pos = t.origin
	camera.fov = cockpit_fov
	camera.global_position = t * (st.get("cockpit_local", Vector3(0.0, 0.9, -3.15)) as Vector3)
	camera.global_basis = (t.basis * Basis.from_euler(Vector3(head_pitch, head_yaw, 0.0))).orthonormalized()
	var keys := _other_keys(airplanes, player_iff)
	status_text = "F1: COCKPIT [%d/%d %s: %s]" % [keys.find(_cockpit_key) + 1, keys.size(),
		_side_name(st, player_iff), st.get("identifier", "AI")]

func _update_head(delta: float, g: float) -> void:
	if _controls == null or not bool(_controls.get_value("cockpit_head_movement", true)):
		_reset_head()
		return
	var g_load: float = (g - 1.0) / 8.0 # 0 at 1 G, 1 at +9 G
	var target_drop: float = clampf(-g_load * HEAD_DROP_AT_9G_M, -HEAD_DROP_AT_9G_M, HEAD_RISE_MAX_M)
	var target_tilt: float = deg_to_rad(HEAD_TILT_AT_9G_DEG) * clampf(g_load, 0.0, 1.0)
	var k: float = 1.0 - exp(-delta / HEAD_LAG_S)
	_head_drop += (target_drop - _head_drop) * k
	_head_tilt += (target_tilt - _head_tilt) * k

func _reset_head() -> void:
	_head_drop = 0.0
	_head_tilt = 0.0

# Orbit offset around an aircraft whose roll is ignored (horizon-stable chase).
func _orbit_offset(aircraft_basis: Basis) -> Vector3:
	var e := aircraft_basis.get_euler()
	var no_roll := Basis.from_euler(Vector3(e.x, e.y, 0.0))
	return no_roll * (Basis.from_euler(Vector3(cam_pitch, cam_yaw, 0.0)) * Vector3(0.0, 0.0, cam_distance))

func _update_flyby(player_tfm: Transform3D, velocity: Vector3) -> void:
	var player_pos := player_tfm.origin
	var dist := player_pos.distance_to(_flyby_pos)
	if not _flyby_valid or dist > 550.0:
		var fwd := velocity.normalized() if velocity.length() > 5.0 else (-player_tfm.basis.z).normalized()
		var right := fwd.cross(Vector3.UP)
		right = Vector3.RIGHT if right.length_squared() < 0.001 else right.normalized()
		_flyby_side = -_flyby_side
		_flyby_pos = player_pos + fwd * 300.0 + right * (36.0 * _flyby_side) + Vector3(0.0, 10.0, 0.0)
		_flyby_pos.y = maxf(_flyby_pos.y, 3.5 - _sim.get_render_origin().y) # 3.5 m above sea level
		_flyby_valid = true
		dist = player_pos.distance_to(_flyby_pos)
	camera.global_position = _flyby_pos
	camera.fov = clampf(2400.0 / maxf(dist, 25.0), 18.0, 65.0)
	_look_at(player_pos, Vector3.UP)
	status_text = "F4: CINEMATIC FLY-BY (%.0fm)" % dist

func _update_tower(player_pos: Vector3) -> void:
	var towers: PackedVector3Array = _sim.get_tower_positions()
	var origin: Vector3 = _sim.get_render_origin()
	var pos := Vector3(50.0, 28.0, 50.0) - origin # no tower on the map: near the map centre
	if towers.size() > 0:
		pos = towers[_tower_index % towers.size()]
		if pos.y + origin.y < 8.0:
			pos.y += 18.0 # tower given at ground level: raise to a cab height
	camera.global_position = pos
	var dist := player_pos.distance_to(pos)
	camera.fov = clampf((1900.0 / maxf(dist, 25.0)) * _tower_zoom, 6.0, 60.0)
	_look_at(player_pos, Vector3.UP)
	status_text = "F7: TOWER CAM [#%d/%d | %.1f km | FOV %d°]" % [(_tower_index % maxi(towers.size(), 1)) + 1,
		maxi(towers.size(), 1), dist / 1000.0, int(round(camera.fov))]

func _select_nearest_tower() -> void:
	var towers: PackedVector3Array = _sim.get_tower_positions()
	_tower_index = 0
	var player_pos: Vector3 = _sim.get_player_transform().origin
	var best := INF
	for i in towers.size():
		var d2 := player_pos.distance_squared_to(towers[i])
		if d2 < best:
			best = d2
			_tower_index = i

func _fallback_view(player_pos: Vector3, text: String) -> void:
	camera.global_position = player_pos + Vector3(0.0, 5.0, cam_distance)
	_look_at(player_pos, Vector3.UP)
	status_text = text

# Alive non-player aircraft, enemies first.
# Live aircraft other than the player: enemies first, each side in key order (stable while jets come and go).
func _other_keys(airplanes: Dictionary, player_iff: int) -> Array:
	var enemies: Array = []
	var friends: Array = []
	for key in airplanes.keys():
		var st: Dictionary = airplanes[key]
		if _session_spectator_iff >= 0 and int(st.get("iff", -1)) != _session_spectator_iff:
			continue
		if st.get("is_player", false) or not st.get("is_alive", true):
			continue
		if int(st.get("iff", -1)) != player_iff:
			enemies.append(key)
		else:
			friends.append(key)
	enemies.sort()
	friends.sort()
	return enemies + friends

# The locked target key: kept until the user steps (Tab / [ ] / the same F-key again). The first one is
# picked automatically only when nothing was chosen yet.
func _locked_target(for_mode: int, key: int, airplanes: Dictionary, player_iff: int) -> int:
	if _session_spectator_iff >= 0 and (not airplanes.has(key) or int(airplanes[key].get("iff", -1)) != _session_spectator_iff):
		key = -1
	var step: int = _pending_step.get(for_mode, 0)
	_pending_step.erase(for_mode)
	if step == 0 and key >= 0:
		return key
	var keys := _other_keys(airplanes, player_iff)
	if keys.is_empty():
		return key
	var i := keys.find(key)
	if i < 0:
		return keys[0] if step >= 0 else keys[keys.size() - 1]
	return keys[(i + step + keys.size()) % keys.size()]

# Offline roster targets stay on the chosen team; command-line spectator behavior is preserved.
func set_session_spectator(enabled: bool, iff: int, target_key: int = -1) -> void:
	_dragging = false
	_session_spectator_iff = iff if enabled else -1
	_spectator_input = enabled or _launch_spectator
	_player_input = not enabled and _launch_player
	set_process_unhandled_input(true)
	if enabled:
		set_mode(CamMode.SPECTATOR_AI)
		_spectator_key = target_key

func _side_name(st: Dictionary, player_iff: int) -> String:
	return "BANDIT" if int(st.get("iff", -1)) != player_iff else "ALLY"

func _look_at(target: Vector3, up: Vector3) -> void:
	var diff := target - camera.global_position
	var d := diff.length()
	if d < 0.001:
		return
	var dir := diff / d
	var safe_up := up.normalized()
	if absf(dir.dot(safe_up)) > 0.995:
		safe_up = Vector3.FORWARD if absf(dir.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	camera.look_at(target, safe_up)

func _compute_bomb_impact(player_pos: Vector3, tel: Dictionary) -> Vector3:
	if tel.has("bomb_impact_pos"):
		return tel["bomb_impact_pos"]
	var vel: Vector3 = tel.get("velocity", Vector3.ZERO)
	var agl: float = float(tel.get("agl_m", player_pos.y))
	var a: float = 0.5 * 9.80665
	var b: float = -vel.y
	var c: float = -maxf(agl, 1.0)
	var det: float = b * b - 4.0 * a * c
	if det >= 0.0:
		var t1: float = (-b + sqrt(det)) / (2.0 * a)
		var t2: float = (-b - sqrt(det)) / (2.0 * a)
		var t: float = t1 if t1 >= 0.0 else t2
		if t >= 0.0:
			var gnd_y: float = player_pos.y - agl
			return Vector3(player_pos.x + vel.x * t, gnd_y, player_pos.z + vel.z * t)
	return player_pos + vel * 2.0 + Vector3(0.0, -10.0, 0.0)
