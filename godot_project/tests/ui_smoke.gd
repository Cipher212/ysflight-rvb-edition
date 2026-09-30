extends SceneTree

# UI smoke test: instantiates every menu screen for a few frames, headless, and fails on any error.
# Run: engine\Godot_v4.7.2-stable_win64_console.exe --headless --path godot_project -s res://tests/ui_smoke.gd
# Prints "UI SMOKE OK" and exits 0, or "UI SMOKE FAIL: ..." and exits 1. Screens: logs/UI_scheme.md.

const SCENES := ["res://ui/home.tscn", "res://ui/event_builder.tscn", "res://ui/debrief.tscn"]
const FRAMES_PER_SCENE := 10

var _i := -1
var _frames := 0
var _node: Node = null
var _failed := false

func _process(_delta: float) -> bool:
	if _node != null:
		_frames += 1
		if _frames < FRAMES_PER_SCENE:
			return false
		_node.queue_free()
		_node = null
	_i += 1
	if _i >= SCENES.size():
		print("UI SMOKE FAIL" if _failed else "UI SMOKE OK")
		quit(1 if _failed else 0)
		return true
	var path: String = SCENES[_i]
	if not ResourceLoader.exists(path):
		print("UI SMOKE FAIL: missing ", path)
		_failed = true
		return false
	var packed: PackedScene = load(path)
	if packed == null:
		print("UI SMOKE FAIL: cannot load ", path)
		_failed = true
		return false
	_node = packed.instantiate()
	root.add_child(_node)
	_frames = 0
	print("UI SMOKE: ", path)
	return false
