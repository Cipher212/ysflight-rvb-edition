extends RefCounted

# Colour grade, Ace Combat 4 / Zero style (user, 2026-09-30): ACES tone mapping, less saturation, a little
# more contrast and per-channel curves (slightly lifted cool shadows, warm muted highlights), so Luavi reads
# less bright and toy-like. All of it runs inside Godot's tone-mapping pass, which runs every frame anyway:
# no extra pass, one small texture lookup per pixel.

const EXPOSURE := 1.0          # restrained daylight; ambient fill still keeps aircraft undersides readable
const WHITE := 6.0
const SATURATION := 0.72
const CONTRAST := 1.08
const BRIGHTNESS := 1.0
const SHADOW_LIFT := Color(0.0, 0.012, 0.035)     # added at black, gone by mid-grey
const HIGHLIGHT_SHIFT := Color(0.0, -0.01, -0.05) # added at white: warmer, a touch muted

static func apply(env: Environment) -> void:
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = EXPOSURE
	env.tonemap_white = WHITE
	env.adjustment_enabled = true
	env.adjustment_brightness = BRIGHTNESS
	env.adjustment_contrast = CONTRAST
	env.adjustment_saturation = SATURATION
	env.adjustment_color_correction = _curves()

# 256x1 texture = one curve per channel (Godot treats a 2D correction texture as per-channel 1D curves).
static func _curves() -> ImageTexture:
	var img := Image.create(256, 1, false, Image.FORMAT_RGB8)
	for i in 256:
		var x := i / 255.0
		var c := Color(x, x, x) + SHADOW_LIFT * pow(1.0 - x, 3.0) + HIGHLIGHT_SHIFT * pow(x, 3.0)
		img.set_pixel(i, 0, c.clamp())
	return ImageTexture.create_from_image(img)
