extends RefCounted

# Colour grade, Ace Combat 4 / Zero style (user, 2026-09-30): ACES tone mapping, less saturation, a little
# more contrast and per-channel curves (slightly lifted cool shadows, warm muted highlights), so Luavi reads
# less bright and toy-like. All of it runs inside Godot's tone-mapping pass, which runs every frame anyway:
# no extra pass, one small texture lookup per pixel.

const DEFAULT_STYLE := "RvB Default"

const STYLES: Dictionary = {
	"RvB Default": {
		"exposure": 1.0,
		"white": 6.0,
		"saturation": 0.72,
		"contrast": 1.08,
		"brightness": 1.0,
		"shadow_lift": Color(0.0, 0.012, 0.035),
		"highlight_shift": Color(0.0, -0.01, -0.05),
	},
	"Vibrant": {
		"exposure": 1.05,
		"white": 6.0,
		"saturation": 1.0,
		"contrast": 1.05,
		"brightness": 1.02,
		"shadow_lift": Color(0.0, 0.005, 0.015),
		"highlight_shift": Color(0.02, 0.01, -0.02),
	},
	"Grim": {
		"exposure": 0.92,
		"white": 5.0,
		"saturation": 0.5,
		"contrast": 1.15,
		"brightness": 0.97,
		"shadow_lift": Color(0.0, 0.015, 0.03),
		"highlight_shift": Color(-0.02, -0.01, 0.0),
	},
	"Classic YSFlight": {
		"exposure": 1.08,
		"white": 8.0,
		"saturation": 0.95,
		"contrast": 1.0,
		"brightness": 1.0,
		"shadow_lift": Color(0, 0, 0),
		"highlight_shift": Color(0, 0, 0),
	},
	"Cinematic": {
		"exposure": 1.0,
		"white": 6.0,
		"saturation": 0.85,
		"contrast": 1.12,
		"brightness": 1.0,
		"shadow_lift": Color(0.0, 0.02, 0.035),
		"highlight_shift": Color(0.03, 0.0, -0.04),
	},
}

static func apply(env: Environment, style: String = DEFAULT_STYLE) -> void:
	if env == null:
		return
	var cfg: Dictionary = STYLES.get(style, STYLES[DEFAULT_STYLE])
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = float(cfg["exposure"])
	env.tonemap_white = float(cfg["white"])
	env.adjustment_enabled = true
	env.adjustment_brightness = float(cfg["brightness"])
	env.adjustment_contrast = float(cfg["contrast"])
	env.adjustment_saturation = float(cfg["saturation"])
	env.adjustment_color_correction = _curves(cfg["shadow_lift"], cfg["highlight_shift"])

# 256x1 texture = one curve per channel (Godot treats a 2D correction texture as per-channel 1D curves).
static func _curves(shadow_lift: Color, highlight_shift: Color) -> ImageTexture:
	var img := Image.create(256, 1, false, Image.FORMAT_RGB8)
	for i in 256:
		var x := i / 255.0
		var c := Color(x, x, x) + shadow_lift * pow(1.0 - x, 3.0) + highlight_shift * pow(x, 3.0)
		img.set_pixel(i, 0, c.clamp())
	return ImageTexture.create_from_image(img)

