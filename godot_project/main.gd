extends Node3D

# Composition root: creates the sim and every subsystem, then runs the per-frame order:
# camera -> effects -> HUD / radar / G effects -> audio. The sim node itself runs first (process priority
# -100: interpolation + model sync) and its physics tick runs after the controls (priority +100).
# Command-line flags (after "--"): --benchmark, --ai-player, --no-interp, --mission <res path>,
# --stock-ai (stock YS AI instead of the RvB tactical AI), --no-ai-respawn, --ai-ground-ops (archived RTB/taxi),
# --ai-soak <sim seconds> [--sim-speed N] (AI-only run that logs the AI, tests/ai_soak.gd). Notes: logs/.

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
const DeathFXScript = preload("res://fx/death_fx.gd")
const DebugOverlayScript = preload("res://ui/debug_overlay.gd")
const FpsMonitorScript = preload("res://ui/fps_monitor.gd")
const PerfLogScript = preload("res://core/perf_log.gd")
const TestRunnerScript = preload("res://tests/test_runner.gd")
const AiSoakScript = preload("res://tests/ai_soak.gd")
const SkyEnvironmentScript = preload("res://world/sky_environment.gd")
const SpeedStreaksScript = preload("res://fx/speed_streaks.gd")
const SunGlareScript = preload("res://fx/sun_glare.gd")
const BlastGlowScript = preload("res://fx/blast_glow.gd")

const MISSION := "res://mission/luavi_16v16.yfs"
const BENCHMARK_SEED := 12345
const HEAT_HAZE_LAYER := 11 # render/burner_mesh.h: camera cull layer of the burner heat haze (Graphics setting)
# The screen effects below are drawn (empty) for this many frames at load, so their shaders compile then and
# not at the first explosion or glance at the sun (a 100-300 ms hitch).
const EFFECT_PREWARM_FRAMES := 30

var ysflight_sim: YSFlightSimulation = null
var camera_rig: Node = null
var camera: Camera3D = null
var sky_environment: WorldEnvironment = null
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
var _death_fx: Node3D = null
var speed_streaks: MultiMeshInstance3D = null # Graphics settings switch these (graphics_settings.gd)
var sun_glare: MeshInstance3D = null
var blast_glow: MeshInstance3D = null
var _sun: DirectionalLight3D = null
var _prewarm_left := EFFECT_PREWARM_FRAMES
var _debug_overlay: Control = null
var _perf_log: RefCounted = null
var _perf_us := PackedInt64Array([0, 0, 0, 0, 0])

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	benchmark_mode = "--benchmark" in args
	test_mode = "--run-tests" in args
	var soak_i := args.find("--ai-soak")
	ai_player_mode = benchmark_mode or soak_i >= 0 or "--ai-player" in args

	_add_sun()
	ysflight_sim = YSFlightSimulation.new()
	add_child(ysflight_sim)
	ysflight_sim.initialize_simulation()
	ysflight_sim.set_rvb_ai_enabled(not "--stock-ai" in args)
	ysflight_sim.set_ai_respawn_enabled(not "--no-ai-respawn" in args)
	ysflight_sim.set_ai_ground_ops("--ai-ground-ops" in args) # archived: RTB / landing / taxi / refuel
	if benchmark_mode or test_mode:
		ysflight_sim.set_random_seed(BENCHMARK_SEED)
	var mission := MISSION
	var mi := args.find("--mission")
	if mi >= 0 and mi + 1 < args.size():
		mission = args[mi + 1] # e.g. stresstest.bat: res://mission/luavi_stresstest_32v32.yfs
	ysflight_sim.load_yfs(mission)
	if "--no-interp" in args:
		ysflight_sim.set_interpolation_enabled(false) # A/B test: show the latest physics tick, no blending
	if ai_player_mode:
		ysflight_sim.enable_player_autopilot()
	var speed_i := args.find("--sim-speed")
	if speed_i >= 0 and speed_i + 1 < args.size():
		ysflight_sim.set_sim_speed(int(args[speed_i + 1]))

	controls = ControlsScript.new()
	controls.name = "Controls"
	add_child(controls)
	controls.setup(self, ysflight_sim)

	camera_rig = CameraRigScript.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	camera_rig.setup(ysflight_sim, controls, ai_player_mode, benchmark_mode)
	camera = camera_rig.camera
	sky_environment = SkyEnvironmentScript.new()
	add_child(sky_environment)
	sky_environment.setup(ysflight_sim, camera.far)

	_puffs = PuffSystemScript.new()
	add_child(_puffs)
	blast_glow = BlastGlowScript.new()
	blast_glow.setup(camera)
	_explosions = ExplosionFXScript.new()
	_explosions.name = "Explosions"
	add_child(_explosions)
	_explosions.setup(_puffs, blast_glow)
	_crashes = CrashFXScript.new()
	_crashes.name = "CrashSites"
	add_child(_crashes)
	_crashes.setup(_puffs)
	_death_fx = DeathFXScript.new()
	add_child(_death_fx)
	_death_fx.setup(_puffs)
	speed_streaks = SpeedStreaksScript.new()
	add_child(speed_streaks)
	speed_streaks.setup()
	sun_glare = SunGlareScript.new()
	sun_glare.setup(camera, _sun)

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
	elif soak_i >= 0:
		var soak: Node = AiSoakScript.new()
		soak.name = "AiSoak"
		add_child(soak)
		var sample_i := args.find("--soak-sample")
		if sample_i >= 0 and sample_i + 1 < args.size():
			soak.sample_s = float(args[sample_i + 1])
		soak.setup(self, float(args[soak_i + 1]) if soak_i + 1 < args.size() else 600.0)

