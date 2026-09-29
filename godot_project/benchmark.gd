extends Node

var main: Node = null
var bench_seconds: float = 120.0
var bench_label: String = "run"
var start_tick: int = 0
var out_dir: String = ""
var prev_usec: int = 0
var csv_lines := PackedStringArray()
var last_spike_time: float = -10.0
var spike_count: int = 0
var frame_count: int = 0
var done := false
var start_datetime: String = ""
var last_cam_mode: int = -1
var last_periodic_sec: int = -1
var bench_vsync := false # true = vsync on, as players run it (frame pacing by the display)
var bench_fps: int = 0 # 0 = uncapped (measures headroom); 60 = what a player with a 60 FPS cap sees
var bench_res := Vector2i(1920, 1080) # Vector2i.ZERO = "native": leave the window as it is

func setup(m: Node) -> void:
	main = m
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--bench-seconds="):
			bench_seconds = arg.trim_prefix("--bench-seconds=").to_float()
		elif arg.begins_with("--bench-label="):
			bench_label = arg.trim_prefix("--bench-label=")
		elif arg == "--bench-vsync":
			bench_vsync = true
		elif arg.begins_with("--bench-fps="):
			bench_fps = arg.trim_prefix("--bench-fps=").to_int()
		elif arg.begins_with("--bench-res="):
			var res := arg.trim_prefix("--bench-res=")
			if res == "native":
				bench_res = Vector2i.ZERO
			else:
				var wh := res.split("x")
				if wh.size() == 2:
					bench_res = Vector2i(wh[0].to_int(), wh[1].to_int())

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bench_vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = bench_fps
	_enforce_window_size()
	
	var rid: RID = main.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)

	var dt := Time.get_datetime_dict_from_system()
	start_datetime = "%04d-%02d-%02d %02d:%02d:%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	var dt_str := "%04d%02d%02d_%02d%02d%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	out_dir = ProjectSettings.globalize_path("res://").path_join("../crashlog/bench/%s_%s" % [dt_str, bench_label]).simplify_path()
	DirAccess.make_dir_recursive_absolute(out_dir)

	start_tick = Engine.get_physics_frames()
	main.ysflight_sim.get_frame_stats() # Reset accumulators
	
	csv_lines.append("frame,sim_time,wall_ms,ticks,sim_ms,sync_ms,camera_ms,fetch_ms,vfx_ms,hud_ms,gpu_ms,render_cpu_ms,draw_calls,primitives,objects,nodes,alive_air,weapons,explosions,visual_entities,cam_mode,flag,audio_ms,motion_err")

# Keeps the render resolution fixed for the whole run (maximising the window would change the GPU load).
func _enforce_window_size() -> void:
	if bench_res == Vector2i.ZERO:
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if DisplayServer.window_get_size() != bench_res:
		DisplayServer.window_set_size(bench_res)

# Motion smoothness: how far the player jet moved on screen this frame vs how far it should have moved
# (speed * frame delta). 0 = perfectly smooth; stepping between physics ticks shows up as large errors.
var _motion_prev_pos := Vector3.ZERO
var _motion_has_prev := false

func _motion_error() -> float:
	var tel: Dictionary = main.ysflight_sim.get_player_telemetry()
	var pos: Vector3 = main.ysflight_sim.get_player_transform().origin
	var dt: float = get_process_delta_time()
	var speed: float = float(tel.get("speed_ms", 0.0))
	var err: float = -1.0 # -1 = not measured this frame
	if _motion_has_prev and bool(tel.get("is_alive", false)) and speed > 30.0 and dt > 0.0:
		var expected: float = speed * dt
		err = absf(pos.distance_to(_motion_prev_pos) - expected) / expected
	_motion_prev_pos = pos
	_motion_has_prev = true
	return err

