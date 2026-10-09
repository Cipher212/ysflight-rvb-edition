extends Node
class_name Controls

# ==============================================================================
# YSFlight Godot Port - Controls Subsystem
# ==============================================================================
# Handles all player flight inputs, response curves, device management (Mouse-as-stick,
# Gamepad, Joystick/HOTAS, Keyboard), weapon triggers and YSFlight button events.
# Owns user://controls.cfg (the settings themselves are listed in controls/settings_schema.gd).
# Camera look / orbit / zoom input lives in camera/camera_rig.gd (it reads is_action_held()).
# ==============================================================================

signal changed(key: String)

const CONFIG_PATH: String = "user://controls.cfg"

# Linear throttle spool delays (0% -> 100% in 2.4s, 50% in 1.2s)
const THROTTLE_SPOOL_UP_TIME: float = 2.4
const THROTTLE_SPOOL_DOWN_TIME: float = 2.4
const THROTTLE_SPOOL_UP_RATE: float = 1.0 / THROTTLE_SPOOL_UP_TIME
const THROTTLE_SPOOL_DOWN_RATE: float = 1.0 / THROTTLE_SPOOL_DOWN_TIME
const AFTERBURNER_ENGAGE_THRESHOLD: float = 0.99

const SETTINGS: Array[Dictionary] = preload("res://controls/settings_schema.gd").SETTINGS # every setting + default

var main: Node = null
var ysflight_sim: YSFlightSimulation = null
var settings_panel: CanvasLayer = null
# Set by core/event_session.gd during an offline event: Esc ("open_settings") goes there instead.
var open_settings_handler: Callable = Callable()
var _session_input_enabled := true

var _config: ConfigFile = ConfigFile.new()
var _values: Dictionary = {}
var _binding_to_actions: Dictionary = {}

# Active device tracking
var _active_stick_device: String = "Keyboard"
var _mouse_stick_enabled: bool = true
var _mouse_drag_view_held: bool = false
var _last_joy_device: int = 0
var _last_joy_throttle_val: float = -999.0

# Continuous state
var current_throttle: float = 0.85
var _actual_throttle: float = 0.85
var _afterburner_lit: bool = false
var current_trim: float = 0.0

var _last_elevator: float = 0.0
var _last_aileron: float = 0.0
var _last_rudder: float = 0.0

# Keyboard stick deflection
var _kb_pitch: float = 0.0
var _kb_roll: float = 0.0
var _kb_rudder: float = 0.0

# Input tracking
var _held_inputs: Dictionary = {}
var _action_held: Dictionary = {}
var _action_just_pressed: Dictionary = {}

# Initialization state
var _initialized_telemetry: bool = false
var _prev_is_alive: bool = false
var _paused_before_settings: bool = false

func _init():
	process_mode = Node.PROCESS_MODE_ALWAYS

func setup(p_main: Node, p_sim: YSFlightSimulation) -> void:
	main = p_main
	ysflight_sim = p_sim
	_load_settings()
	# Mouse = stick position: start centred so the jet doesn't spawn already rolling/pitching.
	# Deferred because the window may not have its final size yet.
	recenter_mouse.call_deferred()
	if is_inside_tree() and get_tree() != null:
		get_tree().create_timer(0.3).timeout.connect(recenter_mouse)

func set_settings_panel(panel: CanvasLayer) -> void:
	settings_panel = panel

# ------------------------------------------------------------------------------
# Configuration & Persistence
# ------------------------------------------------------------------------------
func _load_settings() -> void:
	_config = ConfigFile.new()
	var err: Error = _config.load(CONFIG_PATH)

	# Populate defaults
	for s in SETTINGS:
		if s["type"] == "binding":
			var k: String = s["key"]
			_values["bind." + k] = s.get("default", "")
			_values["bind2." + k] = s.get("default2", "")
			if s.get("slots", 2) >= 3:
				_values["bind3." + k] = s.get("default3", "")
		else:
			_values[s["key"]] = s.get("default")

	# Override with saved values
	if err == OK:
		for k in _config.get_section_keys("controls"):
			_values[k] = _config.get_value("controls", k)

	_rebuild_binding_map()

func get_value(key: String, fallback: Variant = null) -> Variant:
	if _values.has(key):
		return _values[key]
	# Fallback check for binding key without prefix
	if _values.has("bind." + key):
		return _values["bind." + key]
	return fallback

