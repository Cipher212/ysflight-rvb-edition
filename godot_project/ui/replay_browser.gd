extends Control

# ==============================================================================
# YSFlight RvB Edition - Replay Browser & Analytics Hub
# ==============================================================================
# Main menu hub for browsing, inspecting, and launching saved .ysrvb flight replays.
# Displays pre-computed aircraft statistics, ground object threat rankings, and
# auto-detected highlights reel furball clusters.
#
# FULL SPECIFICATION & ARCHITECTURE REFERENCE:
# -> planning/replay_and_spectator_system.md
#
# If any issues occur, see planning/replay_and_spectator_system.md for analytics
# computation, folder resolution, and spectator launch details.
# ==============================================================================

const Kit := preload("res://ui/ui_kit.gd")
const AppState := preload("res://core/app_state.gd")
const ReplayManager := preload("res://core/replay_manager.gd")
const HOME_SCENE := "res://ui/home.tscn"

const PANEL_WIDTH := 1320
const PANEL_HEIGHT := 840
const LEFT_COL_WIDTH := 420

var _replays: Array[Dictionary] = []
var _selected_idx: int = -1
var _current_replay_data: Dictionary = {}

var _replay_list_box: VBoxContainer = null
var _details_panel: VBoxContainer = null
var _status_lbl: Label = null

