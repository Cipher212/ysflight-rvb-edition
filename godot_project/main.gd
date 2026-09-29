extends Node3D

const AudioManagerScript = preload("res://audio_manager.gd")
const CombatVFXScript = preload("res://combat_vfx.gd")
const HUDTargetOverlayScript = preload("res://hud_target_overlay.gd")
const HUDScript = preload("res://hud.gd")
const RadarScopeScript = preload("res://radar_scope.gd")
const GForceEffectScript = preload("res://gforce_effect.gd")
const BenchmarkScript = preload("res://benchmark.gd")
const ControlsScript = preload("res://controls.gd")
const SettingsPanelScript = preload("res://settings_panel.gd")
const ControlsOverlayScript = preload("res://controls_overlay.gd")
const RespawnManagerScript = preload("res://respawn_manager.gd")
const AircraftFXScript = preload("res://aircraft_fx.gd")
const GraphicsSettingsScript = preload("res://graphics_settings.gd")

const FUEL_LOW_PCT: float = 20.0
const FUEL_REARM_PCT: float = 25.0

var ysflight_sim: YSFlightSimulation = null
var camera: Camera3D = null
var controls: Node = null
var settings_panel: CanvasLayer = null
var controls_overlay: Control = null
var audio_manager: Node3D = null
var telemetry_label: RichTextLabel = null
var fuel_banner_label: Label = null
var perf_label: Label = null
var combat_vfx: Node3D = null
var aircraft_fx: Node3D = null
var graphics_settings: Node = null
var hud_target_overlay: Control = null
var hud: Control = null
var radar_scope: Control = null
var gforce: CanvasLayer = null
var benchmark: Node = null
var benchmark_mode := false
# --ai-player: the YS dogfight AI flies the player jet (spectating); views, HUD and sound work as normal
var ai_player_mode := false

var _fuel_low_triggered := false
var _fuel_banner_timer := 0.0
var _latest_telemetry: Dictionary = {}
var _latest_air_tfms: Dictionary = {}

enum CamMode {
	COCKPIT = 1,        # F1: First-Person Cockpit View (with Free-Look + FOV Zoom)
	HORIZON_CHASE = 2,  # F2: Roll-Stabilized Horizon Orbit Chase Cam
	LOCKED_TAIL = 3,    # F3: Dynamic Roll-Locked Tail Chase Cam (with G-Lag)
	FLY_BY = 4,         # F4: Cinematic Airshow Fly-By Cam (Auto-Repositioning + Telephoto)
	PADLOCK_THREAT = 5, # F5: Combat Target Padlock / Threat Line-of-Sight Cam
	SPECTATOR_AI = 6,   # F6: AI / Bandit External Spectator Cam
	TOWER = 7,          # F7: Airfield Control Tower Cam (Auto-Telephoto Zoom)
	ACTION_MOUNT = 8    # F8: GoPro / Action Airframe Hard-Mounts (Wingtip, Tail, Shoulder, Belly)
}

var cam_mode: int = CamMode.HORIZON_CHASE
var cam_yaw: float = 0.0
var cam_pitch: float = -0.18
var cam_distance: float = 18.0
var is_dragging_cam: bool = false

# Cockpit free-look & zoom
var head_yaw: float = 0.0
var head_pitch: float = 0.0
var cockpit_fov: float = 65.0

# Locked Tail smoothing basis
var locked_basis: Basis = Basis.IDENTITY
var locked_basis_initialized: bool = false

# Fly-by state
var flyby_pos: Vector3 = Vector3.ZERO
var flyby_initialized: bool = false
var flyby_side: float = 1.0

# Padlock / Spectator / Tower / Action Mount indices
var padlock_index: int = 0
var spectator_index: int = 0
var tower_index: int = 0
var tower_zoom_mult: float = 1.0
var action_mount_index: int = 0

var cam_status_str: String = "F2: HORIZON CHASE"
var current_throttle: float = 0.85

const ACTION_MOUNTS = [
	{
		"name": "WINGTIP INWARD",
		"pos": Vector3(5.6, 0.35, 1.1),
		"look_target": Vector3(-1.5, 0.4, -2.2),
		"fov": 72.0
	},
	{
		"name": "TAIL FIN TOP",
		"pos": Vector3(0.0, 3.35, 6.2),
		"look_target": Vector3(0.0, 0.4, -12.0),
		"fov": 70.0
	},
	{
		"name": "OVER-THE-SHOULDER",
		"pos": Vector3(-0.85, 1.35, 0.4),
		"look_target": Vector3(0.0, 0.5, -15.0),
		"fov": 65.0
	},
	{
		"name": "BELLY / GEAR BAY",
		"pos": Vector3(0.0, -1.35, 4.5),
		"look_target": Vector3(0.0, -0.7, -15.0),
		"fov": 72.0
	}
]

