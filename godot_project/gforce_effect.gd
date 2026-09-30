extends CanvasLayer

# G effects: blackout (positive G) and redout (negative G) as a plain full-screen colour whose opacity
# follows the G load, drawn only in the cockpit view (F1). G-LOC (pilot unconscious, controls to neutral for
# GLOC_DURATION, see controls.gd is_gloc()) still happens in every view: it is the pilot, not the camera.
#   Blackout: starts at +9 G, full black at +11 G (full black = G-LOC).  Redout: starts at -3 G, full at -5 G.
# Cost: one ColorRect, hidden when nothing is shown (no shader, no screen copy).

const G_BLACKOUT_START: float = 9.0
const G_BLACKOUT_FULL: float = 11.0
const G_REDOUT_START: float = 3.0 # magnitude of negative G
const G_REDOUT_FULL: float = 5.0
const GLOC_DURATION: float = 2.5
const RISE_RATE: float = 1.0 # per second
const FALL_RATE: float = 2.0
const BLACK := Color(0.0, 0.0, 0.0)
const RED := Color(0.6, 0.0, 0.0)

var blackout: float = 0.0
var redout: float = 0.0

var _gloc_timer: float = 0.0
var _gloc_active: bool = false
var _gloc_can_trigger: bool = true
var _rect := ColorRect.new()

func _ready() -> void:
	layer = 15
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.visible = false
	add_child(_rect)

func is_gloc() -> bool:
	return _gloc_active

func update_effect(delta: float, g: float, is_alive: bool, is_ai: bool, is_paused: bool, is_cockpit: bool) -> void:
	if not is_alive or is_ai:
		blackout = 0.0
		redout = 0.0
		_gloc_timer = 0.0
		_gloc_active = false
		_gloc_can_trigger = true
		_rect.visible = false
		return
	if not is_paused:
		_step(delta, g)
	var shown: bool = is_cockpit and (blackout > 0.001 or redout > 0.001)
	_rect.visible = shown
	if shown:
		var c: Color = BLACK if blackout >= redout else RED
		c.a = maxf(blackout, redout)
		_rect.color = c

func _step(delta: float, g: float) -> void:
	var target_black: float = clampf((g - G_BLACKOUT_START) / (G_BLACKOUT_FULL - G_BLACKOUT_START), 0.0, 1.0)
	var target_red: float = clampf((-g - G_REDOUT_START) / (G_REDOUT_FULL - G_REDOUT_START), 0.0, 1.0)
	if _gloc_active:
		_gloc_timer -= delta
		blackout = 1.0
		if _gloc_timer <= 0.0:
			_gloc_active = false
	elif target_black > blackout:
		blackout = minf(1.0, blackout + RISE_RATE * delta)
		if blackout >= 1.0 and _gloc_can_trigger:
			_gloc_active = true
			_gloc_timer = GLOC_DURATION
			_gloc_can_trigger = false
	else:
		blackout = maxf(0.0, blackout - FALL_RATE * delta)
		if blackout < 0.5:
			_gloc_can_trigger = true
	if target_red > redout:
		redout = minf(1.0, redout + RISE_RATE * delta)
	else:
		redout = maxf(0.0, redout - FALL_RATE * delta)
