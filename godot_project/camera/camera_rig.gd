extends Node

# The game camera: view modes, head look / orbit / zoom input, and placing the Camera3D every frame.
# Normal play uses F1 (cockpit) and F2 (exterior); F3-F8 are the replay / spectator cameras, available in
# --ai-player mode (and used by the benchmark's camera script).
# Positions come from the sim's interpolated transforms, the same ones the models are drawn with.

enum CamMode {
	COCKPIT = 1,        # F1: cockpit, free look + zoom
	HORIZON_CHASE = 2,  # F2: roll-stabilised orbit chase
	LOCKED_TAIL = 3,    # F3: roll-locked tail chase with a little G lag
	FLY_BY = 4,         # F4: fly-by, repositions ahead of the jet, telephoto
	PADLOCK_THREAT = 5, # F5: frames the player jet while looking at a bandit
	SPECTATOR_AI = 6,   # F6: orbit another aircraft
	TOWER = 7,          # F7: airfield tower with automatic zoom
	ACTION_MOUNT = 8,   # F8: cameras fixed to the airframe
}

const ACTION_MOUNTS := [
	{"name": "WINGTIP INWARD", "pos": Vector3(5.6, 0.35, 1.1), "look_target": Vector3(-1.5, 0.4, -2.2), "fov": 72.0},
	{"name": "TAIL FIN TOP", "pos": Vector3(0.0, 3.35, 6.2), "look_target": Vector3(0.0, 0.4, -12.0), "fov": 70.0},
	{"name": "OVER-THE-SHOULDER", "pos": Vector3(-0.85, 1.35, 0.4), "look_target": Vector3(0.0, 0.5, -15.0), "fov": 65.0},
	{"name": "BELLY / GEAR BAY", "pos": Vector3(0.0, -1.35, 4.5), "look_target": Vector3(0.0, -0.7, -15.0), "fov": 72.0},
]
const DEFAULT_COCKPIT_FOV := 65.0
const DEFAULT_CAM_PITCH := -0.18

var camera: Camera3D = null
var mode: int = CamMode.HORIZON_CHASE
var status_text: String = ""

var cam_yaw: float = 0.0
var cam_pitch: float = DEFAULT_CAM_PITCH
var cam_distance: float = 18.0
var head_yaw: float = 0.0
var head_pitch: float = 0.0
var cockpit_fov: float = DEFAULT_COCKPIT_FOV

var _sim: YSFlightSimulation = null
var _controls: Node = null
var _spectator_input := false # --ai-player: mouse orbit + F1-F8
var _player_input := true     # normal play: look keys / right stick / hat (off when the AI flies)
var _dragging := false
var _locked_basis := Basis.IDENTITY
var _locked_basis_valid := false
var _flyby_pos := Vector3.ZERO
var _flyby_valid := false
var _flyby_side: float = 1.0
var _padlock_index: int = 0
var _spectator_index: int = 0
var _tower_index: int = 0
var _tower_zoom: float = 1.0
var _mount_index: int = 0

# ai_mode: the AI flies the player jet. benchmark: no camera input at all (fixed camera script).
func setup(sim: YSFlightSimulation, controls: Node, ai_mode: bool, benchmark: bool) -> void:
	_sim = sim
	_controls = controls
	_spectator_input = ai_mode and not benchmark
	_player_input = not ai_mode
	camera = Camera3D.new()
	camera.near = 1.5
	camera.far = 80000.0
	camera.fov = 60.0
	add_child(camera)

func is_cockpit() -> bool:
	return mode == CamMode.COCKPIT

# A new player aircraft (respawn): modes that keep state from the previous jet start fresh.
func reset_for_new_aircraft() -> void:
	_locked_basis_valid = false
	_flyby_valid = false

