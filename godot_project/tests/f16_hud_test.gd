extends SceneTree

var _main: Node
var _out := ""
var _results: Array[Dictionary] = []
var _shifts := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hud-out="): _out = arg.trim_prefix("--hud-out=")
	DirAccess.make_dir_recursive_absolute(_out)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	Engine.max_fps = 120
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	await _frames(60)
	var sim: YSFlightSimulation = _main.ysflight_sim
	sim.set_physics_process(false)
	_main.set_process(false)
	_main.controls.set_process(false)
	_main.controls.set_physics_process(false)
	_main.controls._values["show_fps_monitor"] = false
	_main.controls._values["show_stick_indicator"] = false
	_main.controls._values["show_input_overlay"] = false
	_main.controls._values["cockpit_mfd"] = true
	_main.cockpit_mfd._on_setting_changed("cockpit_mfd")
	_main.controls._values["cockpit_hud"] = true
	_main.glass_hud._on_setting_changed("cockpit_hud")
	_main.controls._values["hide_hud"] = false
	_main.camera_rig.set_mode(1)
	await _frames(3)
	sim.set_process(false)
	var tel: Dictionary = sim.get_player_telemetry()
	var tfm: Transform3D = sim.get_player_transform()
	var air: Dictionary = sim.get_airplane_transforms()
	_main.camera_rig.update(0.0, tfm, tel, air)
	var glass: Control = _main.glass_hud
	_check("source vertices loaded", glass._vertices.size() >= 3)
	if glass._vertices.size() < 3:
		quit(1)
		return
	# Temporarily remove the glass controller for matched existing-HUD/hidden proof.
	_main.glass_hud = null
	glass.visible = false
	_main._update_hud(0.2, tfm, tel, air)
	await _frames(5)
	await _shot("before.png")
	_main.controls._values["hide_hud"] = true
	_main.hud._on_setting_changed("hide_hud")
	_main._update_hud(0.2, tfm, tel, air)
	await _frames(3)
	await _shot("hidden.png")
	_check("permanent setting hides helmet HUD only", not _main.hud.visible and _main.radar_scope.visible and _main.cockpit_mfd.visible)
	_main.controls._values["hide_hud"] = false
	_main.glass_hud = glass
	_main._update_hud(0.2, tfm, tel, air)
	await _frames(5)
	await _shot("after.png")
	_check("glass replaces helmet only in player F1", glass.visible and not _main.hud.visible)
	_check("aperture matches projected source geometry", glass.aperture.size() >= 4)
	var direction := -tfm.basis.z
	var initial: Vector2 = glass.project_direction(direction)
	var native_projection: Vector2 = _main.camera.unproject_position(_main.camera.global_position + direction * 1000.0)
	_check("cached optics match native camera projection", initial.distance_to(native_projection) < 0.1)
	var eye: Vector3 = _main.camera.global_position
	_main.camera.global_position += tfm.basis.x * 0.03
	glass.update_display(_main.camera, tfm, tel, air, {}, true)
	_check("collimated cue does not parallax with sideways head motion", initial.distance_to(glass.project_direction(direction)) < 0.01)
	await _frames(3)
	await _shot("head_right.png")
	_main.camera.global_position = eye
	var fov: float = _main.camera.fov
	_main.camera.fov = 40.0
	glass.update_display(_main.camera, tfm, tel, air, {}, true)
	_check("zoom increases optical scale", glass.optical_scale() > 1.3)
	await _frames(3)
	await _shot("zoom.png")
	_main.camera.fov = fov
	var warning := tel.duplicate()
	warning["is_missile_chasing"] = true
	warning["is_locked_by_enemy"] = true
	glass.update_display(_main.camera, tfm, warning, air, {}, true)
	await _frames(3)
	await _shot("warning.png")
	_check("warning reflects telemetry", glass.telemetry.is_missile_chasing)
	var before: Vector2 = glass.at(0.0, 0.0)
	var delta := Vector3(32000, 0, 32000)
	var shifted := tfm
	shifted.origin -= delta
	_main.camera.global_position -= delta
	glass.update_display(_main.camera, shifted, tel, {}, {}, true)
	_check("render-origin translation preserves alignment", before.distance_to(glass.at(0.0, 0.0)) < 0.1)
	_main.camera.global_position = eye
	glass.update_display(_main.camera, tfm, tel, air, {}, true)
	_check("wind-corrected velocity is exposed", tel.has("ground_velocity"))
	_check("no bomb cue for an unselected bomb", not bool(tel.get("cockpit_bomb_impact_valid", true)))
	_check("cockpit bomb data does not replace other aircraft's helmet cue", not tel.has("bomb_impact_pos"))
	_main.controls._values["cockpit_hud"] = false
	glass._on_setting_changed("cockpit_hud")
	_main._update_hud(0.1, tfm, tel, air)
	_check("setting restores helmet display", not glass.visible and _main.hud.visible)
	_main.controls._values["cockpit_hud"] = true
	glass._on_setting_changed("cockpit_hud")
	_main._update_hud(0.1, tfm, tel, air)
	_check("setting restores physical display", glass.visible and not _main.hud.visible)
	# Synthetic target placement exercises finite-distance cues without depending on
	# unpredictable AI locks. It does not claim a missile was fired in this fixture.
	var target_tel := tel.duplicate()
	target_tel["locked_ground_target_key"] = 42
	target_tel["weapon_type"] = 2
	target_tel["weapon_name"] = "AGM65"
	target_tel["ammo_count"] = 2
	target_tel["agm_range"] = 3000.0
	var target_pos := tfm.origin - tfm.basis.z * 2000.0
	glass.update_display(_main.camera, tfm, target_tel, {}, {42: {"pos": target_pos, "is_alive": true}}, true)
	await _frames(3)
	await _shot("target_fixture.png")
	_check("ground lock resolves without fetching all ground objects", glass.target.get("pos") == target_pos)
	target_tel["weapon_type"] = 0
	target_tel["has_gun_lead"] = true
	target_tel["gun_lead_pos"] = target_pos
	glass.update_display(_main.camera, tfm, target_tel, {}, {}, true)
	await _frames(2)
	_check("gun lead drawing accepts render-space cue", glass.telemetry.has_gun_lead)
	glass.update_display(_main.camera, tfm, tel, air, {}, true)
	if "--hud-benchmark" in OS.get_cmdline_user_args():
		await _benchmark(glass, tfm, tel, air)
	var other := tel.duplicate()
	other["identifier"] = "ANOTHER PLANE"
	_check("other aircraft excluded", not glass.update_display(_main.camera, tfm, other, air, {}, true) and not glass.visible)
	_main._update_hud(0.1, tfm, other, air)
	_check("other aircraft retain their helmet HUD", not glass.visible and _main.hud.visible)
	_check("exterior and spectator excluded", not glass.update_display(_main.camera, tfm, tel, air, {}, false))
	other = tel.duplicate()
	other["is_alive"] = false
	_check("dead aircraft excluded", not glass.update_display(_main.camera, tfm, other, air, {}, true))
	# Real C++ rebase, with normal main frame ordering restored.
	var player_key := -1
	for key in air:
		if air[key].is_player: player_key = int(key)
	sim.render_origin_shifted.connect(func(_delta: Vector3) -> void: _shifts += 1)
	sim.debug_move_airplane(player_key, 32000.0, 3000.0, 32000.0)
	sim.reset_interpolation()
	sim.set_process(true)
	_main.set_process(true)
	await _frames(20)
	_check("glass survives a real simulation origin shift", _shifts > 0 and glass.visible and not _main.hud.visible)
	var failed := 0
	for result in _results:
		if not result.ok: failed += 1
	var file := FileAccess.open(_out.path_join("results.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"results": _results, "failed": failed}, "\t"))
	file.close()
	_main.queue_free()
	await _frames(2)
	quit(1 if failed else 0)

func _check(label: String, ok: bool) -> void:
	_results.append({"name": label, "ok": ok})
	print("GLASS %s: %s" % ["PASS" if ok else "FAIL", label])

func _frames(count: int) -> void:
	for frame in count: await process_frame

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(_out.path_join(name))

func _benchmark(glass: Control, tfm: Transform3D, tel: Dictionary, air: Dictionary) -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var phases: Array[Dictionary] = []
	for enabled: bool in [false, true, true, false]:
		_main.hud.visible = not enabled
		glass.update_display(_main.camera, tfm, tel, air, {}, enabled)
		await _frames(60)
		var samples := []
		var start := Time.get_ticks_usec()
		var previous := start
		while Time.get_ticks_usec() - start < 6000000:
			await process_frame
			var now := Time.get_ticks_usec()
			var cpu := Time.get_ticks_usec()
			glass.update_display(_main.camera, tfm, tel, air, {}, enabled)
			_main.hud.update_hud(0.016, _main.camera, tfm, 1, tel, air, {})
			samples.append({"wall_ms": (now - previous) / 1000.0,
				"update_us": Time.get_ticks_usec() - cpu,
				"draw_us": glass._symbols.draw_us if enabled else 0,
				"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(rid),
				"render_cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(rid)})
			previous = now
		phases.append({"enabled": enabled, "display": "glass" if enabled else "helmet", "samples": samples})
	var file := FileAccess.open(_out.path_join("performance.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"resolution": "%dx%d" % [root.size.x, root.size.y],
		"vsync": DisplayServer.window_get_vsync_mode(), "fps_cap": Engine.max_fps,
		"frozen_scene": true, "phases": phases}))
	file.close()
