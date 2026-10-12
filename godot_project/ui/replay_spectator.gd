extends Node3D

# ==============================================================================
# YSFlight RvB Edition - Dedicated Replay Spectator & Tac-View Engine
# ==============================================================================
# Full-fidelity 3D replay theater featuring multiple camera perspectives, weapons cam,
# timeline scrubber, pilot tracking by name, dynamic progression scoreboard, and
# highlights reel quick-navigation.
#
# FULL SPECIFICATION & ARCHITECTURE REFERENCE:
# -> planning/replay_and_spectator_system.md
#
# If any issues occur, see planning/replay_and_spectator_system.md for camera modes,
# weapons tracking, and timepoint evaluation.
# ==============================================================================

const Kit := preload("res://ui/ui_kit.gd")
const AppState := preload("res://core/app_state.gd")
const ReplayManager := preload("res://core/replay_manager.gd")
const ScoreboardScript := preload("res://ui/scoreboard.gd")
const REPLAY_BROWSER_SCENE := "res://ui/replay_browser.tscn"

enum CamMode {
	COCKPIT,
	CHASE,
	ORBIT,
	FLYBY,
	WEAPONS_CAM,
	FREE_CAM,
	CINEMATIC_DIRECTOR,
	TAC_VIEW
}

# Playback State
var replay_data: Dictionary = {}
var is_playing: bool = true
var playback_speed: float = 1.0
var current_time: float = 0.0
var duration: float = 0.0
var active_cam_mode: CamMode = CamMode.CHASE

# Target & Pilot Tracking
var spectated_pilot_id: int = 0
var spectated_pilot_name: String = "PLAYER"
var active_missile_id: int = -1

# Camera Node & State
var camera: Camera3D = null
var _cam_yaw: float = 0.0
var _cam_pitch: float = 0.0
var _orbit_dist: float = 35.0
var _freecam_pos: Vector3 = Vector3(0, 1000, 0)

# Visual Nodes
var _aircraft_visuals: Dictionary = {} # id -> Node3D
var _weapon_visuals: Dictionary = {}   # id -> Node3D

# UI Overlay Elements
var _scoreboard: CanvasLayer = null
var _timeline_slider: HSlider = null
var _time_lbl: Label = null
var _play_pause_btn: Button = null
var _pilot_name_lbl: Label = null
var _telemetry_lbl: Label = null
var _cam_mode_lbl: Label = null
var _highlights_container: HBoxContainer = null

func _ready() -> void:
	# Load replay data from AppState or file
	replay_data = AppState.last_replay_data
	if replay_data.is_empty() and not AppState.spectating_replay_path.is_empty():
		replay_data = ReplayManager.load_replay(AppState.spectating_replay_path)

	duration = float(replay_data.get("metadata", {}).get("duration", 10.0))
	if duration <= 0.0:
		duration = 10.0

	_setup_environment_and_camera()
	_setup_scoreboard()
	_setup_ui()
	_init_visual_entities()

func _setup_environment_and_camera() -> void:
	camera = Camera3D.new()
	camera.current = true
	camera.fov = 65.0
	camera.near = 0.5
	camera.far = 80000.0
	add_child(camera)

	# Sun & Directional Light
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.light_color = Color(1.0, 0.96, 0.9)
	add_child(sun)

	# World Environment
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.35, 0.5, 0.65)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.45, 0.5)
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

func _setup_scoreboard() -> void:
	_scoreboard = ScoreboardScript.new()
	add_child(_scoreboard)
	_scoreboard.setup_replay(replay_data)