# Effects quality 0 low / 1 medium / 2 high (graphics_settings.gd, from "FX Density").
func set_effects_quality(quality: int) -> void:
	ysflight_sim.set_effects_quality(quality)
	_puffs.set_quality(quality)
	_explosions.quality = quality
	_crashes.quality = quality
	_death_fx.quality = quality

func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var player_tfm: Transform3D = ysflight_sim.get_player_transform()
	var tel: Dictionary = ysflight_sim.get_player_telemetry()
	var airplanes: Dictionary = ysflight_sim.get_airplane_transforms()
	camera_rig.update(delta, player_tfm, tel, airplanes)
	var t1 := Time.get_ticks_usec()
	var explosions: Array = ysflight_sim.get_active_explosions()
	var fx_state: Dictionary = ysflight_sim.get_aircraft_fx_state()
	var t2 := Time.get_ticks_usec()
	_puffs.advance(delta)
	_explosions.update(delta, explosions)
	_crashes.update(delta, fx_state["crashes"])
	_death_fx.update(delta, fx_state["aircraft"])
	speed_streaks.update(delta, camera, camera_rig.is_at_player(), tel)
	sun_glare.update()
	blast_glow.update(delta)
	if _prewarm_left > 0:
		_prewarm_left -= 1
		for fx in [sun_glare, blast_glow, speed_streaks]: # each hides itself again on its next update
			fx.visible = _prewarm_left > 0
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
	gforce.update_effect(delta, float(tel.get("g_force", 1.0)), bool(tel.get("is_alive", true)), ai_player_mode,
		get_tree().paused, camera_rig.is_cockpit())
	_debug_overlay.update(camera_rig.status_text, tel)

func _add_sun() -> void:
	# YSFlight-like sun without double lighting
	_sun = get_node_or_null("DirectionalLight3D")
	if _sun == null:
		_sun = DirectionalLight3D.new()
		add_child(_sun)
	_sun.rotation_degrees = Vector3(-40.0, 35.0, 0.0) # 40 deg high: shapes read better, sun in view more often
	_sun.light_energy = 0.85
	_sun.light_color = Color(1.0, 0.96, 0.88) # slightly warm: golden haze towards the sun (fog sun scatter)
	RenderingServer.global_shader_parameter_set("sun_direction", _sun.global_basis.z) # ground_fx.gdshaderinc
