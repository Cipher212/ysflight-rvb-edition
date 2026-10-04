extends Node

# Day/night atmosphere cycle controller for offline RvB events and free flight.
# Coordinates sky gradient, horizon/depth fog, directional sun (rotation, colour, energy),
# explicit ambient fill, and daylight strength for dependent shaders (water, shadows, glare).
#
# Clock contract:
# - set_time_of_day(hours: float) is deterministic: reapplying the same time does no work.
# - STATIC mode: locked to daylight (STATIC_HOUR); default outside event mode.
# - DYNAMIC mode: derives progress from event elapsed time (EventSession state_updated).
#   Progresses from 06:00 (dawn) to 22:00 (night) over a nominal 60-minute reference match.
#   Shorter matches (e.g. 10-15 min) progress at the same rate, avoiding premature sunset.

const START_HOUR := 6.0              # 06:00 dawn
const STATIC_HOUR := 12.0            # 12:00 fixed daylight
const END_HOUR := 22.0               # 22:00 full night
const REFERENCE_DURATION_S := 3600.0 # 60-min nominal RvB match duration for the full cycle
const UPDATE_INTERVAL_S := 1.0       # 1 Hz update cadence: saves GPU/CPU uniform bandwidth

# Tunable artistic defaults (PS2 Ace Combat / restrained Pacific-island style):
const KEYFRAMES := [
	{
		"hour": 6.0, # Dawn: muted blue/lilac with a restrained warm horizon
		"sky_top": Color(0.28, 0.35, 0.52),
		"haze": Color(0.62, 0.52, 0.50),
		"sun_color": Color(1.0, 0.88, 0.72),
		"sun_energy": 0.60,
		"sun_pitch_deg": -8.0,
		"sun_yaw_deg": 75.0,
		"ambient_color": Color(0.42, 0.40, 0.48),
		"ambient_energy": 0.55,
		"daylight_strength": 0.60,
	},
	{
		"hour": 8.5, # Morning transition
		"sky_top": Color(0.28, 0.44, 0.68),
		"haze": Color(0.58, 0.63, 0.68),
		"sun_color": Color(1.0, 0.94, 0.84),
		"sun_energy": 0.80,
		"sun_pitch_deg": -25.0,
		"sun_yaw_deg": 55.0,
		"ambient_color": Color(0.48, 0.50, 0.54),
		"ambient_energy": 0.62,
		"daylight_strength": 0.90,
	},
	{
		"hour": 12.0, # Daylight: subdued blue overhead and pale blue-grey horizon
		"sky_top": Color(0.26, 0.44, 0.68),
		"haze": Color(0.52, 0.64, 0.72),
		"sun_color": Color(1.0, 0.96, 0.88),
		"sun_energy": 0.85,
		"sun_pitch_deg": -45.0,
		"sun_yaw_deg": 35.0,
		"ambient_color": Color(0.52, 0.54, 0.56),
		"ambient_energy": 0.65,
		"daylight_strength": 1.0,
	},
	{
		"hour": 16.0, # Late afternoon
		"sky_top": Color(0.24, 0.40, 0.64),
		"haze": Color(0.56, 0.60, 0.66),
		"sun_color": Color(1.0, 0.92, 0.80),
		"sun_energy": 0.80,
		"sun_pitch_deg": -30.0,
		"sun_yaw_deg": -20.0,
		"ambient_color": Color(0.50, 0.50, 0.52),
		"ambient_energy": 0.60,
		"daylight_strength": 0.95,
	},
	{
		"hour": 18.5, # Sunset: blue overhead and dusty peach horizon
		"sky_top": Color(0.20, 0.28, 0.48),
		"haze": Color(0.64, 0.46, 0.38),
		"sun_color": Color(1.0, 0.75, 0.50),
		"sun_energy": 0.50,
		"sun_pitch_deg": -6.0,
		"sun_yaw_deg": -70.0,
		"ambient_color": Color(0.38, 0.34, 0.38),
		"ambient_energy": 0.50,
		"daylight_strength": 0.50,
	},
	{
		"hour": 19.75, # Dusk / Twilight
		"sky_top": Color(0.12, 0.16, 0.30),
		"haze": Color(0.28, 0.22, 0.28),
		"sun_color": Color(0.85, 0.45, 0.25),
		"sun_energy": 0.15,
		"sun_pitch_deg": -1.0,
		"sun_yaw_deg": -80.0,
		"ambient_color": Color(0.25, 0.24, 0.30),
		"ambient_energy": 0.38,
		"daylight_strength": 0.15,
	},
	{
		"hour": 22.0, # Night: dark navy, with enough ambient fill to see aircraft/runways
		"sky_top": Color(0.06, 0.09, 0.16),
		"haze": Color(0.10, 0.14, 0.22),
		"sun_color": Color(0.60, 0.70, 0.88),
		"sun_energy": 0.08,
		"sun_pitch_deg": -50.0,
		"sun_yaw_deg": -80.0,
		"ambient_color": Color(0.32, 0.38, 0.50),
		"ambient_energy": 0.75,
		"daylight_strength": 0.0,
	},
]