func _ready():
	# Configure the scene's directional light to match YSFlight's sun without double-lighting
	if has_node("DirectionalLight3D"):
		var sun = $DirectionalLight3D as DirectionalLight3D
		sun.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
		sun.light_energy = 0.85
	else:
		var light = DirectionalLight3D.new()
		light.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
		light.light_energy = 0.85
		add_child(light)

	ysflight_sim = YSFlightSimulation.new()
	add_child(ysflight_sim)

	camera = Camera3D.new()
	camera.near = 1.5
	camera.far = 80000.0
	camera.fov = 60.0
	add_child(camera)

	# Initialize the YSFlight C++ engine and load the Luavi 16v16 RvB Stress Test mission
	ysflight_sim.initialize_simulation()
	benchmark_mode = "--benchmark" in OS.get_cmdline_user_args()
	if benchmark_mode:
		ysflight_sim.set_random_seed(12345)
	ysflight_sim.load_yfs("res://mission/luavi_16v16.yfs")
	if "--no-interp" in OS.get_cmdline_user_args():
		ysflight_sim.set_interpolation_enabled(false) # A/B test: show the latest physics tick, no blending
	ai_player_mode = benchmark_mode or "--ai-player" in OS.get_cmdline_user_args()
	if ai_player_mode:
		ysflight_sim.enable_player_autopilot()

	if ysflight_sim.has_method("get_player_telemetry"):
		var init_t: Dictionary = ysflight_sim.get_player_telemetry()
		if init_t.has("throttle"):
			current_throttle = float(init_t.get("throttle", 0.85))
		if ysflight_sim.has_method("log_to_crashlog"):
			ysflight_sim.log_to_crashlog("GDScript _ready() complete. Player weapon=%s, AIM120=%d, AIM9=%d, FuelTank=%d" % [
				str(init_t.get("weapon_name", "NONE")),
				int(init_t.get("aim120_count", 0)),
				int(init_t.get("aim9_count", 0)),
				int(init_t.get("fuel_tank_count", 0))
			])

	# Instantiate 3D Combat & Ordnance VFX Manager (Tracers, Missile Smoke Trails, Explosions)
	combat_vfx = CombatVFXScript.new()
	combat_vfx.name = "CombatVFX"
	add_child(combat_vfx)

	aircraft_fx = AircraftFXScript.new()
	aircraft_fx.name = "AircraftFX"
	add_child(aircraft_fx)

	audio_manager = AudioManagerScript.new()
	audio_manager.name = "AudioManager"
	add_child(audio_manager)
	audio_manager.setup(ysflight_sim)

	var env = WorldEnvironment.new()
	var env_res = Environment.new()
	
	# Use a ProceduralSkyMaterial to draw the infinite sky and ground planes without Z-fighting
	var sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = ysflight_sim.get_sky_color()
	sky_mat.sky_horizon_color = sky_mat.sky_top_color
	sky_mat.ground_bottom_color = ysflight_sim.get_ground_color()
	sky_mat.ground_horizon_color = sky_mat.ground_bottom_color
	sky_mat.sun_angle_max = 0.0 # Hide procedural sun disk as we have a DirectionalLight
	
	var sky = Sky.new()
	sky.sky_material = sky_mat
	
	env_res.background_mode = Environment.BG_SKY
	env_res.sky = sky
	
	env_res.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env_res.ambient_light_color = Color(0.65, 0.65, 0.65)
	env_res.ambient_light_energy = 1.0
	env_res.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = env_res
	add_child(env)

	# G-Force effects (CanvasLayer layer 15 above HUD layer)
	gforce = GForceEffectScript.new()
	gforce.name = "GForce"
	add_child(gforce)

	# --- Setup Real Helmet HUD & Placeholder Layer ---
	var hud_layer = CanvasLayer.new()
	hud_layer.name = "HUDLayer"
	add_child(hud_layer)

	# Real vector helmet HUD
	hud = HUDScript.new()
	hud.name = "HUD"
	hud_layer.add_child(hud)

	# Tactical heading-up radar scope
	radar_scope = RadarScopeScript.new()
	radar_scope.name = "RadarScope"
	hud_layer.add_child(radar_scope)

	# 2D Target Container Boxes, LOCKED Diamond, Gun Lead Pipper & Threat Banner (placeholder hidden)
	hud_target_overlay = HUDTargetOverlayScript.new()
	hud_target_overlay.name = "HUDTargetOverlay"
	hud_target_overlay.visible = false
	hud_layer.add_child(hud_target_overlay)

	var margin_container = MarginContainer.new()
	margin_container.name = "MarginContainer"
	margin_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin_container.add_theme_constant_override("margin_left", 20)
	margin_container.add_theme_constant_override("margin_top", 20)
	margin_container.add_theme_constant_override("margin_right", 20)
	margin_container.add_theme_constant_override("margin_bottom", 20)
	hud_layer.add_child(margin_container)
	margin_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	fuel_banner_label = Label.new()
	fuel_banner_label.name = "FuelBannerLabel"
	fuel_banner_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fuel_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fuel_banner_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	fuel_banner_label.offset_top = 70.0
	fuel_banner_label.add_theme_color_override("font_color", Color(1.0, 0.22, 0.22, 0.98))
	fuel_banner_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	fuel_banner_label.add_theme_constant_override("outline_size", 4)
	fuel_banner_label.add_theme_font_size_override("font_size", 20)
	fuel_banner_label.text = "FUEL LOW"
	fuel_banner_label.visible = false
	hud_layer.add_child(fuel_banner_label)

	var vbox = VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin_container.add_child(vbox)
	
	var hbox = HBoxContainer.new()
	hbox.name = "HBoxContainer"
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(hbox)

	telemetry_label = RichTextLabel.new()
	telemetry_label.name = "TelemetryLabel"
	telemetry_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	telemetry_label.bbcode_enabled = true
	telemetry_label.fit_content = true
	telemetry_label.scroll_active = false
	telemetry_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	telemetry_label.custom_minimum_size = Vector2(460, 160)
	telemetry_label.add_theme_color_override("default_color", Color(0.35, 1.0, 0.35))
	telemetry_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	telemetry_label.add_theme_constant_override("outline_size", 4)
	telemetry_label.add_theme_font_size_override("normal_font_size", 20)
	telemetry_label.visible = false
	hbox.add_child(telemetry_label)
	
	var spacer = Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)
	
	perf_label = Label.new()
	perf_label.name = "PerfLabel"
	perf_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	perf_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	perf_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.35))
	perf_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	perf_label.add_theme_constant_override("outline_size", 4)
	perf_label.add_theme_font_size_override("font_size", 16)
	perf_label.visible = false
	hbox.add_child(perf_label)

	controls = ControlsScript.new()
	controls.name = "Controls"
	add_child(controls)
	controls.setup(self, ysflight_sim)
	hud.setup(controls)
	radar_scope.setup(controls)
	aircraft_fx.setup(self, ysflight_sim, controls)

	graphics_settings = GraphicsSettingsScript.new()
	graphics_settings.name = "GraphicsSettings"
	add_child(graphics_settings)
	graphics_settings.setup(self, controls)

	# Automatic respawn + placeholder flight setup panel (F10)
	var respawn_manager := RespawnManagerScript.new()
	respawn_manager.name = "RespawnManager"
	add_child(respawn_manager)
	respawn_manager.setup(self, ysflight_sim)

	settings_panel = SettingsPanelScript.new()
	settings_panel.name = "SettingsPanel"
	add_child(settings_panel)
	settings_panel.setup(controls)

	controls_overlay = ControlsOverlayScript.new()
	controls_overlay.name = "ControlsOverlay"
	hud_layer.add_child(controls_overlay)
	controls_overlay.setup(self, controls)

	print("YSFlight Ready: [F1] Cockpit [F2] Exterior | [Space] Weapon [Ctrl/LMB] Gun [2] Cycle [4] Flare | [Tab] Afterburner [G] Gear | [Esc] Settings [F10] Flight setup")
	_set_camera_mode(CamMode.HORIZON_CHASE, false)
	_update_camera(0.016)

	if benchmark_mode:
		benchmark = BenchmarkScript.new()
		benchmark.name = "Benchmark"
		add_child(benchmark)
		benchmark.setup(self)

