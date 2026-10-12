extends SceneTree

# Verifies that navigating from Home to Replays and back to Home preserves
# the maximized window state without force-resizing.

var _step := 0
var _orig_mode: int = 0

func _process(_delta: float) -> bool:
	match _step:
		0:
			_step = 1
			_orig_mode = DisplayServer.window_get_mode()
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
			change_scene_to_file("res://ui/home.tscn")
			return false
		1:
			_step = 2
			return false # wait for home scene _ready()
		2:
			_step = 3
			var cur_mode := DisplayServer.window_get_mode()
			print("Home loaded. Current window mode: ", cur_mode)
			assert(cur_mode == DisplayServer.WINDOW_MODE_MAXIMIZED, "Window must remain maximized on Home")
			change_scene_to_file("res://ui/replay_browser.tscn")
			return false
		3:
			_step = 4
			return false # wait for replay_browser _ready()
		4:
			_step = 5
			var cur_mode := DisplayServer.window_get_mode()
			print("ReplayBrowser loaded. Current window mode: ", cur_mode)
			assert(cur_mode == DisplayServer.WINDOW_MODE_MAXIMIZED, "Window must remain maximized on ReplayBrowser")
			# Simulate clicking BACK TO MENU
			change_scene_to_file("res://ui/home.tscn")
			return false
		5:
			_step = 6
			return false # wait for home reload _ready()
		6:
			_step = 7
			var final_mode := DisplayServer.window_get_mode()
			print("Returned to Home. Final window mode: ", final_mode)
			assert(final_mode == DisplayServer.WINDOW_MODE_MAXIMIZED,
				"Window must remain maximized after returning to Home from Replays!")
			DisplayServer.window_set_mode(_orig_mode)
			print("--- REPLAY WINDOW RESIZE TEST PASSED ---")
			quit(0)
			return true
	return false