func _ready() -> void:
	Kit.make_screen(self)
	_build_ui()
	_refresh_list()

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_bottom", 30)
	add_child(margin)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 16)
	margin.add_child(page)

	# 1. Header Bar
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	page.add_child(header)

	var title_col := VBoxContainer.new()
	title_col.add_theme_constant_override("separation", 4)
	header.add_child(title_col)

	var title := Kit.label("REPLAY THEATER & TAC-VIEW", "TitleLabel")
	title.add_theme_font_size_override("font_size", 42)
	title_col.add_child(title)

	var subtitle := Kit.label("SAVED EVENT & FREE FLIGHT ARCHIVES", "TagLabel")
	title_col.add_child(subtitle)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	var btn_box := HBoxContainer.new()
	btn_box.add_theme_constant_override("separation", 12)
	btn_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(btn_box)

	var open_folder_btn := Kit.button("OPEN FOLDER", "BlueButton", _open_replay_folder)
	btn_box.add_child(open_folder_btn)

	var back_btn := Kit.button("BACK TO MENU", "RedButton", func() -> void:
		get_tree().change_scene_to_file(HOME_SCENE))
	btn_box.add_child(back_btn)

	page.add_child(HSeparator.new())

	# 2. Main Content Split View
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 24)
	page.add_child(content)

	# Left Column: Replay Files List
	var left_box := VBoxContainer.new()
	left_box.custom_minimum_size = Vector2(LEFT_COL_WIDTH, 0)
	left_box.add_theme_constant_override("separation", 10)
	content.add_child(left_box)

	left_box.add_child(Kit.label("RECORDED SORTIES", "SectionLabel"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_box.add_child(scroll)

	_replay_list_box = VBoxContainer.new()
	_replay_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_replay_list_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_replay_list_box)

	# Right Column: Replay Details, Highlights & Analytics
	_details_panel = VBoxContainer.new()
	_details_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details_panel.add_theme_constant_override("separation", 14)
	content.add_child(_details_panel)

	# Footer Status Bar
	var footer := HBoxContainer.new()
	page.add_child(footer)
	_status_lbl = Kit.label("", "DimLabel")
	footer.add_child(_status_lbl)

func _refresh_list() -> void:
	for child in _replay_list_box.get_children():
		child.queue_free()

	_replays = ReplayManager.list_replays()
	if _replays.is_empty():
		var empty_lbl := Kit.label("NO REPLAYS SAVED YET.\nCOMPLETE A FLIGHT OR ENABLE AUTOSAVE IN SETTINGS.", "DimLabel")
		_replay_list_box.add_child(empty_lbl)
		_show_empty_details()
		return

	for i in range(_replays.size()):
		var r: Dictionary = _replays[i]
		var map_name: String = str(r.get("map", "UNKNOWN")).replace("[RVB]", "")
		var dur_str: String = Kit.clock(float(r.get("duration", 0.0)))
		var kills_str: String = "%d KILLS" % int(r.get("kills_count", 0))

		var btn_text := "%s  /  %s  /  %s\n%s" % [map_name, dur_str, kills_str, r.get("file_name", "")]
		var btn := Kit.button(btn_text, "HomeButton", _select_replay.bind(i))
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(0, 58)
		_replay_list_box.add_child(btn)

	_select_replay(0)

func _select_replay(idx: int) -> void:
	if idx < 0 or idx >= _replays.size():
		return
	_selected_idx = idx
	var meta: Dictionary = _replays[idx]
	var path: String = str(meta.get("file_path", ""))

	_current_replay_data = ReplayManager.load_replay(path)
	_render_details(_current_replay_data, meta)

func _show_empty_details() -> void:
	for child in _details_panel.get_children():
		child.queue_free()
	var lbl := Kit.label("SELECT A REPLAY FILE TO VIEW HIGHLIGHTS AND ANALYTICS.", "DimLabel")
	_details_panel.add_child(lbl)

func _render_details(data: Dictionary, meta: Dictionary) -> void:
	for child in _details_panel.get_children():
		child.queue_free()

	if data.is_empty():
		_details_panel.add_child(Kit.label("FAILED TO LOAD REPLAY DATA.", "RedText"))
		return

	var m: Dictionary = data.get("metadata", meta)
	var events: Array = data.get("events", [])
	var roster: Array = data.get("roster", [])

	# Top action buttons
	var action_bar := HBoxContainer.new()
	action_bar.add_theme_constant_override("separation", 16)
	_details_panel.add_child(action_bar)

	var watch_btn := Kit.button("SPECTATE REPLAY", "HomeBlueButton", _launch_spectator)
	watch_btn.custom_minimum_size = Vector2(220, 50)
	action_bar.add_child(watch_btn)

	var delete_btn := Kit.button("DELETE", "RedButton", _delete_selected_replay)
	delete_btn.custom_minimum_size = Vector2(120, 50)
	action_bar.add_child(delete_btn)

	var stats_scroll := ScrollContainer.new()
	stats_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stats_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_details_panel.add_child(stats_scroll)

	var stats_box := VBoxContainer.new()
	stats_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_box.add_theme_constant_override("separation", 16)
	stats_scroll.add_child(stats_box)

	# 1. Highlights Reel Section (Ref: planning/replay_and_spectator_system.md)
	stats_box.add_child(Kit.label("HIGHLIGHTS REEL (AUTOMATED CLUSTERS)", "SectionLabel"))
	var highlights: Array[Dictionary] = ReplayManager.detect_highlights(events)
	if highlights.is_empty():
		stats_box.add_child(Kit.label("NO MAJOR COMBAT CLUSTERS DETECTED.", "DimLabel"))
	else:
		var hl_grid := GridContainer.new()
		hl_grid.columns = 3
		hl_grid.add_theme_constant_override("h_separation", 16)
		hl_grid.add_theme_constant_override("v_separation", 8)
		stats_box.add_child(hl_grid)
		for hl in highlights:
			var hl_btn := Kit.button("%s\nAT %s" % [hl["title"], Kit.clock(float(hl["start_time"]))], "", func() -> void:
				_launch_spectator(float(hl["start_time"])))
			hl_btn.custom_minimum_size = Vector2(240, 54)
			hl_grid.add_child(hl_btn)

	stats_box.add_child(HSeparator.new())

	# 2. Aircraft Statistics (Ref: planning/replay_and_spectator_system.md)
	stats_box.add_child(Kit.label("AIRCRAFT UTILIZATION & COMBAT STATS", "SectionLabel"))
	var ac_stats: Array[Dictionary] = ReplayManager.compute_aircraft_statistics(data)
	if ac_stats.is_empty():
		stats_box.add_child(Kit.label("NO AIRCRAFT FLIGHT DATA RECORDED.", "DimLabel"))
	else:
		var ac_grid := GridContainer.new()
		ac_grid.columns = 5
		ac_grid.add_theme_constant_override("h_separation", 18)
		ac_grid.add_theme_constant_override("v_separation", 6)
		stats_box.add_child(ac_grid)
		for head in ["AIRCRAFT", "SORTIES", "AIR KILLS", "GND KILLS", "K/D RATIO"]:
			ac_grid.add_child(Kit.label(head, "TableHead"))
		for ac in ac_stats:
			ac_grid.add_child(Kit.label(ac["aircraft"]))
			ac_grid.add_child(Kit.label(str(ac["sorties"])))
			ac_grid.add_child(Kit.label(str(ac["air_kills"])))
			ac_grid.add_child(Kit.label(str(ac["ground_kills"])))
			ac_grid.add_child(Kit.label(str(ac["kd_ratio"])))

	stats_box.add_child(HSeparator.new())

	# 3. Ground Threat Statistics (Ref: planning/replay_and_spectator_system.md)
	stats_box.add_child(Kit.label("GROUND OBJECT THREAT REPORT", "SectionLabel"))
	var gnd_stats: Dictionary = ReplayManager.compute_ground_statistics(data)
	var destroyed: Array[Dictionary] = gnd_stats.get("most_destroyed", [])
	if destroyed.is_empty():
		stats_box.add_child(Kit.label("NO GROUND TARGETS DESTROYED.", "DimLabel"))
	else:
		var g_row := HBoxContainer.new()
		g_row.add_theme_constant_override("separation", 14)
		stats_box.add_child(g_row)
		for item in destroyed.slice(0, 6):
			var badge := Kit.label("%s: %d" % [item["target"], item["count"]], "TagLabel")
			g_row.add_child(badge)

func _launch_spectator(start_time: float = 0.0) -> void:
	if _selected_idx < 0 or _selected_idx >= _replays.size():
		return
	var meta: Dictionary = _replays[_selected_idx]
	AppState.spectating_replay_path = str(meta.get("file_path", ""))
	AppState.mode = "spectator_replay"
	# Store start timestamp in AppState for the spectator viewer
	AppState.last_replay_data = _current_replay_data
	get_tree().change_scene_to_file("res://ui/replay_spectator.tscn")

func _delete_selected_replay() -> void:
	if _selected_idx < 0 or _selected_idx >= _replays.size():
		return
	var meta: Dictionary = _replays[_selected_idx]
	var path: String = str(meta.get("file_path", ""))
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		_status_lbl.text = "DELETED REPLAY: " + meta.get("file_name", "")
		_refresh_list()

func _open_replay_folder() -> void:
	var dir := ReplayManager.get_replay_dir()
	OS.shell_open(ProjectSettings.globalize_path(dir))