func _setup_ui() -> void:
	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 50
	add_child(hud_layer)

	var root := Control.new()
	root.theme = Kit.THEME
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(root)

	# 1. Top HUD Bar
	var top_bar := HBoxContainer.new()
	top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_bar.custom_minimum_size = Vector2(0, 60)
	top_bar.add_theme_constant_override("separation", 18)
	top_bar.position = Vector2(24, 16)
	root.add_child(top_bar)

	var back_btn := Kit.button("EXIT REPLAY", "RedButton", func() -> void:
		get_tree().change_scene_to_file(REPLAY_BROWSER_SCENE))
	top_bar.add_child(back_btn)

	var prev_pilot_btn := Kit.button("< PREV PILOT", "", _cycle_pilot.bind(-1))
	top_bar.add_child(prev_pilot_btn)

	_pilot_name_lbl = Kit.label("PILOT: PLAYER [BLUE]", "SectionLabel")
	top_bar.add_child(_pilot_name_lbl)

	var next_pilot_btn := Kit.button("NEXT PILOT >", "", _cycle_pilot.bind(1))
	top_bar.add_child(next_pilot_btn)

	_telemetry_lbl = Kit.label("SPD: 580 KT  |  ALT: 1,200 FT  |  4.2 G", "TagLabel")
	_telemetry_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top_bar.add_child(_telemetry_lbl)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)

	_cam_mode_lbl = Kit.label("CAMERA: CHASE (F2)", "SectionLabel")
	top_bar.add_child(_cam_mode_lbl)

	var sb_btn := Kit.button("SCOREBOARD (TAB)", "BlueButton", func() -> void:
		_scoreboard.toggle_scoreboard())
	top_bar.add_child(sb_btn)

	# 2. Highlights Reel Quick-Jump Row (Mid-Top)
	var hl_scroll := ScrollContainer.new()
	hl_scroll.position = Vector2(24, 82)
	hl_scroll.custom_minimum_size = Vector2(1200, 38)
	hl_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(hl_scroll)

	_highlights_container = HBoxContainer.new()
	_highlights_container.add_theme_constant_override("separation", 10)
	hl_scroll.add_child(_highlights_container)
	_build_highlights_bar()

	# 3. Bottom Playback & Scrubber Controls
	var bottom_panel := PanelContainer.new()
	bottom_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom_panel.custom_minimum_size = Vector2(0, 96)
	bottom_panel.position = Vector2(24, -110)
	root.add_child(bottom_panel)

	var bottom_layout := VBoxContainer.new()
	bottom_layout.add_theme_constant_override("separation", 8)
	bottom_panel.add_child(bottom_layout)

	# Scrubber Slider
	var slider_row := HBoxContainer.new()
	slider_row.add_theme_constant_override("separation", 16)
	bottom_layout.add_child(slider_row)

	_time_lbl = Kit.label("00:00 / 00:00", "TagLabel")
	_time_lbl.custom_minimum_size = Vector2(140, 0)
	slider_row.add_child(_time_lbl)

	_timeline_slider = HSlider.new()
	_timeline_slider.min_value = 0.0
	_timeline_slider.max_value = duration
	_timeline_slider.step = 0.1
	_timeline_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_timeline_slider.value_changed.connect(_on_slider_value_changed)
	slider_row.add_child(_timeline_slider)

	# Control Buttons Row
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)
	bottom_layout.add_child(btn_row)

	_play_pause_btn = Kit.button("PAUSE (SPACE)", "BlueButton", _toggle_play_pause)
	btn_row.add_child(_play_pause_btn)

	btn_row.add_child(Kit.button("-5s", "", func() -> void: _seek_relative(-5.0)))
	btn_row.add_child(Kit.button("+5s", "", func() -> void: _seek_relative(5.0)))

	for spd in [0.25, 0.5, 1.0, 2.0, 4.0]:
		var spd_btn := Kit.button("%.2fx" % spd if spd < 1.0 else "%dx" % int(spd), "", _set_speed.bind(spd))
		btn_row.add_child(spd_btn)

	var spacer2 := Control.new()
	spacer2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(spacer2)

	# Camera Mode Buttons (F1 - F9)
	for cm in [
		["COCKPIT (F1)", CamMode.COCKPIT],
		["CHASE (F2)", CamMode.CHASE],
		["ORBIT (F3)", CamMode.ORBIT],
		["FLYBY (F4)", CamMode.FLYBY],
		["WEAPON (F6)", CamMode.WEAPONS_CAM],
		["FREECAM (F7)", CamMode.FREE_CAM],
		["DIRECTOR (F8)", CamMode.CINEMATIC_DIRECTOR],
		["TAC-VIEW (F9)", CamMode.TAC_VIEW]
	]:
		var cbtn := Kit.button(cm[0], "", _set_cam_mode.bind(cm[1]))
		btn_row.add_child(cbtn)

func _build_highlights_bar() -> void:
	for c in _highlights_container.get_children():
		c.queue_free()

	var events: Array = replay_data.get("events", [])
	var highlights := ReplayManager.detect_highlights(events)
	if highlights.is_empty():
		return

	var badge := Kit.label("HIGHLIGHTS:", "SectionLabel")
	_highlights_container.add_child(badge)

	for hl in highlights:
		var start_t: float = float(hl.get("start_time", 0.0))
		var btn := Kit.button("%s [%s]" % [hl.get("title", "ACTION"), Kit.clock(start_t)], "", func() -> void:
			_seek_to(start_t))
		_highlights_container.add_child(btn)

