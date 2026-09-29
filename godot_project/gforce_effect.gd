extends CanvasLayer

# ==============================================================================
# YSFlight Godot Port - G-Force Effects & G-LOC (Loss of Consciousness)
# ==============================================================================
# Simulates physiological G-tolerance effects:
#   - Blackout (positive G): Peripheral tunnel vision vignette and desaturation
#     onset at +9.0 G, full blackout at +11.0 G.
#   - G-LOC: If blackout reaches 1.0, pilot loses consciousness for 2.5 seconds.
#     Controls lock to neutral, weapon triggers suppressed.
#   - Redout (negative G): Red tunnel vision onset at -3.0 G, full redout at -5.0 G.
#
# Performance:
#   Full-screen ColorRect with a lightweight canvas_item shader.
#   Visible only when blackout or redout > 0.001 (zero overhead in normal flight).
# ==============================================================================

const G_BLACKOUT_START: float = 9.0
const G_BLACKOUT_FULL: float = 11.0
const G_REDOUT_START: float = -3.0
const G_REDOUT_FULL: float = -5.0
const GLOC_DURATION: float = 2.5
const RISE_RATE: float = 1.0
const FALL_RATE: float = 2.0

var blackout: float = 0.0
var redout: float = 0.0

var _gloc_timer: float = 0.0
var _gloc_active: bool = false
var _gloc_can_trigger: bool = true

var _rect: ColorRect = null
var _mat: ShaderMaterial = null

const SHADER_CODE: String = """shader_type canvas_item;

uniform float blackout : hint_range(0.0, 1.0) = 0.0;
uniform float redout : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec4 sc = texture(screen_texture, uv);

	vec2 centered = (uv - vec2(0.5)) * 2.0;
	float dist = length(centered);

	if (blackout > 0.001) {
		// Tunnel vision vignette: radius shrinks inward as blackout builds up
		float radius = (1.0 - blackout) * 1.5;
		float edge_soft = max(0.01, 0.45 * (1.0 - blackout * 0.7));
		float vig = smoothstep(radius, radius - edge_soft, dist);

		// Desaturate underlying colors
		float luma = dot(sc.rgb, vec3(0.299, 0.587, 0.114));
		vec3 desat = mix(sc.rgb, vec3(luma), blackout * 0.8);

		vec3 col = mix(desat, vec3(0.0), vig);
		if (blackout >= 0.999) {
			col = vec3(0.0);
		}
		COLOR = vec4(col, 1.0);
	} else if (redout > 0.001) {
		float radius = 1.4;
		float vig = smoothstep(0.2, radius, dist);
		float red_amount = mix(vig * 0.7, 1.0, redout) * redout;
		vec3 red_col = mix(sc.rgb, vec3(0.9, 0.05, 0.05), red_amount);
		if (redout >= 0.999) {
			red_col = vec3(0.8, 0.0, 0.0);
		}
		COLOR = vec4(red_col, 1.0);
	} else {
		COLOR = sc;
	}
}
"""

func _ready() -> void:
	layer = 15
	process_mode = Node.PROCESS_MODE_ALWAYS

	var shader := Shader.new()
	shader.code = SHADER_CODE

	_mat = ShaderMaterial.new()
	_mat.shader = shader

	_rect = ColorRect.new()
	_rect.name = "GForceRect"
	_rect.material = _mat
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.visible = false
	add_child(_rect)

func is_gloc() -> bool:
	return _gloc_active

func update_effect(delta: float, g: float, is_alive: bool, is_ai: bool, is_paused: bool) -> void:
	if not is_alive or is_ai:
		blackout = 0.0
		redout = 0.0
		_gloc_timer = 0.0
		_gloc_active = false
		_gloc_can_trigger = true
		if _rect != null:
			_rect.visible = false
		return

	if is_paused:
		return

	# Blackout target [9G..11G] -> [0..1]
	var target_black: float = clamp((g - G_BLACKOUT_START) / (G_BLACKOUT_FULL - G_BLACKOUT_START), 0.0, 1.0)
	# Redout target [-3G..-5G] -> [0..1]
	var target_red: float = clamp((-g - 3.0) / (5.0 - 3.0), 0.0, 1.0)

	if _gloc_active:
		_gloc_timer -= delta
		blackout = 1.0
		if _gloc_timer <= 0.0:
			_gloc_active = false
	else:
		# Blackout rate of change
		if target_black > blackout:
			blackout = min(1.0, blackout + RISE_RATE * delta)
			if blackout >= 1.0 and _gloc_can_trigger:
				_gloc_active = true
				_gloc_timer = GLOC_DURATION
				_gloc_can_trigger = false
		else:
			blackout = max(0.0, blackout - FALL_RATE * delta)
			if blackout < 0.5:
				_gloc_can_trigger = true

		# Redout rate of change
		if target_red > redout:
			redout = min(1.0, redout + RISE_RATE * delta)
		else:
			redout = max(0.0, redout - FALL_RATE * delta)

	if _rect != null:
		var is_vis: bool = (blackout > 0.001 or redout > 0.001)
		_rect.visible = is_vis
		if is_vis and _mat != null:
			_mat.set_shader_parameter("blackout", blackout)
			_mat.set_shader_parameter("redout", redout)