func _set_camera_mode(new_mode: int, same_key_pressed: bool):
	var prev_mode := cam_mode
	cam_mode = new_mode

	var is_cockpit := (cam_mode == CamMode.COCKPIT)
	if ysflight_sim != null and ysflight_sim.has_method("set_cockpit_cull_mode"):
		ysflight_sim.set_cockpit_cull_mode(is_cockpit)

	if is_cockpit:
		camera.near = 0.15
		if same_key_pressed:
			head_yaw = 0.0
			head_pitch = 0.0
			cockpit_fov = 65.0
	else:
		camera.near = 1.5
		camera.fov = 60.0

	match cam_mode:
		CamMode.HORIZON_CHASE:
			if same_key_pressed:
				cam_yaw = 0.0
				cam_pitch = -0.18
		CamMode.LOCKED_TAIL:
			if prev_mode != CamMode.LOCKED_TAIL:
				locked_basis_initialized = false
			if same_key_pressed:
				cam_yaw = 0.0
				cam_pitch = -0.12
		CamMode.FLY_BY:
			# Always trigger a fresh fly-by setup when F4 is pressed
			flyby_initialized = false
		CamMode.PADLOCK_THREAT:
			if same_key_pressed:
				padlock_index += 1
		CamMode.SPECTATOR_AI:
			if same_key_pressed:
				spectator_index += 1
		CamMode.TOWER:
			if prev_mode != CamMode.TOWER:
				_select_nearest_tower()
				tower_zoom_mult = 1.0
			elif same_key_pressed:
				tower_index += 1
		CamMode.ACTION_MOUNT:
			if same_key_pressed:
				action_mount_index = (action_mount_index + 1) % ACTION_MOUNTS.size()

