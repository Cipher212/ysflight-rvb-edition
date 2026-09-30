extends RefCounted

# Every player setting (controls, graphics, HUD, radar, key bindings): key, label, settings-panel section,
# type and default. The single source of truth: controls.gd loads/saves user://controls.cfg from it and
# settings_panel.gd builds its rows from it. Binding strings: "key:<name>", "mouse:<button>",
# "joy_button:<index>"; "slots": 3 allows a third binding.

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
		"key": "cockpit_head_movement",
		"label": "Head Moves Under G (Cockpit)",
		"section": "Display",
		"type": "bool",
		"default": true
	},
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
	# Effects for stronger PCs: on in the Medium and High presets, off in Low (graphics_settings.gd).
	{
		"key": "aircraft_shadows",
		"label": "Aircraft Shadows",
		"section": "Graphics",
		"type": "bool",
		"default": true
	},
	{
		"key": "cloud_shadows",
		"label": "Cloud Shadows",
		"section": "Graphics",
		"type": "bool",
		"default": true
	},
	{
		"key": "water_shine",
		"label": "Water Shine",
		"section": "Graphics",
		"type": "bool",
		"default": true
	},
	{
		"key": "heat_haze",
		"label": "Afterburner Heat Haze",
		"section": "Graphics",
		"type": "bool",
		"default": true
	},
	{
		"key": "lens_glare",
		"label": "Sun & Explosion Glare",
		"section": "Graphics",
		"type": "bool",
		"default": true
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
		"key": "show_fps_monitor",
		"label": "Show FPS / Latency",
		"section": "HUD",
		"type": "bool",
		"default": true
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