func set_mode(new_mode: int, same_key_pressed: bool = false) -> void:
	var prev := mode
	mode = new_mode
	var cockpit := mode == CamMode.COCKPIT
	_sim.set_cockpit_cull_mode(cockpit)
	if cockpit:
		camera.near = 0.15
		if same_key_pressed:
			head_yaw = 0.0
			head_pitch = 0.0
			cockpit_fov = DEFAULT_COCKPIT_FOV
	else:
		camera.near = 1.5
		camera.fov = 60.0
	match mode:
		CamMode.HORIZON_CHASE:
			if same_key_pressed:
				cam_yaw = 0.0
				cam_pitch = DEFAULT_CAM_PITCH
		CamMode.LOCKED_TAIL:
			if prev != CamMode.LOCKED_TAIL:
				_locked_basis_valid = false
			if same_key_pressed:
				cam_yaw = 0.0
				cam_pitch = -0.12
		CamMode.FLY_BY:
			_flyby_valid = false # every F4 press sets up a fresh fly-by
		CamMode.PADLOCK_THREAT:
			if same_key_pressed:
				_padlock_index += 1
		CamMode.SPECTATOR_AI:
			if same_key_pressed:
				_spectator_index += 1
		CamMode.TOWER:
			if prev != CamMode.TOWER:
				_select_nearest_tower()
				_tower_zoom = 1.0
			elif same_key_pressed:
				_tower_index += 1
		CamMode.ACTION_MOUNT:
			if same_key_pressed:
				_mount_index = (_mount_index + 1) % ACTION_MOUNTS.size()

# ------------------------------------------------------------------------------
# Input
# ------------------------------------------------------------------------------

# Spectator (--ai-player) camera: mouse drag orbits / looks, wheel zooms, F1-F8 switch, Tab / [ ] cycle targets.
func _unhandled_input(event: InputEvent) -> void:
	if not _spectator_input:
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
		if event.keycode >= KEY_F1 and event.keycode <= KEY_F8:
			var m: int = CamMode.COCKPIT + (event.keycode - KEY_F1)
			set_mode(m, mode == m)
		elif event.keycode == KEY_C:
			head_yaw = 0.0
			head_pitch = 0.0
			cockpit_fov = DEFAULT_COCKPIT_FOV
			cam_yaw = 0.0
			cam_pitch = DEFAULT_CAM_PITCH
			_tower_zoom = 1.0
		elif event.keycode == KEY_TAB or event.keycode == KEY_BRACKETRIGHT:
			_cycle_target(1)
		elif event.keycode == KEY_BRACKETLEFT:
			_cycle_target(-1)

func _cycle_target(step: int) -> void:
	match mode:
		CamMode.PADLOCK_THREAT:
			_padlock_index = maxi(0, _padlock_index + step)
		CamMode.TOWER:
			_tower_index = maxi(0, _tower_index + step)
		CamMode.ACTION_MOUNT:
			_mount_index = (_mount_index + step + ACTION_MOUNTS.size()) % ACTION_MOUNTS.size()
		_:
			_spectator_index = maxi(0, _spectator_index + step)
			if step > 0 and mode != CamMode.SPECTATOR_AI:
				set_mode(CamMode.SPECTATOR_AI)

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
			head_yaw = move_toward(head_yaw, target_yaw, 5.0 * delta)
			head_pitch = move_toward(head_pitch, target_pitch, 4.0 * delta)
		else:
			head_yaw = move_toward(head_yaw, 0.0, 4.5 * delta)
			head_pitch = move_toward(head_pitch, 0.0, 4.0 * delta)
	elif mode == CamMode.HORIZON_CHASE:
		if held.call("look_left"):
			cam_yaw += 2.0 * delta
		if held.call("look_right"):
			cam_yaw -= 2.0 * delta
		if held.call("look_up"):
			cam_pitch = clampf(cam_pitch + 1.5 * delta, -1.45, 1.45)
		if held.call("look_down"):
			cam_pitch = clampf(cam_pitch - 1.5 * delta, -1.45, 1.45)
		if held.call("look_forward"):
			cam_yaw = 0.0
			cam_pitch = DEFAULT_CAM_PITCH
		if held.call("look_back"):
			cam_yaw = PI
		if absf(rx) > 0.01:
			cam_yaw -= rx * 2.5 * delta
		if absf(ry) > 0.01:
			cam_pitch = clampf(cam_pitch - ry * 2.0 * delta, -1.45, 1.45)

# ------------------------------------------------------------------------------
# Per-frame placement
# ------------------------------------------------------------------------------

