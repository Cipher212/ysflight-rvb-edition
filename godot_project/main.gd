extends Node3D

# Composition root: creates the sim and every subsystem, then runs the per-frame order:
# camera -> effects -> HUD / radar / G effects -> audio. The sim node itself runs first (process priority
# -100: interpolation + model sync) and its physics tick runs after the controls (priority +100).
# Command-line flags (after "--"): --benchmark, --ai-player, --no-interp. Notes: logs/.

const AudioManagerScript = preload("res://audio_manager.gd")
const HUDScript = preload("res://hud.gd")
const RadarScopeScript = preload("res://radar_scope.gd")
const GForceEffectScript = preload("res://gforce_effect.gd")
const BenchmarkScript = preload("res://benchmark.gd")
const ControlsScript = preload("res://controls.gd")
const SettingsPanelScript = preload("res://settings_panel.gd")
const ControlsOverlayScript = preload("res://controls_overlay.gd")
const RespawnManagerScript = preload("res://respawn_manager.gd")
const GraphicsSettingsScript = preload("res://graphics_settings.gd")
const CameraRigScript = preload("res://camera/camera_rig.gd")
const PuffSystemScript = preload("res://fx/puff_system.gd")
const ExplosionFXScript = preload("res://fx/explosion_fx.gd")
const CrashFXScript = preload("res://fx/crash_fx.gd")
const DebugOverlayScript = preload("res://ui/debug_overlay.gd")
const FpsMonitorScript = preload("res://ui/fps_monitor.gd")
const PerfLogScript = preload("res://core/perf_log.gd")
const TestRunnerScript = preload("res://tests/test_runner.gd")

const MISSION := "res://mission/luavi_16v16.yfs"
const BENCHMARK_SEED := 12345

var ysflight_sim: YSFlightSimulation = null
var camera_rig: Node = null
var camera: Camera3D = null
var controls: Node = null
var audio_manager: Node3D = null
var hud: Control = null
var radar_scope: Control = null
var gforce: CanvasLayer = null
var benchmark: Node = null
var benchmark_mode := false
var ai_player_mode := false # --ai-player: the YS dogfight AI flies the player jet (spectating)
var test_mode := false      # --run-tests: tests/test_runner.gd plays through the mission and quits

var _puffs: Node3D = null
var _explosions: Node3D = null
var _crashes: Node = null
var _debug_overlay: Control = null
var _perf_log: RefCounted = null
var _perf_us := PackedInt64Array([0, 0, 0, 0, 0])

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	benchmark_mode = "--benchmark" in args
	test_mode = "--run-tests" in args
	ai_player_mode = benchmark_mode or "--ai-player" in args

	_add_sun()
	ysflight_sim = YSFlightSimulation.new()
	add_child(ysflight_sim)
	ysflight_sim.initialize_simulation()
	if benchmark_mode or test_mode:
		ysflight_sim.set_random_seed(BENCHMARK_SEED)
	ysflight_sim.load_yfs(MISSION)
	if "--no-interp" in args:
		ysflight_sim.set_interpolation_enabled(false) # A/B test: show the latest physics tick, no blending
	if ai_player_mode:
		ysflight_sim.enable_player_autopilot()
	_add_environment()

	controls = ControlsScript.new()
	controls.name = "Controls"
	add_child(controls)
	controls.setup(self, ysflight_sim)

	camera_rig = CameraRigScript.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	camera_rig.setup(ysflight_sim, controls, ai_player_mode, benchmark_mode)
	camera = camera_rig.camera

	_puffs = PuffSystemScript.new()
	add_child(_puffs)
	_explosions = ExplosionFXScript.new()
	_explosions.name = "Explosions"
	add_child(_explosions)
	_explosions.setup(_puffs)
	_crashes = CrashFXScript.new()
	_crashes.name = "CrashSites"
	add_child(_crashes)
	_crashes.setup(_puffs)

	audio_manager = AudioManagerScript.new()
	audio_manager.name = "AudioManager"
	add_child(audio_manager)
	audio_manager.setup(ysflight_sim)

	gforce = GForceEffectScript.new()
	gforce.name = "GForce" # controls.gd looks it up by name (G-LOC)
	add_child(gforce)

	var hud_layer := CanvasLayer.new()
	hud_layer.name = "HUDLayer"
	add_child(hud_layer)
	hud = HUDScript.new()
	hud.name = "HUD"
	hud_layer.add_child(hud)
	hud.setup(controls)
	radar_scope = RadarScopeScript.new()
	radar_scope.name = "RadarScope"
	hud_layer.add_child(radar_scope)
	radar_scope.setup(controls)
	_debug_overlay = DebugOverlayScript.new()
	_debug_overlay.controls = controls
	hud_layer.add_child(_debug_overlay)
	var fps_monitor: Label = FpsMonitorScript.new()
	fps_monitor.controls = controls
	hud_layer.add_child(fps_monitor)
	var controls_overlay: Control = ControlsOverlayScript.new()
	controls_overlay.name = "ControlsOverlay"
	hud_layer.add_child(controls_overlay)
	controls_overlay.setup(self, controls)

	var graphics_settings: Node = GraphicsSettingsScript.new()
	graphics_settings.name = "GraphicsSettings"
	add_child(graphics_settings)
	graphics_settings.setup(self, controls)

	var respawn_manager: Node = RespawnManagerScript.new()
	respawn_manager.name = "RespawnManager"
	add_child(respawn_manager)
	respawn_manager.setup(self, ysflight_sim)

	var settings_panel: CanvasLayer = SettingsPanelScript.new()
	settings_panel.name = "SettingsPanel"
	add_child(settings_panel)
	settings_panel.setup(controls)

	_perf_log = PerfLogScript.new(ysflight_sim)
	var tel: Dictionary = ysflight_sim.get_player_telemetry()
	ysflight_sim.log_to_crashlog("GDScript _ready() complete. Player %s, weapon %s, AIM-120 %d, AIM-9 %d" % [
		tel.get("identifier", "?"), tel.get("weapon_name", "NONE"), int(tel.get("aim120_count", 0)), int(tel.get("aim9_count", 0))])
	print("YSFlight Ready: [F1] Cockpit [F2] Exterior | [Space] Weapon [Ctrl/LMB] Gun [2] Cycle [4] Flare | [Tab] Afterburner [G] Gear | [Esc] Settings [F10] Flight setup")
	camera_rig.set_mode(camera_rig.CamMode.HORIZON_CHASE)
	camera_rig.update(0.016, ysflight_sim.get_player_transform(), tel, ysflight_sim.get_airplane_transforms())

	if benchmark_mode:
		benchmark = BenchmarkScript.new()
		benchmark.name = "Benchmark"
		add_child(benchmark)
		benchmark.setup(self)
	elif test_mode:
		var tests: Node = TestRunnerScript.new()
		tests.name = "TestRunner"
		add_child(tests)
		tests.setup(self)

