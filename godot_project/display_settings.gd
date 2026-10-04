extends Node

# Window mode and resolution (Settings > Display), saved with the other settings (controls.gd, user folder) so they
# are remembered on this PC. Applied when the home screen and the game start, and whenever they change.
# - Windowed: the window gets the chosen resolution (never larger than the screen), centred.
# - Borderless Fullscreen / Fullscreen: the screen's own resolution (Godot cannot switch the monitor's mode);
#   lower the 3D Render Scale (Graphics) to render fewer pixels. Fullscreen = exclusive (lowest latency).
# Default: Windowed 1920x1080, the performance target (a 4K laptop screen in fullscreen is 4x the pixels).
# Never created in benchmark or test runs: the benchmark keeps its own 1920x1080 window (benchmark.gd).

const MODES := {
	"Windowed": DisplayServer.WINDOW_MODE_WINDOWED,
	"Borderless Fullscreen": DisplayServer.WINDOW_MODE_FULLSCREEN,
	"Fullscreen": DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN,
}
const SCREEN_MARGIN := Vector2i(0, 80) # keep a window clear of the taskbar and its title bar

var controls: Node = null

func setup(p_controls: Node) -> void:
	name = "DisplaySettings"
	controls = p_controls
	controls.changed.connect(func(key: String) -> void:
		if key in ["window_mode", "resolution", ""]:
			apply())
	apply()

func apply() -> void:
	var mode: int = MODES.get(str(controls.get_value("window_mode", "Windowed")), DisplayServer.WINDOW_MODE_WINDOWED)
	if DisplayServer.window_get_mode() != mode:
		DisplayServer.window_set_mode(mode)
	if mode != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var screen := DisplayServer.window_get_current_screen()
	var usable: Vector2i = DisplayServer.screen_get_usable_rect(screen).size - SCREEN_MARGIN
	var parts := str(controls.get_value("resolution", "1920x1080")).split("x")
	var size := Vector2i(int(parts[0]), int(parts[1])) if parts.size() == 2 else Vector2i(1920, 1080)
	size = Vector2i(mini(size.x, usable.x), mini(size.y, usable.y))
	if DisplayServer.window_get_size() != size:
		DisplayServer.window_set_size(size)
		var origin: Vector2i = DisplayServer.screen_get_usable_rect(screen).position
		DisplayServer.window_set_position(origin + (DisplayServer.screen_get_usable_rect(screen).size - size) / 2)
