extends Node
class_name Controls

# ==============================================================================
# YSFlight Godot Port - Controls Subsystem
# ==============================================================================
# Handles all player flight inputs, response curves, device management (Mouse-as-stick,
# Gamepad, Joystick/HOTAS, Keyboard), weapon triggers, YSFlight button events, and view controls.
# Owns user://controls.cfg as the single source of truth for controls settings.
# ==============================================================================

signal changed(key: String)

const CONFIG_PATH: String = "user://controls.cfg"

# Single source of truth for all controls settings.
const SETTINGS: Array[Dictionary] = [
	# --- Stick Device ---
	{
		"key": "stick_device",
		"label": "Flight Stick Device",
		"section": "Stick Device",
		"type": "enum",
		"default": "Auto",
		"options": ["Auto", "Mouse", "Gamepad", "Joystick", "Keyboard"]
	},

	# --- Mouse ---
	{
		"key": "mouse_deadzone",
		"label": "Mouse Deadzone",
		"section": "Mouse",
		"type": "float",
		"default": 0.03,
		"min": 0.0,
		"max": 0.3,
		"step": 0.01
	},
	{
		"key": "mouse_expo",
		"label": "Mouse Expo (Curvature)",
		"section": "Mouse",
		"type": "float",
		"default": 0.3,
		"min": 0.0,
		"max": 1.0,
		"step": 0.05
	},
	{
		"key": "mouse_sensitivity",
		"label": "Mouse Sensitivity",
		"section": "Mouse",
		"type": "float",
		"default": 1.0,
		"min": 0.3,
		"max": 2.0,
		"step": 0.05
	},
	{
		"key": "mouse_invert_pitch",
		"label": "Invert Mouse Pitch",
		"section": "Mouse",
		"type": "bool",
		"default": false
	},
	{
		"key": "mouse_wheel_throttle",
		"label": "Mouse Wheel Throttle",
		"section": "Mouse",
		"type": "bool",
		"default": true
	},
	{
		"key": "show_stick_indicator",
		"label": "Show Mouse Stick Indicator",
		"section": "Mouse",
		"type": "bool",
		"default": true
	},

	# --- Gamepad ---
	{
		"key": "pad_deadzone",
		"label": "Gamepad Deadzone",
		"section": "Gamepad",
		"type": "float",
		"default": 0.1,
		"min": 0.0,
		"max": 0.4,
		"step": 0.01
	},
	{
		"key": "pad_expo",
		"label": "Gamepad Expo",
		"section": "Gamepad",
		"type": "float",
		"default": 0.4,
		"min": 0.0,
		"max": 1.0,
		"step": 0.05
	},
	{
		"key": "pad_sensitivity",
		"label": "Gamepad Sensitivity",
		"section": "Gamepad",
		"type": "float",
		"default": 1.0,
		"min": 0.3,
		"max": 2.0,
		"step": 0.05
	},
	{
		"key": "pad_invert_pitch",
		"label": "Invert Gamepad Pitch",
		"section": "Gamepad",
		"type": "bool",
		"default": false
	},
	{
		"key": "pad_throttle_rate",
		"label": "Trigger Throttle Rate /s",
		"section": "Gamepad",
		"type": "float",
		"default": 0.6,
		"min": 0.1,
		"max": 2.0,
		"step": 0.05
	},

	# --- Joystick / HOTAS ---
	{
		"key": "joy_deadzone",
		"label": "Joystick Deadzone",
		"section": "Joystick / HOTAS",
		"type": "float",
		"default": 0.05,
		"min": 0.0,
		"max": 0.3,
		"step": 0.01
	},
	{
		"key": "joy_expo",
		"label": "Joystick Expo",
		"section": "Joystick / HOTAS",
		"type": "float",
		"default": 0.2,
		"min": 0.0,
		"max": 1.0,
		"step": 0.05
	},
	{
		"key": "joy_sensitivity",
		"label": "Joystick Sensitivity",
		"section": "Joystick / HOTAS",
		"type": "float",
		"default": 1.0,
		"min": 0.3,
		"max": 2.0,
		"step": 0.05
	},
	{
		"key": "joy_invert_pitch",
		"label": "Invert Joystick Pitch",
		"section": "Joystick / HOTAS",
		"type": "bool",
		"default": false
	},
	{
		"key": "joy_roll_axis",
		"label": "Roll Axis",
		"section": "Joystick / HOTAS",
		"type": "enum",
		"default": "Axis 0",
		"options": ["Axis 0", "Axis 1", "Axis 2", "Axis 3", "Axis 4", "Axis 5", "Axis 6", "Axis 7"]
	},
	{
		"key": "joy_pitch_axis",
		"label": "Pitch Axis",
		"section": "Joystick / HOTAS",
		"type": "enum",
		"default": "Axis 1",
		"options": ["Axis 0", "Axis 1", "Axis 2", "Axis 3", "Axis 4", "Axis 5", "Axis 6", "Axis 7"]
	},
	{
		"key": "joy_rudder_axis",
		"label": "Rudder Axis",
		"section": "Joystick / HOTAS",
		"type": "enum",
		"default": "None",
		"options": ["None", "Axis 0", "Axis 1", "Axis 2", "Axis 3", "Axis 4", "Axis 5", "Axis 6", "Axis 7"]
	},
	{
		"key": "joy_throttle_axis",
		"label": "Throttle Axis",
		"section": "Joystick / HOTAS",
		"type": "enum",
		"default": "Axis 2",
		"options": ["None", "Axis 0", "Axis 1", "Axis 2", "Axis 3", "Axis 4", "Axis 5", "Axis 6", "Axis 7"]
	},
	{
		"key": "joy_throttle_invert",
		"label": "Invert Throttle Axis",
		"section": "Joystick / HOTAS",
		"type": "bool",
		"default": true
	},
	{
		"key": "joy_rudder_invert",
		"label": "Invert Rudder Axis",
		"section": "Joystick / HOTAS",
		"type": "bool",
		"default": false
	},

	# --- Keyboard Stick ---
	{
		"key": "kb_stick_rate",
		"label": "Keyboard Stick Rate /s",
		"section": "Keyboard Stick",
		"type": "float",
		"default": 3.0,
		"min": 0.5,
		"max": 10.0,
		"step": 0.1
	},
	{
		"key": "kb_return_rate",
		"label": "Keyboard Return Rate /s",
		"section": "Keyboard Stick",
		"type": "float",
		"default": 4.0,
		"min": 0.5,
		"max": 10.0,
		"step": 0.1
	},
	{
		"key": "kb_max_travel",
		"label": "Keyboard Max Travel",
		"section": "Keyboard Stick",
		"type": "float",
		"default": 1.0,
		"min": 0.3,
		"max": 1.0,
		"step": 0.05
	},

	# --- Throttle / Afterburner ---
	{
		"key": "kb_throttle_rate",
		"label": "Keyboard Throttle Rate /s",
		"section": "Throttle / Afterburner",
		"type": "float",
		"default": 0.5,
		"min": 0.1,
		"max": 2.0,
		"step": 0.05
	},
	{
		"key": "ab_detent",
		"label": "Afterburner Detent Threshold",
		"section": "Throttle / Afterburner",
		"type": "float",
		"default": 0.95,
		"min": 0.0,
		"max": 1.0,
		"step": 0.01
	},

	# --- Hold vs Toggle ---
	{
		"key": "brake_mode",
		"label": "Wheel Brakes Mode",
		"section": "Hold vs Toggle",
		"type": "enum",
		"default": "Toggle",
		"options": ["Toggle", "Hold"]
	},
	{
		"key": "spoiler_mode",
		"label": "Airbrake / Spoiler Mode",
		"section": "Hold vs Toggle",
		"type": "enum",
		"default": "Toggle",
		"options": ["Toggle", "Hold"]
	},

	# --- Display ---
	{
		"key": "show_input_overlay",
		"label": "Show Input Overlay",
		"section": "Display",
		"type": "bool",
		"default": false
	},

	# --- Graphics ---
	{
		"key": "graphics_preset",
		"label": "Graphics Preset",
		"section": "Graphics",
		"type": "enum",
		"default": "Medium",
		"options": ["Low", "Medium", "High", "Custom"]
	},
	{
		"key": "render_scale",
		"label": "3D Render Scale",
		"section": "Graphics",
		"type": "float",
		"default": 1.0,
		"min": 0.5,
		"max": 1.0,
		"step": 0.05
	},
	{
		"key": "vsync",
		"label": "V-Sync",
		"section": "Graphics",
		"type": "bool",
		"default": true
	},
	{
		"key": "msaa",
		"label": "MSAA 3D",
		"section": "Graphics",
		"type": "enum",
		"default": "Off",
		"options": ["Off", "2x", "4x", "8x"]
	},
	{
		"key": "fxaa",
		"label": "FXAA",
		"section": "Graphics",
		"type": "bool",
		"default": false
	},
	{
		"key": "draw_distance_km",
		"label": "Draw Distance (km)",
		"section": "Graphics",
		"type": "float",
		"default": 80.0,
		"min": 20.0,
		"max": 120.0,
		"step": 5.0
	},
	{
		"key": "fx_density",
		"label": "FX Density",
		"section": "Graphics",
		"type": "enum",
		"default": "Medium",
		"options": ["Low", "Medium", "High"]
	},

	# --- HUD ---
	{
		"key": "hud_color",
		"label": "HUD Color",
		"section": "HUD",
		"type": "enum",
		"default": "Green",
		"options": ["Green", "Amber", "Cyan", "White"]
	},
	{
		"key": "hud_scale",
		"label": "HUD Scale",
		"section": "HUD",
		"type": "float",
		"default": 1.0,
		"min": 0.7,
		"max": 1.4,
		"step": 0.05
	},
	{
		"key": "show_debug_text",
		"label": "Show Debug / Perf Text",
		"section": "HUD",
		"type": "bool",
		"default": false
	},

	# --- Radar ---
	{
		"key": "radar_size",
		"label": "Radar Size",
		"section": "Radar",
		"type": "float",
		"default": 1.0,
		"min": 0.7,
		"max": 1.5,
		"step": 0.05
	},
	{
		"key": "radar_show_ground",
		"label": "Show Ground Targets",
		"section": "Radar",
		"type": "bool",
		"default": true
	},
	{
		"key": "radar_threat_arrows",
		"label": "Threat Arrows",
		"section": "Radar",
		"type": "bool",
		"default": true
	},

	# --- Bindings ---
	{ "key": "pitch_up", "label": "Pitch Up", "section": "Bindings", "type": "binding", "default": "key:Down", "default2": "" },
	{ "key": "pitch_down", "label": "Pitch Down", "section": "Bindings", "type": "binding", "default": "key:Up", "default2": "" },
	{ "key": "roll_left", "label": "Roll Left", "section": "Bindings", "type": "binding", "default": "key:Left", "default2": "" },
	{ "key": "roll_right", "label": "Roll Right", "section": "Bindings", "type": "binding", "default": "key:Right", "default2": "" },
	{ "key": "rudder_left", "label": "Rudder Left", "section": "Bindings", "type": "binding", "default": "key:Z", "default2": "joy_button:9" },
	{ "key": "rudder_center", "label": "Rudder Center", "section": "Bindings", "type": "binding", "default": "key:X", "default2": "" },
	{ "key": "rudder_right", "label": "Rudder Right", "section": "Bindings", "type": "binding", "default": "key:C", "default2": "joy_button:10" },

	{ "key": "throttle_up", "label": "Throttle Up", "section": "Bindings", "type": "binding", "default": "key:Q", "default2": "" },
	{ "key": "throttle_down", "label": "Throttle Down", "section": "Bindings", "type": "binding", "default": "key:A", "default2": "" },
	{ "key": "throttle_max", "label": "Throttle 100% + AB", "section": "Bindings", "type": "binding", "default": "key:W", "default2": "" },
	{ "key": "throttle_idle", "label": "Throttle Idle", "section": "Bindings", "type": "binding", "default": "key:S", "default2": "" },
	{ "key": "afterburner", "label": "Toggle Afterburner", "section": "Bindings", "type": "binding", "default": "key:Tab", "default2": "joy_button:7" },

	{ "key": "trim_up", "label": "Elevator Trim Up", "section": "Bindings", "type": "binding", "default": "key:Delete", "default2": "" },
	{ "key": "trim_down", "label": "Elevator Trim Down", "section": "Bindings", "type": "binding", "default": "key:Insert", "default2": "" },
	{ "key": "auto_trim", "label": "Auto Trim", "section": "Bindings", "type": "binding", "default": "key:T", "default2": "" },

	{ "key": "gear", "label": "Landing Gear", "section": "Bindings", "type": "binding", "default": "key:G", "default2": "joy_button:11" },
	{ "key": "flaps_up", "label": "Flaps Up", "section": "Bindings", "type": "binding", "default": "key:R", "default2": "joy_button:14" },
	{ "key": "flaps_down", "label": "Flaps Down", "section": "Bindings", "type": "binding", "default": "key:F", "default2": "joy_button:12" },
	{ "key": "brake", "label": "Wheel Brakes", "section": "Bindings", "type": "binding", "default": "key:B", "default2": "" },
	{ "key": "spoiler", "label": "Airbrake / Spoiler", "section": "Bindings", "type": "binding", "default": "key:D", "default2": "joy_button:13" },

	{ "key": "fire_weapon", "label": "Fire Selected Weapon", "section": "Bindings", "type": "binding", "default": "key:Space", "default2": "mouse:2", "default3": "joy_button:0", "slots": 3 },
	{ "key": "fire_gun", "label": "Fire Gun", "section": "Bindings", "type": "binding", "default": "key:Ctrl", "default2": "mouse:1", "default3": "joy_button:2", "slots": 3 },
	{ "key": "cycle_weapon", "label": "Cycle Weapon", "section": "Bindings", "type": "binding", "default": "key:2", "default2": "mouse:3", "default3": "joy_button:3", "slots": 3 },
	{ "key": "flare", "label": "Dispense Flare", "section": "Bindings", "type": "binding", "default": "key:4", "default2": "joy_button:1" },
	{ "key": "radar", "label": "Toggle Radar", "section": "Bindings", "type": "binding", "default": "key:3", "default2": "" },
	{ "key": "bomb_bay", "label": "Bomb Bay Door", "section": "Bindings", "type": "binding", "default": "key:1", "default2": "" },

	{ "key": "select_gun", "label": "Select Gun", "section": "Bindings", "type": "binding", "default": "key:5", "default2": "" },
	{ "key": "select_short_range_missile", "label": "Select Short-Range Missile", "section": "Bindings", "type": "binding", "default": "key:6", "default2": "" },
	{ "key": "select_long_range_missile", "label": "Select Long-Range Missile", "section": "Bindings", "type": "binding", "default": "key:7", "default2": "" },
	{ "key": "select_air_to_ground", "label": "Select Air-to-Ground Missile", "section": "Bindings", "type": "binding", "default": "key:8", "default2": "" },
	{ "key": "select_bombs_rockets", "label": "Select Bombs / Rockets", "section": "Bindings", "type": "binding", "default": "key:0", "default2": "" },

	{ "key": "cycle_hud_color", "label": "Cycle HUD Color", "section": "Bindings", "type": "binding", "default": "key:9", "default2": "" },
	{ "key": "toggle_debug_text", "label": "Toggle Debug Text", "section": "Bindings", "type": "binding", "default": "key:F11", "default2": "" },

	{ "key": "view_cockpit", "label": "Cockpit View", "section": "Bindings", "type": "binding", "default": "key:F1", "default2": "" },
	{ "key": "view_exterior", "label": "Exterior View", "section": "Bindings", "type": "binding", "default": "key:F2", "default2": "joy_button:4" },

	{ "key": "look_forward", "label": "Look Forward", "section": "Bindings", "type": "binding", "default": "key:U", "default2": "" },
	{ "key": "look_left", "label": "Look Left", "section": "Bindings", "type": "binding", "default": "key:H", "default2": "" },
	{ "key": "look_right", "label": "Look Right", "section": "Bindings", "type": "binding", "default": "key:K", "default2": "" },
	{ "key": "look_back", "label": "Look Back", "section": "Bindings", "type": "binding", "default": "key:M", "default2": "" },
	{ "key": "look_up", "label": "Look Up", "section": "Bindings", "type": "binding", "default": "key:J", "default2": "" },
	{ "key": "look_down", "label": "Look Down", "section": "Bindings", "type": "binding", "default": "key:N", "default2": "" },

	{ "key": "zoom_in", "label": "Zoom In", "section": "Bindings", "type": "binding", "default": "key:Equal", "default2": "" },
	{ "key": "zoom_out", "label": "Zoom Out", "section": "Bindings", "type": "binding", "default": "key:Minus", "default2": "" },

	{ "key": "recenter_mouse_stick", "label": "Recenter Mouse Stick", "section": "Bindings", "type": "binding", "default": "key:O", "default2": "" },
	{ "key": "toggle_mouse_stick", "label": "Toggle Mouse Stick", "section": "Bindings", "type": "binding", "default": "key:Y", "default2": "" },

	{ "key": "pause", "label": "Pause Simulation", "section": "Bindings", "type": "binding", "default": "key:P", "default2": "" },
	{ "key": "open_settings", "label": "Controls Settings", "section": "Bindings", "type": "binding", "default": "key:Escape", "default2": "joy_button:6" }
]