func _select_nearest_tower():
	if ysflight_sim == null or not ysflight_sim.has_method("get_tower_positions"):
		return
	var towers: PackedVector3Array = ysflight_sim.get_tower_positions()
	if towers.is_empty():
		tower_index = 0
		return
	var player_pos: Vector3 = ysflight_sim.get_player_transform().origin
	var best_idx: int = 0
	var best_dist_sq: float = INF
	for i in range(towers.size()):
		var d2 := player_pos.distance_squared_to(towers[i])
		if d2 < best_dist_sq:
			best_dist_sq = d2
			best_idx = i
	tower_index = best_idx

func _unhandled_input(event: InputEvent):
	# Benchmark runs follow a fixed camera script; ignore keyboard/mouse so runs are comparable
	if benchmark_mode:
		return

	if ai_player_mode:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_LEFT:
				is_dragging_cam = event.pressed
			elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
				if cam_mode == CamMode.COCKPIT:
					cockpit_fov = clamp(cockpit_fov - 4.0, 22.0, 85.0)
				elif cam_mode == CamMode.TOWER:
					tower_zoom_mult = clamp(tower_zoom_mult * 0.85, 0.2, 4.0)
				else:
					cam_distance = max(3.5, cam_distance * 0.88)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
				if cam_mode == CamMode.COCKPIT:
					cockpit_fov = clamp(cockpit_fov + 4.0, 22.0, 85.0)
				elif cam_mode == CamMode.TOWER:
					tower_zoom_mult = clamp(tower_zoom_mult * 1.18, 0.2, 4.0)
				else:
					cam_distance = min(2000.0, cam_distance * 1.14)
		elif event is InputEventMouseMotion and is_dragging_cam:
			if cam_mode == CamMode.COCKPIT:
				head_yaw = clamp(head_yaw - event.relative.x * 0.006, -2.65, 2.65)
				head_pitch = clamp(head_pitch - event.relative.y * 0.006, -1.25, 1.35)
			else:
				cam_yaw -= event.relative.x * 0.008
				cam_pitch = clamp(cam_pitch - event.relative.y * 0.008, -1.45, 1.45)
		elif event is InputEventKey and event.pressed and not event.echo:
			match event.keycode:
				KEY_F1:
					_set_camera_mode(CamMode.COCKPIT, cam_mode == CamMode.COCKPIT)
				KEY_F2:
					_set_camera_mode(CamMode.HORIZON_CHASE, cam_mode == CamMode.HORIZON_CHASE)
				KEY_F3:
					_set_camera_mode(CamMode.LOCKED_TAIL, cam_mode == CamMode.LOCKED_TAIL)
				KEY_F4:
					_set_camera_mode(CamMode.FLY_BY, cam_mode == CamMode.FLY_BY)
				KEY_F5:
					_set_camera_mode(CamMode.PADLOCK_THREAT, cam_mode == CamMode.PADLOCK_THREAT)
				KEY_F6:
					_set_camera_mode(CamMode.SPECTATOR_AI, cam_mode == CamMode.SPECTATOR_AI)
				KEY_F7:
					_set_camera_mode(CamMode.TOWER, cam_mode == CamMode.TOWER)
				KEY_F8:
					_set_camera_mode(CamMode.ACTION_MOUNT, cam_mode == CamMode.ACTION_MOUNT)
				KEY_C:
					head_yaw = 0.0
					head_pitch = 0.0
					cockpit_fov = 65.0
					cam_yaw = 0.0
					cam_pitch = -0.18
					tower_zoom_mult = 1.0
				KEY_TAB, KEY_BRACKETRIGHT:
					if cam_mode == CamMode.PADLOCK_THREAT:
						padlock_index += 1
					elif cam_mode == CamMode.TOWER:
						tower_index += 1
					elif cam_mode == CamMode.ACTION_MOUNT:
						action_mount_index = (action_mount_index + 1) % ACTION_MOUNTS.size()
					else:
						spectator_index += 1
						if cam_mode != CamMode.SPECTATOR_AI:
							_set_camera_mode(CamMode.SPECTATOR_AI, false)
				KEY_BRACKETLEFT:
					if cam_mode == CamMode.PADLOCK_THREAT:
						padlock_index = max(0, padlock_index - 1)
					elif cam_mode == CamMode.TOWER:
						tower_index = max(0, tower_index - 1)
					elif cam_mode == CamMode.ACTION_MOUNT:
						action_mount_index = (action_mount_index - 1 + ACTION_MOUNTS.size()) % ACTION_MOUNTS.size()
					else:
						spectator_index = max(0, spectator_index - 1)

func _physics_process(_delta: float):
	pass