func record_frame(camera_us: float, fetch_us: float, vfx_us: float, hud_us: float, audio_us: float = 0.0) -> void:
	_enforce_window_size()
	if done:
		return
	
	var sim_time: float = (Engine.get_physics_frames() - start_tick) / float(Engine.physics_ticks_per_second)
	
	var target_cam: int = 0
	if sim_time < 20.0:
		target_cam = main.CamMode.HORIZON_CHASE
	elif sim_time < 35.0:
		target_cam = main.CamMode.COCKPIT
	elif sim_time < 60.0:
		target_cam = main.CamMode.SPECTATOR_AI
	elif sim_time < 75.0:
		target_cam = main.CamMode.TOWER
	elif sim_time < 90.0:
		target_cam = main.CamMode.FLY_BY
	elif sim_time < 105.0:
		target_cam = main.CamMode.SPECTATOR_AI
	else:
		target_cam = main.CamMode.HORIZON_CHASE
	
	if target_cam != last_cam_mode:
		main._set_camera_mode(target_cam, false)
		last_cam_mode = target_cam

	var now_usec := Time.get_ticks_usec()
	if prev_usec == 0:
		prev_usec = now_usec
		main.ysflight_sim.get_frame_stats() # Skip the first very slow frame completely, just reset
		return
		
	var wall_ms: float = (now_usec - prev_usec) / 1000.0
	prev_usec = now_usec
	
	var stats: PackedFloat64Array = main.ysflight_sim.get_frame_stats()
	var sim_ms: float = stats[0]
	var ticks: float = stats[1]
	var sync_ms: float = stats[2]
	var alive_air: float = stats[3]
	var weapons: float = stats[4]
	var explosions: float = stats[5]
	var visual_entities: float = stats[6]
	
	var rid: RID = main.get_viewport().get_viewport_rid()
	var gpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(rid)
	var render_cpu_ms: float = RenderingServer.viewport_get_measured_render_time_cpu(rid)
	
	var draw_calls: float = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var primitives: float = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var objects: float = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var nodes: float = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	
	var flag: int = 0
	if sim_time < 2.0:
		flag = 2
		
	var cam_mode: int = main.cam_mode
	
	var current_sec := int(sim_time)
	var take_periodic: bool = false
	if current_sec > 0 and current_sec % 15 == 0 and current_sec != last_periodic_sec:
		take_periodic = true
		last_periodic_sec = current_sec

	var take_spike: bool = false
	if wall_ms > 25.0 and sim_time >= 2.0 and (sim_time - last_spike_time) >= 3.0 and spike_count < 12:
		take_spike = true
		last_spike_time = sim_time
		spike_count += 1
		
	if take_periodic:
		var path := out_dir.path_join("shot_%ds.jpg" % current_sec)
		var img := main.get_viewport().get_texture().get_image()
		if img != null:
			img.save_jpg(path, 0.85)
		if flag != 2:
			flag = 1
	elif take_spike:
		var path := out_dir.path_join("spike_f%d_%dms.jpg" % [frame_count, int(round(wall_ms))])
		var img := main.get_viewport().get_texture().get_image()
		if img != null:
			img.save_jpg(path, 0.85)
		if flag != 2:
			flag = 1

	var motion_err: float = _motion_error()
	var line := "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.4f" % [
		float(frame_count), sim_time, wall_ms, ticks, sim_ms, sync_ms, camera_us/1000.0, fetch_us/1000.0, vfx_us/1000.0, hud_us/1000.0, gpu_ms, render_cpu_ms, draw_calls, primitives, objects, nodes, alive_air, weapons, explosions, visual_entities, float(cam_mode), float(flag), audio_us/1000.0, motion_err
	]
	csv_lines.append(line)
	frame_count += 1
	
	if sim_time >= bench_seconds:
		done = true
		_finish_benchmark()

func _finish_benchmark() -> void:
	var csv_str := "\n".join(csv_lines) + "\n"
	var f := FileAccess.open(out_dir.path_join("frames.csv"), FileAccess.WRITE)
	if f != null:
		f.store_string(csv_str)
		f.close()
	
	var meta := {
		"label": bench_label,
		"fps_cap": bench_fps,
		"vsync": bench_vsync,
		"refresh_hz": DisplayServer.screen_get_refresh_rate(),
		"bench_seconds": bench_seconds,
		"started": start_datetime,
		"window_size": "%dx%d" % [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"gpu": RenderingServer.get_video_adapter_name(),
		"gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"api_version": RenderingServer.get_video_adapter_api_version(),
		"cpu": OS.get_processor_name(),
		"cpu_threads": OS.get_processor_count(),
		"godot": Engine.get_version_info().string,
		"rendering_method": ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		"msaa_3d": ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d"),
		"physics_tps": Engine.physics_ticks_per_second
	}
	var mf := FileAccess.open(out_dir.path_join("meta.json"), FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify(meta, "\t"))
		mf.close()
	
	main.ysflight_sim.log_to_crashlog("Benchmark finished: " + out_dir)
	print("Benchmark finished: " + out_dir)
	get_tree().quit()