var main: Node = null
var ysflight_sim: YSFlightSimulation = null
var settings_panel: CanvasLayer = null

var _config: ConfigFile = ConfigFile.new()
var _values: Dictionary = {}
var _binding_to_actions: Dictionary = {}

# Active device tracking
var _active_stick_device: String = "Keyboard"
var _mouse_stick_enabled: bool = true
var _last_joy_device: int = 0
var _last_joy_throttle_val: float = -999.0

# Continuous state
var current_throttle: float = 0.85
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

func _on_action_pressed(action: String) -> void:
	# Menu & Pause work even during spectator/ai mode or pause
	if action == "open_settings":
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
			if main != null and main.has_method("_set_camera_mode"):
				main._set_camera_mode(1, main.cam_mode == 1)
		"view_exterior":
			if main != null and main.has_method("_set_camera_mode"):
				main._set_camera_mode(2, main.cam_mode == 2)
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

func toggle_settings() -> void:
	if settings_panel == null:
		return
	if settings_panel.visible:
		settings_panel.visible = false
		if not _paused_before_settings:
			get_tree().paused = false
	else:
		_paused_before_settings = get_tree().paused
		get_tree().paused = true
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
			current_throttle,
			_afterburner_lit,
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
			if _mouse_stick_enabled:
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
		current_throttle,
		_afterburner_lit,
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

