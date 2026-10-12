extends SceneTree

const OUT_DIR := "res://../crashlog/game_messages"

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var abs_out: String = ProjectSettings.globalize_path(OUT_DIR).simplify_path()
	DirAccess.make_dir_recursive_absolute(abs_out)

	var main_packed: PackedScene = load("res://main.tscn")
	var main_node: Node = main_packed.instantiate()
	root.add_child(main_node)

	# 1. Capture 1080p Before & After
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	root.size = Vector2i(1920, 1080)
	for i in range(35):
		await process_frame

	var img_before_1080: Image = root.get_texture().get_image()
	if img_before_1080 != null:
		img_before_1080.save_png(abs_out.path_join("before_1080p.png"))
		print("Saved before_1080p.png")

	var gm: Control = main_node.find_child("GameMessages", true, false)
	if gm != null:
		var evs: Array[Dictionary] = [
			{
				"kind": "kill",
				"killer": {"name": "VIPER 1", "iff": 0},
				"victim": {"name": "FLANKER 2", "iff": 3},
				"weapon": "AIM-120",
				"friendly": false
			},
			{
				"kind": "kill",
				"killer": {"name": "SAM_ALPHA", "iff": 3, "type": "ground"},
				"victim": {"name": "HORNET 3", "iff": 0, "type": "aircraft"},
				"weapon": "AIM-9",
				"friendly": false
			},
			{
				"kind": "kill",
				"killer": {"name": "EAGLE 4", "iff": 0},
				"victim": {"name": "AAA_SITE_B", "iff": 3, "type": "ground"},
				"weapon": "AGM",
				"friendly": false
			},
			{
				"kind": "crash",
				"victim": {"name": "FULCRUM 5", "iff": 3},
				"cause": "TERRAIN"
			},
			{
				"kind": "leave",
				"victim": {"name": "GHOST 6", "iff": 0}
			},
			{
				"kind": "disconnect",
				"victim": {"name": "Maverick"}
			}
		]
		for ev in evs:
			var bb: String = gm._format_event_bbcode(ev)
			gm._active_messages.push_front({
				"sequence": 1,
				"time_left": 8.0,
				"bbcode": bb
			})
		if gm._active_messages.size() > 6:
			gm._active_messages.resize(6)
		gm._rebuild_text()

	for i in range(10):
		await process_frame

	var img_after_1080: Image = root.get_texture().get_image()
	if img_after_1080 != null:
		img_after_1080.save_png(abs_out.path_join("after_1080p.png"))
		print("Saved after_1080p.png")

	# 2. Capture 1440p Before & After
	DisplayServer.window_set_size(Vector2i(2560, 1440))
	root.size = Vector2i(2560, 1440)
	if gm != null:
		gm._active_messages.clear()
		gm._rebuild_text()
		gm._update_layout()

	for i in range(10):
		await process_frame

	var img_before_1440: Image = root.get_texture().get_image()
	if img_before_1440 != null:
		img_before_1440.save_png(abs_out.path_join("before_1440p.png"))
		print("Saved before_1440p.png")

	if gm != null:
		var evs: Array[Dictionary] = [
			{
				"kind": "kill",
				"killer": {"name": "VIPER 1", "iff": 0},
				"victim": {"name": "FLANKER 2", "iff": 3},
				"weapon": "AIM-120",
				"friendly": false
			},
			{
				"kind": "kill",
				"killer": {"name": "SAM_ALPHA", "iff": 3, "type": "ground"},
				"victim": {"name": "HORNET 3", "iff": 0, "type": "aircraft"},
				"weapon": "AIM-9",
				"friendly": false
			},
			{
				"kind": "kill",
				"killer": {"name": "EAGLE 4", "iff": 0},
				"victim": {"name": "AAA_SITE_B", "iff": 3, "type": "ground"},
				"weapon": "AGM",
				"friendly": false
			},
			{
				"kind": "crash",
				"victim": {"name": "FULCRUM 5", "iff": 3},
				"cause": "TERRAIN"
			},
			{
				"kind": "leave",
				"victim": {"name": "GHOST 6", "iff": 0}
			},
			{
				"kind": "disconnect",
				"victim": {"name": "Maverick"}
			}
		]
		for ev in evs:
			var bb: String = gm._format_event_bbcode(ev)
			gm._active_messages.push_front({
				"sequence": 1,
				"time_left": 8.0,
				"bbcode": bb
			})
		if gm._active_messages.size() > 6:
			gm._active_messages.resize(6)
		gm._rebuild_text()

	for i in range(10):
		await process_frame

	var img_after_1440: Image = root.get_texture().get_image()
	if img_after_1440 != null:
		img_after_1440.save_png(abs_out.path_join("after_1440p.png"))
		print("Saved after_1440p.png")

	print("CAPTURES COMPLETE")
	quit(0)
