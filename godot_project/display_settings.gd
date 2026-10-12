extends Node

# Window mode and resolution (Settings > Display), saved with the other settings (controls.gd, user folder) so they
# are remembered on this PC. Applied on initial game boot, and whenever display settings are explicitly changed.
# - Windowed: the window gets the chosen resolution (never larger than the screen), centred.
#   If the user maximizes the window in the OS, that maximized state is preserved across scene transitions.
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

static var _initial_applied: bool = false

var controls: Node = null

func setup(p_controls: Node) -> void:
	name = "DisplaySettings"
	controls = p_controls
	controls.changed.connect(func(key: String) -> void:
		if key in ["window_mode", "resolution", ""]:
			apply(key == "resolution" or key == ""))
	if not _initial_applied:
		_initial_applied = true
		apply()

func apply(force_unmaximize: bool = false) -> void:
	var mode: int = MODES.get(str(controls.get_value("window_mode", "Windowed")), DisplayServer.WINDOW_MODE_WINDOWED)
	var current_mode := DisplayServer.window_get_mode()

	# If target mode is Windowed and current mode is Maximized, the window is already in a windowed state.
	# A maximized window must not be unmaximized, resized, or recentered unless explicitly requested
	# (e.g. user selected a specific resolution or clicked Reset Defaults in Settings).
	if mode == DisplayServer.WINDOW_MODE_WINDOWED and current_mode == DisplayServer.WINDOW_MODE_MAXIMIZED and not force_unmaximize:
		return

	if current_mode != mode:
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