# ------------------------------------------------------------------------------
# Process (Head Look, Chase Camera Orbit & Zoom)
# ------------------------------------------------------------------------------
func _process(delta: float) -> void:
	if main == null or main.get("ai_player_mode") == true:
		return

	var cam_mode: int = int(main.get("cam_mode"))

	# --- Zoom Controls ---
	if _action_held.get("zoom_in", false):
		if cam_mode == 1: # COCKPIT
			main.cockpit_fov = clamp(main.cockpit_fov - 40.0 * delta, 20.0, 100.0)
		else:
			main.cam_distance = max(3.5, main.cam_distance * (1.0 - 0.8 * delta))
	if _action_held.get("zoom_out", false):
		if cam_mode == 1: # COCKPIT
			main.cockpit_fov = clamp(main.cockpit_fov + 40.0 * delta, 20.0, 100.0)
		else:
			main.cam_distance = min(2000.0, main.cam_distance * (1.0 + 0.8 * delta))

	# --- Head Look (Cockpit) / Chase Cam Orbit (Exterior) ---
	var joy_id: int = _last_joy_device
	var rx: float = Input.get_joy_axis(joy_id, JOY_AXIS_RIGHT_X)
	var ry: float = Input.get_joy_axis(joy_id, JOY_AXIS_RIGHT_Y)
	if abs(rx) < 0.15: rx = 0.0
	if abs(ry) < 0.15: ry = 0.0

	# Joystick POV Hat (Buttons 11-14 when Joystick)
	if get_active_stick_device_name() == "Joystick":
		if Input.is_joy_button_pressed(joy_id, JOY_BUTTON_DPAD_UP): ry = -1.0
		elif Input.is_joy_button_pressed(joy_id, JOY_BUTTON_DPAD_DOWN): ry = 1.0
		if Input.is_joy_button_pressed(joy_id, JOY_BUTTON_DPAD_LEFT): rx = -1.0
		elif Input.is_joy_button_pressed(joy_id, JOY_BUTTON_DPAD_RIGHT): rx = 1.0

	if cam_mode == 1: # COCKPIT VIEW: Free Look
		var target_yaw: float = 0.0
		var target_pitch: float = 0.0
		var look_active: bool = false

		if _action_held.get("look_back", false):
			target_yaw = 2.967 # ~170 degrees
			look_active = true
		elif _action_held.get("look_left", false):
			target_yaw = 1.571 # +90 degrees
			look_active = true
		elif _action_held.get("look_right", false):
			target_yaw = -1.571 # -90 degrees
			look_active = true

		if _action_held.get("look_up", false):
			target_pitch = 1.047 # +60 degrees
			look_active = true
		elif _action_held.get("look_down", false):
			target_pitch = -0.524 # -30 degrees
			look_active = true

		if _action_held.get("look_forward", false):
			target_yaw = 0.0
			target_pitch = 0.0
			look_active = true

		if abs(rx) > 0.01 or abs(ry) > 0.01:
			target_yaw = -rx * 1.571
			target_pitch = -ry * (1.047 if ry < 0.0 else 0.524)
			look_active = true

		if look_active:
			main.head_yaw = move_toward(main.head_yaw, target_yaw, 5.0 * delta)
			main.head_pitch = move_toward(main.head_pitch, target_pitch, 4.0 * delta)
		else:
			main.head_yaw = move_toward(main.head_yaw, 0.0, 4.5 * delta)
			main.head_pitch = move_toward(main.head_pitch, 0.0, 4.0 * delta)

	elif cam_mode == 2: # HORIZON CHASE: Orbit
		if _action_held.get("look_left", false):
			main.cam_yaw += 2.0 * delta
		if _action_held.get("look_right", false):
			main.cam_yaw -= 2.0 * delta
		if _action_held.get("look_up", false):
			main.cam_pitch = clamp(main.cam_pitch + 1.5 * delta, -1.45, 1.45)
		if _action_held.get("look_down", false):
			main.cam_pitch = clamp(main.cam_pitch - 1.5 * delta, -1.45, 1.45)
		if _action_held.get("look_forward", false):
			main.cam_yaw = 0.0
			main.cam_pitch = -0.18
		if _action_held.get("look_back", false):
			main.cam_yaw = PI

		if abs(rx) > 0.01:
			main.cam_yaw -= rx * 2.5 * delta
		if abs(ry) > 0.01:
			main.cam_pitch = clamp(main.cam_pitch - ry * 2.0 * delta, -1.45, 1.45)