func _init_visual_entities() -> void:
	# Create proxy 3D visual representations for aircraft
	var roster: Array = replay_data.get("roster", [])
	for i in range(maxi(roster.size(), 16)):
		var mesh_inst := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(4.0, 1.2, 8.0) # Jet silhouette representation
		mesh_inst.mesh = box_mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color("#4a75ff") if i % 2 == 0 else Color("#ff4a42")
		mesh_inst.material_override = mat
		add_child(mesh_inst)
		_aircraft_visuals[i] = mesh_inst

func _process(delta: float) -> void:
	if is_playing:
		current_time += delta * playback_speed
		if current_time > duration:
			current_time = duration
			is_playing = false
			_update_play_pause_ui()

		_timeline_slider.set_value_no_signal(current_time)

	_time_lbl.text = "%s / %s" % [Kit.clock(current_time), Kit.clock(duration)]
	_update_simulation_at_time(current_time)
	_update_camera(delta)

	# Keep scoreboard synchronized with current scrubbed timepoint (Ref: planning/replay_and_spectator_system.md)
	if _scoreboard != null and _scoreboard.visible:
		_scoreboard.update_replay_timepoint(current_time)

func _update_simulation_at_time(t: float) -> void:
	var frames: Array = replay_data.get("frames", [])
	if frames.is_empty():
		return

	# Find closest frame by timestamp
	var target_frame: Dictionary = frames[0]
	var idx: int = clamp(int(t / 0.1), 0, frames.size() - 1)
	target_frame = frames[idx]

	# Update aircraft positions
	var ac_list: Array = target_frame.get("aircraft", [])
	for ac in ac_list:
		var ac_id: int = int(ac.get("id", 0))
		var pos_arr = ac.get("pos", [0, 0, 0])
		var pos := Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))

		if _aircraft_visuals.has(ac_id):
			var node: Node3D = _aircraft_visuals[ac_id]
			node.position = pos
			if ac.has("basis"):
				var b_arr = ac["basis"]
				node.basis = Basis(
					Vector3(b_arr[0][0], b_arr[0][1], b_arr[0][2]),
					Vector3(b_arr[1][0], b_arr[1][1], b_arr[1][2]),
					Vector3(b_arr[2][0], b_arr[2][1], b_arr[2][2])
				)

		# Update HUD labels for spectated pilot
		if ac_id == spectated_pilot_id:
			_telemetry_lbl.text = "SPD: %d KT  |  ALT: %d FT  |  %.1f G" % [
				int(ac.get("speed_kt", 0)),
				int(ac.get("alt_ft", 0)),
				float(ac.get("g_load", 1.0))
			]

	# Update weapon visuals (missile launches & trajectories)
	var wpn_list: Array = target_frame.get("weapons", [])
	for w in wpn_list:
		var wid: int = int(w.get("id", 0))
		var wpos_arr = w.get("pos", [0, 0, 0])
		var wpos := Vector3(float(wpos_arr[0]), float(wpos_arr[1]), float(wpos_arr[2]))

		if not _weapon_visuals.has(wid):
			var wnode := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.2
			cyl.bottom_radius = 0.2
			cyl.height = 2.8
			wnode.mesh = cyl
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(1.0, 0.8, 0.2)
			mat.emission_enabled = true
			mat.emission = Color(1.0, 0.6, 0.1)
			wnode.material_override = mat
			add_child(wnode)
			_weapon_visuals[wid] = wnode

		_weapon_visuals[wid].position = wpos
		_weapon_visuals[wid].visible = true
		active_missile_id = wid

