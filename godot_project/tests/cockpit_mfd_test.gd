extends SceneTree

# Rendered integration proof, without writing player settings. Run via tools/cockpit_mfd_test.py.
var _main: Node = null
var _results: Array[Dictionary] = []
var _out := ""
var _shifts := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mfd-out="):
			_out = arg.trim_prefix("--mfd-out=")
	DirAccess.make_dir_recursive_absolute(_out)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 120
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	await _frames(60)
	var sim: YSFlightSimulation = _main.ysflight_sim
	var mfd: Node3D = _main.cockpit_mfd
	var tel: Dictionary = sim.get_player_telemetry()
	_check("native health and IAS telemetry", tel.has("health_pct") and tel.has("ias_kt") and float(tel.health_pct) > 0.0 and float(tel.ias_kt) <= float(tel.speed_kt), str(tel.get("ias_kt")))
	_check("startup prewarm finishes and exterior viewport sleeps", mfd._prewarm == null and mfd._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "")
	# Freeze the aircraft for a genuinely matching before/after pair.
	sim.set_physics_process(false)
	_main.set_process(false)
	_main.controls.set_physics_process(false)
	_main.controls.set_process(false)
	_main.controls._values["show_fps_monitor"] = false # frozen screenshots are not FPS evidence
	_main.controls._values["cockpit_mfd"] = true
	mfd._on_setting_changed("cockpit_mfd")
	_main.camera_rig.set_mode(1)
	await _frames(3) # C++ must apply cockpit materials and update the cockpit shell first.
	sim.set_process(false)
	tel = sim.get_player_telemetry()
	var tfm: Transform3D = sim.get_player_transform()
	_main.camera_rig.update(0.0, tfm, tel, sim.get_airplane_transforms())
	_main._update_hud(0.2, tfm, tel, sim.get_airplane_transforms())
	await _frames(5)
	mfd.visible = false
	await _shot("before.png")
	mfd.update_display(0.2, tfm, tel, true)
	await _frames(5)
	await _shot("after.png")
	_check("one mesh draw and one 2D viewport", mfd._mesh.mesh.get_surface_count() == 1 and mfd._viewport.disable_3d and mfd._viewport.size == Vector2i(512, 256), "")
	_check("display follows interpolated aircraft", mfd.global_transform == tfm, "")
	var before: int = mfd._canvas.redraw_count
	for frame in 20:
		mfd.update_display(0.1, tfm, tel, true)
	_check("unchanged text does not redraw", mfd._canvas.redraw_count == before, "")
	var changed := tel.duplicate()
	changed["fuel_pct"] = 25.0
	changed["health_pct"] = 50.0
	changed["is_locked_by_enemy"] = true
	changed["is_missile_chasing"] = true
	mfd.update_display(0.001, tfm, changed, true)
	await _frames(3)
	_check("warnings refresh before the next scheduled update", mfd._canvas.values.lock and mfd._canvas.values.missile and mfd._canvas.values.health == 50 and mfd._canvas.values.fuel == 25, "")
	mfd._viewport.get_texture().get_image().save_png(_out.path_join("atlas_warning.png"))
	if "--mfd-benchmark" in OS.get_cmdline_user_args():
		await _benchmark(mfd, tfm, tel)
	mfd.update_display(0.2, tfm, tel, false)
	_check("exterior and spectator hide screens and stop updates", not mfd.visible and mfd._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "")
	_main.controls._values["cockpit_mfd"] = false
	mfd._on_setting_changed("cockpit_mfd")
	mfd.update_display(0.2, tfm, tel, true)
	_check("setting disables cockpit display", not mfd.visible, "")
	_main.controls._values["cockpit_mfd"] = true
	mfd._on_setting_changed("cockpit_mfd")
	var other := tel.duplicate()
	other["identifier"] = "OTHER AIRCRAFT"
	mfd.update_display(0.2, tfm, other, true)
	_check("other aircraft remain unchanged", not mfd.visible, "")
	other = tel.duplicate()
	other["is_alive"] = false
	mfd.update_display(0.2, tfm, other, true)
	_check("dead aircraft hides screens", not mfd.visible, "")
	# Force a real floating-origin shift through the sim, then compare the screen transform.
	var key := -1
	for k in sim.get_airplane_transforms():
		if sim.get_airplane_transforms()[k].is_player:
			key = int(k)
	sim.render_origin_shifted.connect(func(_d: Vector3) -> void: _shifts += 1)
	sim.debug_move_airplane(key, 32000.0, 3000.0, 32000.0)
	sim.reset_interpolation()
	sim.set_process(true)
	_main.set_process(true)
	await _frames(20)
	_check("screens survive a real render-origin shift", _shifts > 0 and mfd.visible and mfd.global_transform == sim.get_player_transform(), "%d shifts" % _shifts)
	var failed := 0
	for result in _results:
		if not result.ok:
			failed += 1
	var file := FileAccess.open(_out.path_join("results.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"results": _results, "failed": failed}, "\t"))
	file.close()
	_main.queue_free()
	await _frames(2)
	quit(1 if failed > 0 else 0)

func _check(label: String, ok: bool, detail: String) -> void:
	_results.append({"name": label, "ok": ok, "detail": detail})
	print("MFD %s: %s %s" % ["PASS" if ok else "FAIL", label, detail])

func _frames(count: int) -> void:
	for frame in count:
		await process_frame

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(_out.path_join(name))

func _benchmark(mfd: Node3D, tfm: Transform3D, tel: Dictionary) -> void:
	# Identical frozen scene; alternate off/on/on/off to expose drift. Unlike the combat
	# benchmark this isolates MFD draw/update cost from changing AI fights.
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED) # after graphics settings applied
	var rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var phases: Array[Dictionary] = []
	for enabled: bool in [false, true, true, false]:
		mfd.update_display(0.2, tfm, tel, enabled)
		await _frames(60)
		var samples := []
		var start := Time.get_ticks_usec()
		var previous := start
		while Time.get_ticks_usec() - start < 6000000:
			await process_frame
			var now := Time.get_ticks_usec()
			var delta := (now - previous) / 1000000.0
			var sample_tel := tel.duplicate()
			# Exercise a changing numeric display at its real 10 Hz rate.
			sample_tel["speed_kt"] = 400.0 + fmod((now - start) / 100000.0, 20.0)
			var cpu_start := Time.get_ticks_usec()
			mfd.update_display(delta, tfm, sample_tel, enabled)
			var update_us := Time.get_ticks_usec() - cpu_start
			samples.append({"wall_ms": (now - previous) / 1000.0, "update_us": update_us,
				"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(rid),
				"render_cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(rid)})
			previous = now
		phases.append({"enabled": enabled, "samples": samples})
	var file := FileAccess.open(_out.path_join("performance.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"resolution": "%dx%d" % [root.size.x, root.size.y],
		"vsync": DisplayServer.window_get_vsync_mode(), "fps_cap": Engine.max_fps,
		"frozen_scene": true, "phases": phases}))
	file.close()