# Camera, effects and HUD run once per rendered frame. _physics_process only feeds inputs to the sim,
# so when FPS drops the extra catch-up physics ticks don't repeat this work.
func _process(delta: float):
	if ysflight_sim == null:
		return
	# PERF: per-section timers, logged to crashlog/latest_run.txt every 300 frames
	var t0 := Time.get_ticks_usec()
	_update_camera(delta)
	var t1 := Time.get_ticks_usec()
	var t2 := t1
	if ysflight_sim.has_method("get_active_weapons") and ysflight_sim.has_method("get_active_explosions"):
		var wpns: Array = ysflight_sim.get_active_weapons()
		var exps: Array = ysflight_sim.get_active_explosions()
		t2 = Time.get_ticks_usec()
		if combat_vfx != null:
			combat_vfx.update_vfx(delta, wpns, exps)
		if aircraft_fx != null:
			aircraft_fx.update_fx(delta, camera, _latest_air_tfms)
	elif aircraft_fx != null:
		t2 = Time.get_ticks_usec()
		aircraft_fx.update_fx(delta, camera, _latest_air_tfms)
	var t3 := Time.get_ticks_usec()
	_update_hud(delta)
	var t4 := Time.get_ticks_usec()
	if audio_manager != null:
		audio_manager.update(delta, camera, cam_mode == CamMode.COCKPIT, _latest_telemetry)
	var t5 := Time.get_ticks_usec()
	_perf_accumulate([t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4])
	if benchmark != null:
		benchmark.record_frame(t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4)

var _perf_sum := [0, 0, 0, 0, 0]
var _perf_max := [0, 0, 0, 0, 0]
var _perf_ticks := 0
var _perf_start_tick := 0
var _perf_start_usec := 0