func update(delta: float, player_tfm: Transform3D, tel: Dictionary, airplanes: Dictionary) -> void:
	_player_look_input(delta)
	var player_pos: Vector3 = player_tfm.origin
	var player_iff: int = int(tel.get("iff", 0))
	match mode:
		CamMode.COCKPIT:
			camera.fov = cockpit_fov
			camera.global_position = player_tfm * (tel.get("cockpit_local", Vector3(0.0, 0.9, -3.15)) as Vector3)
			camera.global_basis = (player_tfm.basis * Basis.from_euler(Vector3(head_pitch, head_yaw, 0.0))).orthonormalized()
			status_text = "F1: COCKPIT VIEW (FOV %d°)" % int(round(cockpit_fov))
		CamMode.HORIZON_CHASE:
			camera.global_position = player_pos + _orbit_offset(player_tfm.basis)
			_look_at(player_pos, Vector3.UP)
			status_text = "F2: HORIZON CHASE (%.0fm)" % cam_distance
		CamMode.LOCKED_TAIL:
			var b := player_tfm.basis.orthonormalized()
			_locked_basis = _locked_basis.orthonormalized().slerp(b, clampf(delta * 10.0, 0.0, 1.0)) if _locked_basis_valid else b
			_locked_basis_valid = true
			var offset := Basis.from_euler(Vector3(cam_pitch * 0.4, cam_yaw, 0.0)) * Vector3(0.0, 2.8, cam_distance * 0.85)
			camera.global_position = player_pos + _locked_basis * offset
			_look_at(player_pos + player_tfm.basis * Vector3(0.0, 0.8, -8.0), _locked_basis.y)
			status_text = "F3: LOCKED TAIL CAM (%.0fm)" % (cam_distance * 0.85)
		CamMode.FLY_BY:
			_update_flyby(player_tfm, tel.get("velocity", -player_tfm.basis.z * 100.0))
		CamMode.PADLOCK_THREAT:
			var targets := _other_airplanes(airplanes, player_iff)
			if targets.is_empty():
				_fallback_view(player_pos, "F5: PADLOCK [NO ACTIVE TARGETS]")
			else:
				var tgt: Dictionary = targets[_padlock_index % targets.size()]
				var tgt_pos: Vector3 = tgt["pos"]
				var to_tgt := tgt_pos - player_pos
				var dist_m := to_tgt.length()
				camera.global_position = player_pos - to_tgt / maxf(dist_m, 0.001) * (cam_distance * 0.9) + player_tfm.basis.y * 3.2
				_look_at(tgt_pos, Vector3.UP)
				status_text = "F5: PADLOCK [%s: %s | %.1f km]" % [_side_name(tgt, player_iff), tgt.get("identifier", "TARGET"), dist_m / 1000.0]
		CamMode.SPECTATOR_AI:
			var others := _other_airplanes(airplanes, player_iff)
			if others.is_empty():
				_fallback_view(player_pos, "F6: SPECTATOR [NO AI AIRCRAFT]")
			else:
				var st: Dictionary = others[_spectator_index % others.size()]
				var t: Transform3D = st["transform"]
				camera.global_position = t.origin + _orbit_offset(t.basis)
				_look_at(t.origin, Vector3.UP)
				status_text = "F6: SPECTATOR [%d/%d %s: %s]" % [(_spectator_index % others.size()) + 1, others.size(),
					_side_name(st, player_iff), st.get("identifier", "AI")]
		CamMode.TOWER:
			_update_tower(player_pos)
		CamMode.ACTION_MOUNT:
			var mount: Dictionary = ACTION_MOUNTS[_mount_index % ACTION_MOUNTS.size()]
			camera.fov = float(mount["fov"])
			camera.global_position = player_tfm * (mount["pos"] as Vector3)
			_look_at(player_tfm * (mount["look_target"] as Vector3), player_tfm.basis.y)
			status_text = "F8: ACTION MOUNT [%s]" % mount["name"]

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
		_flyby_pos.y = maxf(_flyby_pos.y, 3.5)
		_flyby_valid = true
		dist = player_pos.distance_to(_flyby_pos)
	camera.global_position = _flyby_pos
	camera.fov = clampf(2400.0 / maxf(dist, 25.0), 18.0, 65.0)
	_look_at(player_pos, Vector3.UP)
	status_text = "F4: CINEMATIC FLY-BY (%.0fm)" % dist

func _update_tower(player_pos: Vector3) -> void:
	var towers: PackedVector3Array = _sim.get_tower_positions()
	var pos := Vector3(50.0, 28.0, 50.0)
	if towers.size() > 0:
		pos = towers[_tower_index % towers.size()]
		if pos.y < 8.0:
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
func _other_airplanes(airplanes: Dictionary, player_iff: int) -> Array:
	var enemies: Array = []
	var friends: Array = []
	for st in airplanes.values():
		if st.get("is_player", false) or not st.get("is_alive", true):
			continue
		if int(st.get("iff", -1)) != player_iff:
			enemies.append(st)
		else:
			friends.append(st)
	return enemies + friends

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