# Effects quality 0 low / 1 medium / 2 high (graphics_settings.gd, from "FX Density").
func set_effects_quality(quality: int) -> void:
	ysflight_sim.set_effects_quality(quality)
	_puffs.set_quality(quality)
	_explosions.quality = quality
	_crashes.quality = quality

func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var player_tfm: Transform3D = ysflight_sim.get_player_transform()
	var tel: Dictionary = ysflight_sim.get_player_telemetry()
	var airplanes: Dictionary = ysflight_sim.get_airplane_transforms()
	camera_rig.update(delta, player_tfm, tel, airplanes)
	var t1 := Time.get_ticks_usec()
	var explosions: Array = ysflight_sim.get_active_explosions()
	var crashes: PackedFloat32Array = ysflight_sim.get_aircraft_fx_state()["crashes"]
	var t2 := Time.get_ticks_usec()
	_puffs.advance(delta)
	_explosions.update(delta, explosions)
	_crashes.update(delta, crashes)
	var t3 := Time.get_ticks_usec()
	_update_hud(delta, player_tfm, tel, airplanes)
	var t4 := Time.get_ticks_usec()
	audio_manager.update(delta, camera, camera_rig.is_cockpit(), tel)
	var t5 := Time.get_ticks_usec()

	_perf_us[0] = t1 - t0
	_perf_us[1] = t2 - t1
	_perf_us[2] = t3 - t2
	_perf_us[3] = t4 - t3
	_perf_us[4] = t5 - t4
	_perf_log.add_frame(_perf_us)
	if benchmark != null:
		benchmark.record_frame(t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4)

func _update_hud(delta: float, player_tfm: Transform3D, tel: Dictionary, airplanes: Dictionary) -> void:
	# Only the locked ground target is needed (fetching all ~500 ground objects every frame cost ~1 ms)
	var grounds := {}
	var locked_gnd: int = int(tel.get("locked_ground_target_key", -1))
	if locked_gnd >= 0:
		var g: Dictionary = ysflight_sim.get_ground_transform(locked_gnd)
		if not g.is_empty():
			grounds[locked_gnd] = g
	hud.update_hud(delta, camera, player_tfm, camera_rig.mode, tel, airplanes, grounds)
	radar_scope.update_radar(camera, player_tfm, tel, airplanes, camera_rig.mode)
	gforce.update_effect(delta, float(tel.get("g_force", 1.0)), bool(tel.get("is_alive", true)), ai_player_mode, get_tree().paused)
	_debug_overlay.update(camera_rig.status_text, tel)

func _add_sun() -> void:
	# YSFlight-like sun without double lighting
	var sun: DirectionalLight3D = get_node_or_null("DirectionalLight3D")
	if sun == null:
		sun = DirectionalLight3D.new()
		add_child(sun)
	sun.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	sun.light_energy = 0.85

func _add_environment() -> void:
	# The procedural sky also draws the infinite ground plane (a mesh at y = 0 would z-fight the field maps)
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = ysflight_sim.get_sky_color()
	sky_mat.sky_horizon_color = sky_mat.sky_top_color
	sky_mat.ground_bottom_color = ysflight_sim.get_ground_color()
	sky_mat.ground_horizon_color = sky_mat.ground_bottom_color
	sky_mat.sun_angle_max = 0.0 # no sun disc: the DirectionalLight3D is the sun
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.65, 0.65, 0.65)
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