func set_value(key: String, v: Variant) -> void:
	_values[key] = v
	_config.set_value("controls", key, v)
	_config.save(CONFIG_PATH)
	_rebuild_binding_map()
	changed.emit(key)

func reset_to_defaults() -> void:
	_config.erase_section("controls")
	for s in SETTINGS:
		if s["type"] == "binding":
			var k: String = s["key"]
			var d1: String = s.get("default", "")
			var d2: String = s.get("default2", "")
			_values["bind." + k] = d1
			_values["bind2." + k] = d2
			_config.set_value("controls", "bind." + k, d1)
			_config.set_value("controls", "bind2." + k, d2)
			if s.get("slots", 2) >= 3:
				var d3: String = s.get("default3", "")
				_values["bind3." + k] = d3
				_config.set_value("controls", "bind3." + k, d3)
		else:
			var val: Variant = s.get("default")
			_values[s["key"]] = val
			_config.set_value("controls", s["key"], val)

	_config.save(CONFIG_PATH)
	_rebuild_binding_map()
	changed.emit("")

func _rebuild_binding_map() -> void:
	_binding_to_actions.clear()
	for s in SETTINGS:
		if s["type"] == "binding":
			var act: String = s["key"]
			var slots: int = s.get("slots", 2)
			for i in range(1, slots + 1):
				var slot_key: String = "bind." + act if i == 1 else "bind%d." % i + act
				var b_str: String = str(get_value(slot_key, ""))
				if b_str != "":
					if not _binding_to_actions.has(b_str):
						_binding_to_actions[b_str] = []
					if not _binding_to_actions[b_str].has(act):
						_binding_to_actions[b_str].append(act)

# ------------------------------------------------------------------------------
# Binding Conversions & Formatters
# ------------------------------------------------------------------------------
static func event_to_binding_string(event: InputEvent) -> String:
	if event is InputEventKey:
		var kc: Key = event.keycode
		if kc == KEY_NONE:
			kc = event.physical_keycode
		var k_name: String = OS.get_keycode_string(kc)
		if k_name.is_empty():
			k_name = OS.get_keycode_string(event.physical_keycode)
		if k_name == "Control":
			k_name = "Ctrl"
		return "key:" + k_name
	elif event is InputEventMouseButton:
		return "mouse:%d" % event.button_index
	elif event is InputEventJoypadButton:
		return "joy_button:%d" % event.button_index
	return ""

static func binding_to_readable_string(b: String) -> String:
	if b == "" or b.is_empty():
		return "None"
	if b.begins_with("key:"):
		return b.substr(4)
	elif b.begins_with("mouse:"):
		var idx: int = b.substr(6).to_int()
		match idx:
			MOUSE_BUTTON_LEFT: return "Mouse Left"
			MOUSE_BUTTON_RIGHT: return "Mouse Right"
			MOUSE_BUTTON_MIDDLE: return "Mouse Middle"
			MOUSE_BUTTON_WHEEL_UP: return "Wheel Up"
			MOUSE_BUTTON_WHEEL_DOWN: return "Wheel Down"
			_: return "Mouse Button %d" % idx
	elif b.begins_with("joy_button:"):
		var j_idx: int = b.substr(11).to_int()
		match j_idx:
			0: return "Pad A / Button 0"
			1: return "Pad B / Button 1"
			2: return "Pad X / Button 2"
			3: return "Pad Y / Button 3"
			4: return "Pad Back / Button 4"
			5: return "Pad Guide / Button 5"
			6: return "Pad Start / Button 6"
			7: return "Pad L-Stick / Button 7"
			8: return "Pad R-Stick / Button 8"
			9: return "Pad LB / Button 9"
			10: return "Pad RB / Button 10"
			11: return "Pad D-Up / Button 11"
			12: return "Pad D-Down / Button 12"
			13: return "Pad D-Left / Button 13"
			14: return "Pad D-Right / Button 14"
			_: return "Pad Button %d" % j_idx
	return b

func is_action_held(action: String) -> bool:
	return _action_held.get(action, false)

func is_action_just_pressed(action: String) -> bool:
	return _action_just_pressed.get(action, false)

func get_active_stick_device_name() -> String:
	var mode: String = str(get_value("stick_device", "Auto"))
	if mode != "Auto":
		return mode
	return _active_stick_device