func _perf_accumulate(us: Array) -> void:
	if _perf_ticks == 0:
		_perf_start_tick = Engine.get_physics_frames()
		_perf_start_usec = Time.get_ticks_usec()
	for i in 5:
		_perf_sum[i] += us[i]
		_perf_max[i] = max(_perf_max[i], us[i])
	_perf_ticks += 1
	if _perf_ticks < 300:
		return
	var frames: int = _perf_ticks
	var ticks: int = Engine.get_physics_frames() - _perf_start_tick
	var secs: float = max((Time.get_ticks_usec() - _perf_start_usec) / 1e6, 0.001)
	var names := ["camera", "weapon/explosion fetch", "combat_vfx", "hud", "audio"]
	var parts := []
	for i in 5:
		parts.append("%s %.2f/%.2f" % [names[i], _perf_sum[i] / float(frames) / 1000.0, _perf_max[i] / 1000.0])
	ysflight_sim.log_to_crashlog("PERF GD (avg/max ms per frame): " + " | ".join(parts))
	if combat_vfx != null and combat_vfx.has_method("perf_report"):
		ysflight_sim.log_to_crashlog(combat_vfx.perf_report())
	if aircraft_fx != null and aircraft_fx.has_method("perf_report"):
		ysflight_sim.log_to_crashlog(aircraft_fx.perf_report())
	ysflight_sim.log_to_crashlog("PERF FRAME: fps %.1f | physics ticks per frame %.2f | draw calls %d | objects %d | nodes %d | primitives %d | render cpu %.2f ms" % [
		frames / secs, float(ticks) / frames,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	_perf_sum = [0, 0, 0, 0, 0]
	_perf_max = [0, 0, 0, 0, 0]
	_perf_ticks = 0

func _safe_look_at(cam: Camera3D, target: Vector3, up: Vector3 = Vector3.UP):
	var diff := target - cam.global_position
	var d_len := diff.length()
	if d_len < 0.001:
		return
	var dir := diff / d_len
	var safe_up := up.normalized()
	if abs(dir.dot(safe_up)) > 0.995:
		safe_up = Vector3.FORWARD if abs(dir.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	cam.look_at(target, safe_up)

func _get_non_player_airplanes(transforms: Dictionary, player_iff: int, enemies_first: bool) -> Array:
	var enemies: Array = []
	var others: Array = []
	for k in transforms.keys():
		var st: Dictionary = transforms[k]
		if st.get("is_player", false):
			continue
		if not st.get("is_alive", true):
			continue
		if enemies_first and int(st.get("iff", -1)) != player_iff:
			enemies.append(st)
		else:
			others.append(st)
	var combined: Array = []
	combined.append_array(enemies)
	combined.append_array(others)
	return combined

func _update_camera(delta: float):
	if ysflight_sim == null or camera == null:
		return

	var player_tfm: Transform3D = ysflight_sim.get_player_transform()
	var player_pos: Vector3 = player_tfm.origin
	var t_dict: Dictionary = ysflight_sim.get_player_telemetry() if ysflight_sim.has_method("get_player_telemetry") else {}
	var cockpit_local: Vector3 = t_dict.get("cockpit_local", Vector3(0.0, 0.9, -3.15))
	var player_vel: Vector3 = t_dict.get("velocity", -player_tfm.basis.z * 100.0)
	var player_iff: int = int(t_dict.get("iff", 0))
	var transforms: Dictionary = ysflight_sim.get_airplane_transforms()

	match cam_mode:
		CamMode.COCKPIT:
			# F1: First-Person Cockpit View
			camera.fov = cockpit_fov
			camera.global_position = player_tfm * cockpit_local
			var head_rot := Basis.from_euler(Vector3(head_pitch, head_yaw, 0.0))
			camera.global_basis = (player_tfm.basis * head_rot).orthonormalized()
			cam_status_str = "F1: COCKPIT VIEW (FOV %d°)" % int(round(cockpit_fov))

		CamMode.HORIZON_CHASE:
			# F2: Roll-Stabilized Horizon Orbit Chase Cam
			var ac_euler: Vector3 = player_tfm.basis.get_euler()
			var no_roll_basis := Basis.from_euler(Vector3(ac_euler.x, ac_euler.y, 0.0))
			var orbit_basis := Basis.from_euler(Vector3(cam_pitch, cam_yaw, 0.0))
			var cam_offset: Vector3 = no_roll_basis * (orbit_basis * Vector3(0.0, 0.0, cam_distance))
			camera.global_position = player_pos + cam_offset
			_safe_look_at(camera, player_pos, Vector3.UP)
			cam_status_str = "F2: HORIZON CHASE (%.0fm)" % cam_distance

		CamMode.LOCKED_TAIL:
			# F3: Dynamic Roll-Locked Tail Chase Cam (rolls 1:1 with aircraft + subtle G-lag)
			if not locked_basis_initialized:
				locked_basis = player_tfm.basis.orthonormalized()
				locked_basis_initialized = true
			else:
				locked_basis = locked_basis.orthonormalized().slerp(player_tfm.basis.orthonormalized(), clamp(delta * 10.0, 0.0, 1.0))
			var local_orbit := Basis.from_euler(Vector3(cam_pitch * 0.4, cam_yaw, 0.0))
			var offset_local := local_orbit * Vector3(0.0, 2.8, cam_distance * 0.85)
			camera.global_position = player_pos + locked_basis * offset_local
			var look_ahead := player_pos + player_tfm.basis * Vector3(0.0, 0.8, -8.0)
			_safe_look_at(camera, look_ahead, locked_basis.y)
			cam_status_str = "F3: LOCKED TAIL CAM (%.0fm)" % (cam_distance * 0.85)

		CamMode.FLY_BY:
			# F4: Cinematic Airshow Fly-By Camera
			var dist_to_cam := player_pos.distance_to(flyby_pos)
			if not flyby_initialized or dist_to_cam > 550.0:
				var fwd := player_vel.normalized() if player_vel.length() > 5.0 else (-player_tfm.basis.z).normalized()
				var right := fwd.cross(Vector3.UP)
				if right.length_squared() < 0.001:
					right = Vector3.RIGHT
				else:
					right = right.normalized()
				flyby_side = -flyby_side
				flyby_pos = player_pos + fwd * 300.0 + right * (36.0 * flyby_side) + Vector3(0.0, 10.0, 0.0)
				flyby_pos.y = max(flyby_pos.y, 3.5)
				flyby_initialized = true
				dist_to_cam = player_pos.distance_to(flyby_pos)

			camera.global_position = flyby_pos
			camera.fov = clamp(2400.0 / max(dist_to_cam, 25.0), 18.0, 65.0)
			_safe_look_at(camera, player_pos, Vector3.UP)
			cam_status_str = "F4: CINEMATIC FLY-BY (%.0fm)" % dist_to_cam

		CamMode.PADLOCK_THREAT:
			# F5: Combat Target Padlock / Threat Cam (frames player jet while looking at bandit)
			var targets := _get_non_player_airplanes(transforms, player_iff, true)
			if targets.size() > 0:
				var tgt: Dictionary = targets[padlock_index % targets.size()]
				var tgt_pos: Vector3 = tgt["pos"]
				var tgt_id: String = tgt.get("identifier", "TARGET")
				var is_enemy: bool = int(tgt.get("iff", -1)) != player_iff
				var to_tgt: Vector3 = tgt_pos - player_pos
				var dist_m: float = to_tgt.length()
				var los_dir: Vector3 = to_tgt / max(dist_m, 0.001)
				camera.global_position = player_pos - los_dir * (cam_distance * 0.9) + player_tfm.basis.y * 3.2
				_safe_look_at(camera, tgt_pos, Vector3.UP)
				cam_status_str = "F5: PADLOCK [%s: %s | %.1f km]" % [
					"BANDIT" if is_enemy else "ALLY", tgt_id, dist_m / 1000.0
				]
			else:
				camera.global_position = player_pos + Vector3(0.0, 5.0, cam_distance)
				_safe_look_at(camera, player_pos, Vector3.UP)
				cam_status_str = "F5: PADLOCK [NO ACTIVE TARGETS]"

		CamMode.SPECTATOR_AI:
			# F6: AI / Bandit Spectator Camera
			var ai_list := _get_non_player_airplanes(transforms, player_iff, true)
			if ai_list.size() > 0:
				var st: Dictionary = ai_list[spectator_index % ai_list.size()]
				var ai_tfm: Transform3D = st["transform"]
				var ai_pos: Vector3 = ai_tfm.origin
				var ai_id: String = st.get("identifier", "AI")
				var is_enemy: bool = int(st.get("iff", -1)) != player_iff
				var ac_euler: Vector3 = ai_tfm.basis.get_euler()
				var no_roll_basis := Basis.from_euler(Vector3(ac_euler.x, ac_euler.y, 0.0))
				var orbit_basis := Basis.from_euler(Vector3(cam_pitch, cam_yaw, 0.0))
				camera.global_position = ai_pos + no_roll_basis * (orbit_basis * Vector3(0.0, 0.0, cam_distance))
				_safe_look_at(camera, ai_pos, Vector3.UP)
				cam_status_str = "F6: SPECTATOR [%d/%d %s: %s]" % [
					(spectator_index % ai_list.size()) + 1, ai_list.size(),
					"BANDIT" if is_enemy else "ALLY", ai_id
				]
			else:
				camera.global_position = player_pos + Vector3(0.0, 5.0, cam_distance)
				_safe_look_at(camera, player_pos, Vector3.UP)
				cam_status_str = "F6: SPECTATOR [NO AI AIRCRAFT]"

		CamMode.TOWER:
			# F7: Airfield Control Tower Camera with Automatic Telephoto Zoom
			var towers: PackedVector3Array = ysflight_sim.get_tower_positions() if ysflight_sim.has_method("get_tower_positions") else PackedVector3Array()
			var twr_pos := Vector3(50.0, 28.0, 50.0)
			var twr_count := towers.size()
			if twr_count > 0:
				twr_pos = towers[tower_index % twr_count]
				# Elevate slightly if tower coordinate is at ground level
				if twr_pos.y < 8.0:
					twr_pos.y += 18.0
			camera.global_position = twr_pos
			var dist_to_twr := player_pos.distance_to(twr_pos)
			camera.fov = clamp((1900.0 / max(dist_to_twr, 25.0)) * tower_zoom_mult, 6.0, 60.0)
			_safe_look_at(camera, player_pos, Vector3.UP)
			cam_status_str = "F7: TOWER CAM [#%d/%d | %.1f km | FOV %d°]" % [
				(tower_index % max(twr_count, 1)) + 1, max(twr_count, 1), dist_to_twr / 1000.0, int(round(camera.fov))
			]

		CamMode.ACTION_MOUNT:
			# F8: Hard-Mounted Airframe Action / GoPro Cameras
			var mount: Dictionary = ACTION_MOUNTS[action_mount_index % ACTION_MOUNTS.size()]
			camera.fov = float(mount["fov"])
			var mount_world_pos: Vector3 = player_tfm * mount["pos"]
			var mount_world_target: Vector3 = player_tfm * mount["look_target"]
			camera.global_position = mount_world_pos
			_safe_look_at(camera, mount_world_target, player_tfm.basis.y)
			cam_status_str = "F8: ACTION MOUNT [%s]" % mount["name"]

func _update_hud(delta: float = 0.016):
	var show_debug: bool = controls != null and bool(controls.get_value("show_debug_text", false))
	if perf_label != null:
		perf_label.visible = show_debug
		if show_debug:
			var fps: int = int(Engine.get_frames_per_second())
			var process_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			var physics_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			var frame_ms: float = 1000.0 / float(fps) if fps > 0 else 0.0
			perf_label.text = (
				"FPS: %d | Frame: %.1f ms\n" +
				"CPU (Render/Sim): %.2f / %.2f ms\n" +
				"CAM: %s\n" +
				"[F1] Cockpit [F2] Exterior | [Space] Weapon [Ctrl/LMB] Gun [2] Cycle [4] Flare\n" +
				"[Tab] Afterburner [G] Gear | [Esc] Settings [F10] Flight setup"
			) % [
				fps, frame_ms, process_ms, physics_ms, cam_status_str
			]

	if ysflight_sim.has_method("get_player_telemetry"):
		var t: Dictionary = ysflight_sim.get_player_telemetry()
		_latest_telemetry = t
		var air_tfms: Dictionary = ysflight_sim.get_airplane_transforms()
		_latest_air_tfms = air_tfms
		# Only the locked ground target is needed (fetching all ~500 ground objects every frame cost ~1 ms)
		var gnd_tfms: Dictionary = {}
		var locked_gnd: int = int(t.get("locked_ground_target_key", -1))
		if locked_gnd >= 0:
			var g_state: Dictionary = ysflight_sim.get_ground_transform(locked_gnd)
			if not g_state.is_empty():
				gnd_tfms[locked_gnd] = g_state

		if hud != null:
			hud.update_hud(delta, camera, ysflight_sim.get_player_transform(), cam_mode, t, air_tfms, gnd_tfms)

		if radar_scope != null:
			radar_scope.update_radar(camera, ysflight_sim.get_player_transform(), t, air_tfms, cam_mode)

		if gforce != null:
			var is_alive: bool = bool(t.get("is_alive", true))
			var g_val: float = float(t.get("g_force", 1.0))
			var is_paused: bool = get_tree().paused
			gforce.update_effect(delta, g_val, is_alive, ai_player_mode, is_paused)

		# Keep placeholder target overlay invisible and stopped
		if hud_target_overlay != null:
			hud_target_overlay.visible = false

		# Fuel low warning logic: kept in code for placeholder references, kept invisible
		var fuel_pct: float = float(t.get("fuel_pct", 100.0))
		if fuel_pct < FUEL_LOW_PCT:
			if not _fuel_low_triggered:
				_fuel_low_triggered = true
				_fuel_banner_timer = 4.0
		elif fuel_pct > FUEL_REARM_PCT:
			_fuel_low_triggered = false

		if fuel_banner_label != null:
			fuel_banner_label.visible = false

		if telemetry_label != null:
			telemetry_label.visible = false
			var gear_str := "DWN" if t.get("gear", 1.0) >= 0.99 else ("UP" if t.get("gear", 1.0) <= 0.01 else "MOV")
			var ab_str := " [AB]" if t.get("afterburner", false) else ""
			var ctrl_str: String = controls.get_active_stick_device_name().to_upper() if controls != null else "KEYBOARD"
			var alive_str := "" if t.get("is_alive", true) else " [DESTROYED]"

			var wpn_name: String = t.get("weapon_name", "GUN")
			var wpn_type: int = int(t.get("weapon_type", 0))
			var wpn_ammo: int = int(t.get("ammo_count", 0))
			var gun_ammo: int = int(t.get("gun_ammo", 0))
			var flr_ammo: int = int(t.get("flare_count", 0))

			# Lock status string (only shows LOCKED when a guided missile is selected and locked)
			var lock_str := "NONE"
			var locked_air_key: int = int(t.get("locked_air_target_key", -1))
			var locked_gnd_key: int = int(t.get("locked_ground_target_key", -1))
			if (wpn_type == 1 or wpn_type == 6 or wpn_type == 10) and locked_air_key >= 0 and air_tfms.has(locked_air_key):
				var tgt_d: Dictionary = air_tfms[locked_air_key]
				lock_str = "LOCKED [%s]" % tgt_d.get("identifier", "BANDIT")
			elif wpn_type == 2 and locked_gnd_key >= 0 and gnd_tfms.has(locked_gnd_key):
				var gtgt_d: Dictionary = gnd_tfms[locked_gnd_key]
				lock_str = "LOCKED [%s]" % gtgt_d.get("identifier", "GROUND")

			# Fuel text flashing red (2 Hz: 0.25 s red, 0.25 s normal)
			var fuel_str := "FUEL: %d%%" % int(round(fuel_pct))
			if fuel_pct < FUEL_LOW_PCT:
				var time_sec: float = float(Time.get_ticks_msec()) * 0.001
				var is_red_half: bool = fmod(time_sec, 0.5) < 0.25
				if is_red_half:
					fuel_str = "[color=#ff3030]%s[/color]" % fuel_str

			telemetry_label.text = (
				"ACFT: %s%s\n" +
				"SPD: %d kts (Mach %.2f)\n" +
				"ALT: %d ft (%d m) | VSI: %+d fpm\n" +
				"HDG: %03d° | PITCH: %+.1f° | BANK: %+.1f°\n" +
				"THR: %d%%%s | G: %.1fG | %s\n" +
				"WPN: [%s: %d] | GUN: %d | FLR: %d | TARGET: %s\n" +
				"GEAR: %s | FLAP: %d%% | CTRL: %s"
			) % [
				t.get("identifier", "F-16"),
				alive_str,
				int(round(t.get("speed_kt", 0.0))),
				t.get("mach", 0.0),
				int(round(t.get("altitude_ft", 0.0))),
				int(round(t.get("altitude_m", 0.0))),
				int(round(t.get("vsi_fpm", 0.0))),
				int(round(t.get("heading_deg", 0.0))) % 360,
				t.get("pitch_deg", 0.0),
				t.get("bank_deg", 0.0),
				int(round(t.get("throttle", 0.0) * 100.0)),
				ab_str,
				t.get("g_force", 1.0),
				fuel_str,
				wpn_name,
				wpn_ammo,
				gun_ammo,
				flr_ammo,
				lock_str,
				gear_str,
				int(round(t.get("flaps", 0.0) * 100.0)),
				ctrl_str
			]