func _update_camera(delta: float) -> void:
	var target_node: Node3D = _aircraft_visuals.get(spectated_pilot_id, null)
	var target_pos := target_node.position if target_node != null else Vector3.ZERO
	var target_basis := target_node.basis if target_node != null else Basis.IDENTITY

	match active_cam_mode:
		CamMode.COCKPIT:
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			camera.position = target_pos + target_basis * Vector3(0, 0.8, -1.2)
			camera.basis = target_basis

		CamMode.CHASE:
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			var offset := target_basis * Vector3(0, 4.5, 24.0)
			camera.position = camera.position.lerp(target_pos + offset, 12.0 * delta)
			camera.look_at(target_pos + target_basis * Vector3(0, 1.0, -10.0), Vector3.UP)

		CamMode.ORBIT:
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			var rot := Basis(Vector3.UP, _cam_yaw) * Basis(Vector3.RIGHT, _cam_pitch)
			camera.position = target_pos + rot * Vector3(0, 0, _orbit_dist)
			camera.look_at(target_pos, Vector3.UP)

		CamMode.FLYBY:
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			# Fixed ground / air station pointing at passing jet
			camera.look_at(target_pos, Vector3.UP)

		CamMode.WEAPONS_CAM:
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			if _weapon_visuals.has(active_missile_id):
				var wnode: Node3D = _weapon_visuals[active_missile_id]
				camera.position = wnode.position + Vector3(0, 1.5, 6.0)
				camera.look_at(wnode.position - Vector3(0, 0, 10.0), Vector3.UP)
			else:
				# Fallback to chase if no active ordnance
				var offset := target_basis * Vector3(0, 4.5, 24.0)
				camera.position = target_pos + offset
				camera.look_at(target_pos, Vector3.UP)

		CamMode.FREE_CAM:
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			camera.position = _freecam_pos

		CamMode.CINEMATIC_DIRECTOR:
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			var cinematic_offset := Vector3(sin(current_time * 0.4) * 25.0, 6.0, cos(current_time * 0.4) * 25.0)
			camera.position = target_pos + cinematic_offset
			camera.look_at(target_pos, Vector3.UP)

		CamMode.TAC_VIEW:
			# Orthographic tactical satellite view (Ref: planning/replay_and_spectator_system.md)
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = 12000.0
			camera.position = Vector3(target_pos.x, 10000.0, target_pos.z)
			camera.rotation_degrees = Vector3(-90, 0, 0)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_scoreboard") or (event is InputEventKey and event.pressed and event.keycode == KEY_TAB):
		_scoreboard.toggle_scoreboard()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				_toggle_play_pause()
			KEY_F1:
				_set_cam_mode(CamMode.COCKPIT)
			KEY_F2:
				_set_cam_mode(CamMode.CHASE)
			KEY_F3:
				_set_cam_mode(CamMode.ORBIT)
			KEY_F4:
				_set_cam_mode(CamMode.FLYBY)
			KEY_F6:
				_set_cam_mode(CamMode.WEAPONS_CAM)
			KEY_F7:
				_set_cam_mode(CamMode.FREE_CAM)
			KEY_F8:
				_set_cam_mode(CamMode.CINEMATIC_DIRECTOR)
			KEY_F9:
				_set_cam_mode(CamMode.TAC_VIEW)
			KEY_LEFT:
				_seek_relative(-5.0)
			KEY_RIGHT:
				_seek_relative(5.0)
			KEY_BRACKETLEFT:
				_cycle_pilot(-1)
			KEY_BRACKETRIGHT:
				_cycle_pilot(1)

func _cycle_pilot(delta_idx: int) -> void:
	var roster: Array = replay_data.get("roster", [])
	var count: int = maxi(roster.size(), _aircraft_visuals.size())
	spectated_pilot_id = (spectated_pilot_id + delta_idx + count) % count

	if spectated_pilot_id < roster.size():
		var p = roster[spectated_pilot_id]
		spectated_pilot_name = str(p.get("name", "PILOT %d" % spectated_pilot_id))
		_pilot_name_lbl.text = "PILOT: %s [%s]" % [spectated_pilot_name, str(p.get("team", "BLUE")).to_upper()]
	else:
		_pilot_name_lbl.text = "PILOT: #%d" % spectated_pilot_id

func _set_cam_mode(mode: CamMode) -> void:
	active_cam_mode = mode
	var names := {
		CamMode.COCKPIT: "COCKPIT (F1)",
		CamMode.CHASE: "CHASE (F2)",
		CamMode.ORBIT: "ORBIT (F3)",
		CamMode.FLYBY: "FLYBY (F4)",
		CamMode.WEAPONS_CAM: "WEAPONS CAM (F6)",
		CamMode.FREE_CAM: "FREECAM (F7)",
		CamMode.CINEMATIC_DIRECTOR: "DIRECTOR (F8)",
		CamMode.TAC_VIEW: "TAC-VIEW (F9)"
	}
	_cam_mode_lbl.text = "CAMERA: " + names.get(mode, "CUSTOM")

func _toggle_play_pause() -> void:
	is_playing = not is_playing
	_update_play_pause_ui()

func _update_play_pause_ui() -> void:
	_play_pause_btn.text = "PLAY (SPACE)" if not is_playing else "PAUSE (SPACE)"

func _set_speed(spd: float) -> void:
	playback_speed = spd

func _seek_relative(offset: float) -> void:
	_seek_to(current_time + offset)

func _seek_to(target_t: float) -> void:
	current_time = clampf(target_t, 0.0, duration)
	_timeline_slider.set_value_no_signal(current_time)
	if _scoreboard != null and _scoreboard.visible:
		_scoreboard.update_replay_timepoint(current_time)

func _on_slider_value_changed(val: float) -> void:
	current_time = clampf(val, 0.0, duration)
	if _scoreboard != null and _scoreboard.visible:
		_scoreboard.update_replay_timepoint(current_time)