# Device index of the gamepad / joystick used last.
func get_joy_device() -> int:
	return _last_joy_device

func is_afterburner_on() -> bool:
	return _afterburner_lit

func get_flight_controls_state() -> Dictionary:
	return {
		"pitch": _last_elevator,
		"roll": _last_aileron,
		"rudder": _last_rudder,
		"throttle": current_throttle,
		"afterburner": _afterburner_lit,
		"trim": current_trim,
		"device": get_active_stick_device_name()
	}

# ------------------------------------------------------------------------------
# Input Handling
# ------------------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	if not _session_input_enabled:
		var binding := event_to_binding_string(event)
		if event.is_pressed() and not event.is_echo() and "open_settings" in _binding_to_actions.get(binding, []):
			_on_action_pressed("open_settings")
			get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadMotion or event is InputEventJoypadButton:
		_last_joy_device = event.device

	# Stick Device Auto-detection
	var mode: String = str(get_value("stick_device", "Auto"))
	if mode == "Auto":
		if event is InputEventMouseMotion:
			if _mouse_stick_enabled and event.relative.length_squared() > 9.0:
				_active_stick_device = "Mouse"
		elif event is InputEventJoypadMotion:
			if abs(event.axis_value) > 0.25:
				if Input.is_joy_known(event.device):
					_active_stick_device = "Gamepad"
				else:
					_active_stick_device = "Joystick"

	# Mouse wheel throttle
	if bool(get_value("mouse_wheel_throttle", true)) and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			current_throttle = clamp(current_throttle + 0.05, 0.0, 1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			current_throttle = clamp(current_throttle - 0.05, 0.0, 1.0)
			if current_throttle < 1.0:
				_afterburner_lit = false

	# Action bindings capture
	var b_str: String = event_to_binding_string(event)
	if b_str != "":
		# When Click-Drag Mouse View is enabled, left-click is reserved for looking around, not weapon fire
		if b_str == "mouse:1" and bool(get_value("mouse_click_drag_view", false)):
			_mouse_drag_view_held = event.is_pressed()
			return

		if event.is_pressed():
			if not event.is_echo():
				_held_inputs[b_str] = true
				if _binding_to_actions.has(b_str):
					for act in _binding_to_actions[b_str]:
						_action_just_pressed[act] = true
						_action_held[act] = true
						_on_action_pressed(act)
		else:
			_held_inputs.erase(b_str)
			if _binding_to_actions.has(b_str):
				for act in _binding_to_actions[b_str]:
					var still_held: bool = false
					for pfx in ["bind.", "bind2.", "bind3."]:
						var bound_key: String = str(get_value(pfx + act, ""))
						if bound_key != "" and _held_inputs.get(bound_key, false):
							still_held = true
							break
					if not still_held:
						_action_held[act] = false
						_on_action_released(act)

func set_session_input_enabled(enabled: bool) -> void:
	_session_input_enabled = enabled
	_held_inputs.clear()
	_action_held.clear()
	_action_just_pressed.clear()
	set_physics_process(enabled)
	_mouse_drag_view_held = false
	if not enabled and ysflight_sim != null:
		ysflight_sim.set_player_weapon_inputs(false, false, false, false, false)

func _on_action_pressed(action: String) -> void:
	# Menu & Pause work even during spectator/ai mode or pause
	if action == "open_settings":
		if open_settings_handler.is_valid():
			open_settings_handler.call()
		else:
			toggle_settings()
		return
	elif action == "pause":
		toggle_pause()
		return
	elif action == "cycle_hud_color":
		var colors := ["Green", "Amber", "Cyan", "White"]
		var cur: String = str(get_value("hud_color", "Green"))
		var idx: int = colors.find(cur)
		var next_color: String = colors[(idx + 1) % colors.size()] if idx >= 0 else "Green"
		set_value("hud_color", next_color)
		return
	elif action == "toggle_debug_text":
		var cur_dbg: bool = bool(get_value("show_debug_text", false))
		set_value("show_debug_text", not cur_dbg)
		return

	# In AI player mode (spectator / benchmark), controls send no flight or weapon inputs
	if main != null and main.get("ai_player_mode") == true:
		return

	# If pilot is unconscious due to G-LOC, suppress weapon firing and aircraft buttons
	if main != null and main.has_node("GForce"):
		var gf = main.get_node("GForce")
		if gf != null and gf.has_method("is_gloc") and gf.is_gloc():
			return

	match action:
		"view_cockpit":
			if main != null and main.camera_rig != null:
				main.camera_rig.press_cockpit_view()
		"view_exterior":
			if main != null and main.camera_rig != null:
				main.camera_rig.press_exterior_view()
		"padlock":
			if main != null and main.camera_rig != null:
				main.camera_rig.toggle_or_cycle_padlock()
		"recenter_mouse_stick":
			recenter_mouse()
		"toggle_mouse_stick":
			_mouse_stick_enabled = not _mouse_stick_enabled
		"gear":
			if ysflight_sim != null:
				ysflight_sim.press_button("LANDINGGEAR")
		"flaps_up":
			if ysflight_sim != null:
				ysflight_sim.press_button("FLAPUP")
		"flaps_down":
			if ysflight_sim != null:
				ysflight_sim.press_button("FLAPDOWN")
		"radar":
			if ysflight_sim != null:
				ysflight_sim.press_button("RADAR")
		"radar_filter":
			if main != null:
				var rs = main.get("radar_scope")
				if rs != null and rs.has_method("cycle_filter_mode"):
					rs.cycle_filter_mode()
		"radar_enlarge":
			if main != null:
				var rs = main.get("radar_scope")
				if rs != null and rs.has_method("toggle_enlarge"):
					rs.toggle_enlarge()
		"bomb_bay":
			if ysflight_sim != null:
				ysflight_sim.press_button("BOMBBAYDOOR")
		"brake":
			if str(get_value("brake_mode", "Toggle")) == "Toggle":
				if ysflight_sim != null:
					ysflight_sim.press_button("BRAKEONOFF")
			else:
				if ysflight_sim != null:
					ysflight_sim.set_player_control("brake", 1.0)
		"spoiler":
			if str(get_value("spoiler_mode", "Toggle")) == "Toggle":
				if ysflight_sim != null:
					ysflight_sim.press_button("SPOILER")
			else:
				if ysflight_sim != null:
					ysflight_sim.set_player_control("spoiler", 1.0)
		"afterburner":
			# Fix: Tab toggles afterburner while ensuring 100% throttle
			if not _afterburner_lit:
				current_throttle = 1.0
				_afterburner_lit = true
			else:
				_afterburner_lit = false
				current_throttle = 1.0
		"throttle_max":
			current_throttle = 1.0
			_afterburner_lit = true
		"throttle_idle":
			current_throttle = 0.0
			_afterburner_lit = false
		"auto_trim":
			current_trim = clamp(current_trim + _last_elevator, -1.0, 1.0)
		"rudder_center":
			_kb_rudder = 0.0
		"select_gun":
			_try_select_weapon([0])
		"select_short_range_missile":
			_try_select_weapon([10, 1])
		"select_long_range_missile":
			_try_select_weapon([6])
		"select_air_to_ground":
			_try_select_weapon([2])
		"select_bombs_rockets":
			_try_select_weapon([3, 7, 9, 4])

func _on_action_released(action: String) -> void:
	if main != null and main.get("ai_player_mode") == true:
		return

	if action == "brake" and str(get_value("brake_mode", "Toggle")) == "Hold":
		if ysflight_sim != null:
			ysflight_sim.set_player_control("brake", 0.0)
	elif action == "spoiler" and str(get_value("spoiler_mode", "Toggle")) == "Hold":
		if ysflight_sim != null:
			ysflight_sim.set_player_control("spoiler", 0.0)

func _try_select_weapon(types: Array) -> void:
	if ysflight_sim == null or not ysflight_sim.has_method("select_weapon"):
		return
	for t in types:
		if ysflight_sim.select_weapon(int(t)):
			break

func recenter_mouse() -> void:
	var vp: Viewport = get_viewport()
	if vp != null:
		var centre: Vector2 = vp.get_visible_rect().size * 0.5
		Input.warp_mouse(centre)

func toggle_pause() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	tree.paused = not tree.paused

# pause = false during offline events (the event clock and the AI keep running)
func toggle_settings(pause: bool = true) -> void:
	if settings_panel == null:
		return
	if settings_panel.visible:
		settings_panel.visible = false
		if not _paused_before_settings:
			get_tree().paused = false
	else:
		_paused_before_settings = get_tree().paused
		get_tree().paused = pause
		settings_panel.visible = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# ------------------------------------------------------------------------------
# Response Curve & Stick Math
# ------------------------------------------------------------------------------
static func apply_curve(x: float, dz: float, expo: float, sensitivity: float) -> float:
	var abs_x: float = absf(x)
	if abs_x <= dz:
		return 0.0
	var s: float = sign(x) * ((abs_x - dz) / (1.0 - dz))
	var y: float = ((1.0 - expo) * s + expo * s * s * s) * sensitivity
	return clamp(y, -1.0, 1.0)

static func parse_axis_index(val: Variant) -> int:
	if val is int:
		return val
	var s: String = str(val)
	if s == "None" or s == "-1":
		return -1
	return s.replace("Axis ", "").to_int()

# ------------------------------------------------------------------------------
# Physics Process (Tick Inputs to YSFlight)
# ------------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if ysflight_sim == null:
		return

	# Handle respawn and airborne start power initialization
	var is_alive: bool = true
	if ysflight_sim.has_method("get_player_telemetry"):
		var t: Dictionary = ysflight_sim.get_player_telemetry()
		is_alive = bool(t.get("is_alive", true))
		if not _initialized_telemetry or (is_alive and not _prev_is_alive):
			if t.has("throttle"):
				current_throttle = float(t.get("throttle", 0.85))
				_actual_throttle = current_throttle
			if t.has("afterburner"):
				_afterburner_lit = bool(t.get("afterburner", false))
			_initialized_telemetry = true
	_prev_is_alive = is_alive

	if not is_alive or (main != null and main.get("ai_player_mode") == true):
		_action_just_pressed.clear()
		return

	# Pilot G-LOC (loss of consciousness): freeze stick to neutral, maintain throttle/afterburner, zero weapons
	var is_unconscious: bool = false
	if main != null and main.has_node("GForce"):
		var gf = main.get_node("GForce")
		if gf != null and gf.has_method("is_gloc"):
			is_unconscious = gf.is_gloc()

	# Spool throttle linearly (0% to 100% in 2.4s)
	var spool_rate: float = THROTTLE_SPOOL_UP_RATE if current_throttle > _actual_throttle else THROTTLE_SPOOL_DOWN_RATE
	_actual_throttle = move_toward(_actual_throttle, current_throttle, spool_rate * delta)
	var actual_ab: bool = _afterburner_lit and _actual_throttle >= AFTERBURNER_ENGAGE_THRESHOLD

	if is_unconscious:
		_last_elevator = 0.0
		_last_aileron = 0.0
		_last_rudder = 0.0
		_kb_pitch = 0.0
		_kb_roll = 0.0
		_kb_rudder = 0.0
		ysflight_sim.set_player_flight_inputs(
			0.0,
			0.0,
			0.0,
			_actual_throttle,
			actual_ab,
			current_trim
		)
		ysflight_sim.set_player_weapon_inputs(
			false,
			false,
			false,
			false,
			false
		)
		_action_just_pressed.clear()
		return

	# --- 1. Continuous Trim ---
	if _action_held.get("trim_up", false):
		current_trim = clamp(current_trim + 0.3 * delta, -1.0, 1.0)
	if _action_held.get("trim_down", false):
		current_trim = clamp(current_trim - 0.3 * delta, -1.0, 1.0)

	# --- 2. Keyboard Stick & Rudder ---
	var kb_rate: float = float(get_value("kb_stick_rate", 3.0))
	var kb_ret: float = float(get_value("kb_return_rate", 4.0))
	var kb_max: float = float(get_value("kb_max_travel", 1.0))

	# Elevator: pitch_up (+nose up), pitch_down (-nose down)
	var p_up: bool = _action_held.get("pitch_up", false)
	var p_down: bool = _action_held.get("pitch_down", false)
	if p_up and not p_down:
		_kb_pitch = min(_kb_pitch + kb_rate * delta, kb_max)
	elif p_down and not p_up:
		_kb_pitch = max(_kb_pitch - kb_rate * delta, -kb_max)
	else:
		_kb_pitch = move_toward(_kb_pitch, 0.0, kb_ret * delta)

	# Aileron: roll_left (+1 bank left), roll_right (-1 bank right)
	var r_left: bool = _action_held.get("roll_left", false)
	var r_right: bool = _action_held.get("roll_right", false)
	if r_left and not r_right:
		_kb_roll = min(_kb_roll + kb_rate * delta, kb_max)
	elif r_right and not r_left:
		_kb_roll = max(_kb_roll - kb_rate * delta, -kb_max)
	else:
		_kb_roll = move_toward(_kb_roll, 0.0, kb_ret * delta)

	# Rudder: rudder_left (+1 yaw left), rudder_right (-1 yaw right)
	var rud_l: bool = _action_held.get("rudder_left", false)
	var rud_r: bool = _action_held.get("rudder_right", false)
	if rud_l and not rud_r:
		_kb_rudder = min(_kb_rudder + kb_rate * delta, 1.0)
	elif rud_r and not rud_l:
		_kb_rudder = max(_kb_rudder - kb_rate * delta, -1.0)
	else:
		_kb_rudder = move_toward(_kb_rudder, 0.0, kb_ret * delta)

	# --- 3. Analog Flight Stick Sources ---
	var active_device: String = get_active_stick_device_name()
	var analog_pitch: float = 0.0
	var analog_roll: float = 0.0
	var analog_rudder: float = 0.0

	var joy_id: int = _last_joy_device

	match active_device:
		"Mouse":
			if _mouse_stick_enabled and not (bool(get_value("mouse_click_drag_view", false)) and _mouse_drag_view_held):
				var vp: Viewport = get_viewport()
				if vp != null:
					var vp_rect: Rect2 = vp.get_visible_rect()
					var centre: Vector2 = vp_rect.size * 0.5
					var scale_factor: float = max(0.45 * vp_rect.size.y, 1.0)
					var mpos: Vector2 = vp.get_mouse_position()
					var raw_x: float = clamp((mpos.x - centre.x) / scale_factor, -1.0, 1.0)
					var raw_y: float = clamp((mpos.y - centre.y) / scale_factor, -1.0, 1.0)

					# YS signs: mouse right -> roll right (aileron -1)
					# mouse down -> pitch up (elevator +1 unless inverted)
					var m_roll: float = -raw_x
					var m_pitch: float = raw_y
					if bool(get_value("mouse_invert_pitch", false)):
						m_pitch = -m_pitch

					var m_dz: float = float(get_value("mouse_deadzone", 0.03))
					var m_expo: float = float(get_value("mouse_expo", 0.3))
					var m_sens: float = float(get_value("mouse_sensitivity", 1.0))

					analog_roll = apply_curve(m_roll, m_dz, m_expo, m_sens)
					analog_pitch = apply_curve(m_pitch, m_dz, m_expo, m_sens)

		"Gamepad":
			# Left stick: X = axis 0, Y = axis 1
			var gp_x: float = Input.get_joy_axis(joy_id, JOY_AXIS_LEFT_X)
			var gp_y: float = Input.get_joy_axis(joy_id, JOY_AXIS_LEFT_Y)

			# YS signs: Left stick left (-1) rolls left (+1), stick back (+1) pitches up (+1)
			var pad_roll: float = -gp_x
			var pad_pitch: float = gp_y
			if bool(get_value("pad_invert_pitch", false)):
				pad_pitch = -pad_pitch

			var p_dz: float = float(get_value("pad_deadzone", 0.1))
			var p_expo: float = float(get_value("pad_expo", 0.4))
			var p_sens: float = float(get_value("pad_sensitivity", 1.0))

			analog_roll = apply_curve(pad_roll, p_dz, p_expo, p_sens)
			analog_pitch = apply_curve(pad_pitch, p_dz, p_expo, p_sens)

			# Gamepad trigger throttle
			var rt: float = max(0.0, Input.get_joy_axis(joy_id, JOY_AXIS_TRIGGER_RIGHT))
			var lt: float = max(0.0, Input.get_joy_axis(joy_id, JOY_AXIS_TRIGGER_LEFT))
			var pad_thr_rate: float = float(get_value("pad_throttle_rate", 0.6))

			if rt > 0.05:
				current_throttle = clamp(current_throttle + pad_thr_rate * rt * delta, 0.0, 1.0)
			if lt > 0.05:
				current_throttle = clamp(current_throttle - pad_thr_rate * lt * delta, 0.0, 1.0)
				if current_throttle < 1.0:
					_afterburner_lit = false

			# Afterburner detent on right trigger
			if rt > 0.95 and current_throttle >= 0.999:
				_afterburner_lit = true
			elif _afterburner_lit and rt < 0.5:
				_afterburner_lit = false

		"Joystick":
			var r_axis: int = parse_axis_index(get_value("joy_roll_axis", 0))
			var p_axis: int = parse_axis_index(get_value("joy_pitch_axis", 1))
			var rud_axis: int = parse_axis_index(get_value("joy_rudder_axis", -1))
			var thr_axis: int = parse_axis_index(get_value("joy_throttle_axis", 2))

			var j_dz: float = float(get_value("joy_deadzone", 0.05))
			var j_expo: float = float(get_value("joy_expo", 0.2))
			var j_sens: float = float(get_value("joy_sensitivity", 1.0))

			if r_axis >= 0:
				var j_x: float = Input.get_joy_axis(joy_id, r_axis as JoyAxis)
				analog_roll = apply_curve(-j_x, j_dz, j_expo, j_sens)

			if p_axis >= 0:
				var j_y: float = Input.get_joy_axis(joy_id, p_axis as JoyAxis)
				if bool(get_value("joy_invert_pitch", false)):
					j_y = -j_y
				analog_pitch = apply_curve(j_y, j_dz, j_expo, j_sens)

			if rud_axis >= 0:
				var j_z: float = Input.get_joy_axis(joy_id, rud_axis as JoyAxis)
				if bool(get_value("joy_rudder_invert", false)):
					j_z = -j_z
				analog_rudder = apply_curve(-j_z, j_dz, j_expo, j_sens)

			if thr_axis >= 0:
				var raw_thr: float = Input.get_joy_axis(joy_id, thr_axis as JoyAxis)
				var mapped_thr: float = (raw_thr + 1.0) * 0.5
				if bool(get_value("joy_throttle_invert", true)):
					mapped_thr = 1.0 - mapped_thr
				mapped_thr = clamp(mapped_thr, 0.0, 1.0)

				if abs(mapped_thr - _last_joy_throttle_val) > 0.05:
					current_throttle = mapped_thr
					_last_joy_throttle_val = mapped_thr

					var detent: float = float(get_value("ab_detent", 0.95))
					if detent > 0.0:
						_afterburner_lit = (current_throttle >= detent)
					elif current_throttle < 1.0:
						_afterburner_lit = false

	# --- 4. Continuous Keyboard Throttle ---
	var kb_thr_rate: float = float(get_value("kb_throttle_rate", 0.5))
	if _action_held.get("throttle_up", false):
		current_throttle = clamp(current_throttle + kb_thr_rate * delta, 0.0, 1.0)
	if _action_held.get("throttle_down", false):
		current_throttle = clamp(current_throttle - kb_thr_rate * delta, 0.0, 1.0)
		if current_throttle < 1.0:
			_afterburner_lit = false

	# --- 5. Combine Stick Inputs ---
	_last_elevator = clamp(analog_pitch + _kb_pitch, -1.0, 1.0)
	_last_aileron = clamp(analog_roll + _kb_roll, -1.0, 1.0)
	_last_rudder = clamp(analog_rudder + _kb_rudder, -1.0, 1.0)

	# Send flight inputs to YSFlight C++ engine
	ysflight_sim.set_player_flight_inputs(
		_last_elevator,
		_last_aileron,
		_last_rudder,
		_actual_throttle,
		actual_ab,
		current_trim
	)

	# --- 6. Weapon Inputs ---
	var fire_weapon_held: bool = _action_held.get("fire_weapon", false)
	var fire_weapon_jp: bool = _action_just_pressed.get("fire_weapon", false)
	var fire_gun_held: bool = _action_held.get("fire_gun", false)
	var cycle_wpn_jp: bool = _action_just_pressed.get("cycle_weapon", false)
	var flare_jp: bool = _action_just_pressed.get("flare", false)

	ysflight_sim.set_player_weapon_inputs(
		fire_weapon_held,
		fire_weapon_jp,
		fire_gun_held,
		cycle_wpn_jp,
		flare_jp
	)

	# Clear edge triggers after physics tick consumption
	_action_just_pressed.clear()
