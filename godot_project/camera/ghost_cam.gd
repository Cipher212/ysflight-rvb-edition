extends RefCounted

# F11 ghost camera (spectator mode): a free camera flown like an aircraft, as in stock YSFlight.
# Mouse position from screen centre / joystick / arrow keys = pitch and roll (Q / E or twist = yaw);
# Space moves forward, Backspace backward; + / - (or Page Up / Page Down) change the speed.
# Setting "ghost_cam_smoothing" (0..1) sets how slowly speed and turn rate follow the input.

const BASE_SPEED_MPS := 120.0
const MIN_SPEED_MPS := 5.0
const MAX_SPEED_MPS := 3000.0
const SPEED_STEP := 1.5      # each + / - press multiplies / divides the speed
const PITCH_RATE := 1.4      # rad/s at full input
const ROLL_RATE := 2.2
const YAW_RATE := 0.9
const MOUSE_DEADZONE := 0.04 # fraction of the half screen
const STICK_DEADZONE := 0.12
const MAX_LAG_S := 1.5       # time constant at smoothing 1.0

var pos := Vector3.ZERO
var basis := Basis.IDENTITY
var speed_setting: float = BASE_SPEED_MPS
var _velocity: float = 0.0       # m/s along the view direction (negative = backward)
var _rates := Vector3.ZERO       # pitch, yaw, roll rad/s

# Start where the current camera is, looking the same way.
func start(from: Transform3D) -> void:
	pos = from.origin
	basis = from.basis.orthonormalized()
	_velocity = 0.0
	_rates = Vector3.ZERO

func rebase(delta: Vector3) -> void:
	pos -= delta

func press_key(keycode: int) -> bool:
	if keycode == KEY_EQUAL or keycode == KEY_KP_ADD or keycode == KEY_PAGEUP:
		speed_setting = minf(speed_setting * SPEED_STEP, MAX_SPEED_MPS)
		return true
	if keycode == KEY_MINUS or keycode == KEY_KP_SUBTRACT or keycode == KEY_PAGEDOWN:
		speed_setting = maxf(speed_setting / SPEED_STEP, MIN_SPEED_MPS)
		return true
	return false

func update(delta: float, viewport: Viewport, joy_id: int, smoothing: float) -> Transform3D:
	var stick := _stick_input(viewport, joy_id)
	var target_rates := Vector3(stick.y * PITCH_RATE, stick.z * YAW_RATE, stick.x * ROLL_RATE)
	var target_vel := 0.0
	if Input.is_key_pressed(KEY_SPACE):
		target_vel += speed_setting
	if Input.is_key_pressed(KEY_BACKSPACE):
		target_vel -= speed_setting
	var lag: float = clampf(smoothing, 0.0, 1.0) * MAX_LAG_S
	var k: float = 1.0 if lag < 0.001 else 1.0 - exp(-delta / lag)
	_rates += (target_rates - _rates) * k
	_velocity += (target_vel - _velocity) * k
	basis = (basis * Basis.from_euler(_rates * delta)).orthonormalized()
	pos += -basis.z * _velocity * delta
	return Transform3D(basis, pos)

func status() -> String:
	return "F11: GHOST CAM [%.0f m/s, set %.0f | Space / Backspace, + / -]" % [absf(_velocity), speed_setting]

# x = roll (+ left), y = pitch (+ nose up), z = yaw (+ left), each -1..1.
func _stick_input(viewport: Viewport, joy_id: int) -> Vector3:
	var out := Vector3.ZERO
	var size: Vector2 = viewport.get_visible_rect().size
	if size.x > 0.0 and size.y > 0.0:
		var m: Vector2 = (viewport.get_mouse_position() - size * 0.5) / (size * 0.5)
		out.x = -_dead(clampf(m.x, -1.0, 1.0), MOUSE_DEADZONE)
		out.y = _dead(clampf(m.y, -1.0, 1.0), MOUSE_DEADZONE) # mouse below centre = stick pulled = nose up
	var jx: float = _dead(Input.get_joy_axis(joy_id, JOY_AXIS_LEFT_X), STICK_DEADZONE)
	var jy: float = _dead(Input.get_joy_axis(joy_id, JOY_AXIS_LEFT_Y), STICK_DEADZONE)
	var jz: float = _dead(Input.get_joy_axis(joy_id, JOY_AXIS_RIGHT_X), STICK_DEADZONE)
	if absf(jx) > 0.0 or absf(jy) > 0.0:
		out.x = -jx
		out.y = jy
	out.z = -jz
	if Input.is_key_pressed(KEY_LEFT):
		out.x = 1.0
	elif Input.is_key_pressed(KEY_RIGHT):
		out.x = -1.0
	if Input.is_key_pressed(KEY_UP):
		out.y = -1.0
	elif Input.is_key_pressed(KEY_DOWN):
		out.y = 1.0
	if Input.is_key_pressed(KEY_Q):
		out.z = 1.0
	elif Input.is_key_pressed(KEY_E):
		out.z = -1.0
	return out

func _dead(v: float, dz: float) -> float:
	if absf(v) <= dz:
		return 0.0
	return signf(v) * (absf(v) - dz) / (1.0 - dz)