var _sky_env: Node = null
var _sun: DirectionalLight3D = null
var _sun_glare: Node = null
var _time_mode: String = "STATIC"
var _last_applied_hour: float = -999.0
var _last_update_msec: int = -999999
var _force_next: bool = false
var _event_session: Node = null

func setup(sky_env: Node, sun: DirectionalLight3D, sun_glare: Node, time_mode: String = "STATIC") -> void:
	_sky_env = sky_env
	_sun = sun
	_sun_glare = sun_glare
	_time_mode = time_mode.to_upper()
	_force_next = true
	if _time_mode == "DYNAMIC":
		set_time_of_day(START_HOUR)
	else:
		set_time_of_day(STATIC_HOUR)

func bind_event_session(session: Node) -> void:
	_event_session = session
	if _event_session != null and _event_session.has_signal("state_updated"):
		_event_session.state_updated.connect(_on_event_state)

func _on_event_state(state: Dictionary) -> void:
	if _time_mode != "DYNAMIC":
		return
	var now := Time.get_ticks_msec()
	if now - _last_update_msec < int(UPDATE_INTERVAL_S * 1000.0):
		return
	_last_update_msec = now

	# Handle missing or invalid state gracefully
	if state.is_empty():
		return
	var elapsed := float(state.get("elapsed", 0.0))
	var progress := clampf(elapsed / REFERENCE_DURATION_S, 0.0, 1.0)
	var hours := lerpf(START_HOUR, END_HOUR, progress)
	set_time_of_day(hours)

func set_time_of_day(hours: float) -> void:
	hours = clampf(hours, START_HOUR, END_HOUR)
	if not _force_next and absf(hours - _last_applied_hour) < 0.001:
		return
	_force_next = false
	_last_applied_hour = hours

	var p: Dictionary = evaluate_palette(hours)
	_apply_palette(p)

func get_time_of_day() -> float:
	return _last_applied_hour

func get_time_mode() -> String:
	return _time_mode

static func evaluate_palette(hours: float) -> Dictionary:
	if hours <= float(KEYFRAMES[0]["hour"]):
		return KEYFRAMES[0].duplicate()
	if hours >= float(KEYFRAMES[KEYFRAMES.size() - 1]["hour"]):
		return KEYFRAMES[KEYFRAMES.size() - 1].duplicate()

	for i in KEYFRAMES.size() - 1:
		var k0: Dictionary = KEYFRAMES[i]
		var k1: Dictionary = KEYFRAMES[i + 1]
		var h0 := float(k0["hour"])
		var h1 := float(k1["hour"])
		if hours >= h0 and hours <= h1:
			var t := (hours - h0) / maxf(h1 - h0, 0.0001)
			return {
				"hour": hours,
				"sky_top": (k0["sky_top"] as Color).lerp(k1["sky_top"] as Color, t),
				"haze": (k0["haze"] as Color).lerp(k1["haze"] as Color, t),
				"sun_color": (k0["sun_color"] as Color).lerp(k1["sun_color"] as Color, t),
				"sun_energy": lerpf(float(k0["sun_energy"]), float(k1["sun_energy"]), t),
				"sun_pitch_deg": lerpf(float(k0["sun_pitch_deg"]), float(k1["sun_pitch_deg"]), t),
				"sun_yaw_deg": lerpf(float(k0["sun_yaw_deg"]), float(k1["sun_yaw_deg"]), t),
				"ambient_color": (k0["ambient_color"] as Color).lerp(k1["ambient_color"] as Color, t),
				"ambient_energy": lerpf(float(k0["ambient_energy"]), float(k1["ambient_energy"]), t),
				"daylight_strength": lerpf(float(k0["daylight_strength"]), float(k1["daylight_strength"]), t),
			}
	return KEYFRAMES[0].duplicate()

func _apply_palette(p: Dictionary) -> void:
	if _sun != null:
		_sun.rotation_degrees = Vector3(p["sun_pitch_deg"], p["sun_yaw_deg"], 0.0)
		_sun.light_color = p["sun_color"]
		_sun.light_energy = p["sun_energy"]
		var to_sun: Vector3 = (_sun.global_basis.z if _sun.is_inside_tree() else _sun.basis.z).normalized()
		RenderingServer.global_shader_parameter_set("sun_direction", to_sun)
		if _sun_glare != null and _sun_glare.has_method("set_sun"):
			_sun_glare.set_sun(to_sun, p["daylight_strength"])

	var haze: Color = p["haze"]
	var haze_linear: Color = haze.srgb_to_linear()
	RenderingServer.global_shader_parameter_set("sky_haze", Vector3(haze_linear.r, haze_linear.g, haze_linear.b))
	RenderingServer.global_shader_parameter_set("daylight_strength", p["daylight_strength"])

	if _sky_env != null and _sky_env.has_method("apply_atmosphere"):
		_sky_env.apply_atmosphere(p["sky_top"], haze, p["ambient_color"], p["ambient_energy"])
