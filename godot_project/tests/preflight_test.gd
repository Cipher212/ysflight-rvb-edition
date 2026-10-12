extends SceneTree

# Production scene integration, native station contract and both offline session routes.
const AppState := preload("res://core/app_state.gd")
const EventConfig := preload("res://core/event_config.gd")
const Presets := preload("res://core/loadout_presets.gd")
var _failed := 0
var _checks := 0
var _game: Node
var _capture_folder := "res://../crashlog/preflight_design"

func _initialize() -> void:
	create_timer(120.0 if "--capture" in OS.get_cmdline_user_args() else 45.0).timeout.connect(func() -> void: quit(99))
	_run.call_deferred()

func check(condition: bool, text: String) -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("PREFLIGHT %s: %s" % ["PASS" if condition else "FAIL", text])

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if "--capture-dir" in args:
		_capture_folder = args[args.find("--capture-dir") + 1]
	var event := "--event" in args
	AppState.mode = "event" if event else "free_flight"
	root.size = Vector2i(1920, 1080)
	_game = load("res://main.tscn").instantiate()
	root.add_child(_game)
	for i in 35:
		await process_frame
	var session: Node = _game.preflight_session
	if "--capture" in args:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(1920, 1080))
		DisplayServer.window_set_position(Vector2i(-3000, 0))
		for i in 5:
			await process_frame
	var flow: CanvasLayer = _game.get_node("Preflight")
	var sim: YSFlightSimulation = _game.ysflight_sim
	check(session.in_menu and session.menu_screen == "lobby", "initial lobby")
	var before_throttle: float = _game.controls.current_throttle
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	_game.controls._input(wheel)
	check(_game.controls.current_throttle == before_throttle, "menu wheel cannot change flight throttle")
	check(not session.team_locked, "team unlocked before selection")
	session.open_settings()
	check(_game.controls.settings_panel.visible, "settings accessible from lobby")
	session._on_escape()
	check(not _game.controls.settings_panel.visible and session.in_menu, "settings returns to lobby")
	check(sim.get_airplane_transforms().is_empty(), "preview creates no simulation aircraft")
	check(session.choose_team("red") and session.choose_team("blue"), "provisional team can change")
	check(session.start_positions().size() > 0, "team-specific starts")
	for team in ["red", "blue"]:
		session.choose_team(team)
		flow.hangar.refresh_aircraft()
		_check_aircraft_sections(flow.hangar, team)
	for size in [8, 16]:
		var cfg := EventConfig.defaults()
		cfg["team_size"] = size
		EventConfig.fit_team_sizes(cfg, session.catalog)
		for team in ["blue", "red"]:
			var match_cfg := EventConfig.with_human_slot(cfg, team)
			check(EventConfig.count(match_cfg, team) == size - 1 and EventConfig.count(match_cfg, "red" if team == "blue" else "blue") == size, "%dv%d human replaces one %s bot" % [size, size, team])
	if "--capture" in args:
		flow.lobby.refresh()
		await _capture("after_lobby_1920.png")
	check(session.enter_hangar(), "enter hangar")
	check(session.team_locked and not session.choose_team("red"), "hard team lock")
	for i in 10:
		await process_frame
	var hangar: Control = flow.hangar
	for i in hangar._choices.size():
		if str(hangar._choices[i]["identifier"]).begins_with("F-16("):
			hangar._select_aircraft(i)
			break
	var model: RefCounted = hangar._model
	check(model != null and not model.points.is_empty(), "aircraft station data")
	var preset_path := "user://preflight_test_loadouts_%d.json" % OS.get_process_id()
	var presets := Presets.new(preset_path)
	check(presets.save_preset(model.identifier, "TEST", model.snapshot()).is_empty(), "save named preset")
	var original: Dictionary = model.snapshot()
	model.fuel = 23.0
	check(presets.save_preset(model.identifier, "TEST", model.snapshot()).is_empty(), "overwrite named preset")
	presets = Presets.new(preset_path)
	check(float(presets.get_preset(model.identifier, "TEST").get("fuel", 0)) == 23.0, "preset survives disk reload")
	model.restore(original)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(preset_path))
	var valid: Dictionary = model.validation()
	check(valid.get("ok", false), "default symmetric loadout valid: " + str(valid.get("error", "")))
	check(sim.validate_aircraft_configuration(model.identifier, 0, model.slots).get("ok", false)
		and sim.validate_aircraft_configuration(model.identifier, 100, model.slots).get("ok", false), "fuel boundaries accepted")
	check(not sim.validate_aircraft_configuration(model.identifier, -1, model.slots).get("ok", true)
		and not sim.validate_aircraft_configuration(model.identifier, NAN, model.slots).get("ok", true), "invalid fuel rejected")
	var duplicate: Array = model.slots.duplicate(true)
	duplicate[1]["station"] = 0
	check(not sim.validate_aircraft_configuration(model.identifier, 50, duplicate).get("ok", true), "duplicate station rejected")
	var unknown: Array = model.slots.duplicate(true)
	unknown[0]["weapon"] = "UNSUPPORTED_WEAPON"
	check(not sim.validate_aircraft_configuration(model.identifier, 50, unknown).get("ok", true), "unsupported weapon rejected")
	var checked_catalog := 0
	var invalid_catalog: Array[String] = []
	for entry in session.catalog:
		var specs: Dictionary = sim.get_aircraft_specs(entry["identifier"])
		var result: Dictionary = sim.validate_aircraft_configuration(entry["identifier"], 50.0, specs.get("default_slots", []))
		if not result.get("ok", false):
			invalid_catalog.append(str(entry["identifier"]) + ": " + str(result.get("error", "")))
		checked_catalog += 1
	check(invalid_catalog.is_empty(), "catalog defaults %d aircraft: %s" % [checked_catalog, str(invalid_catalog)])
	for entry in session.catalog:
		if str(entry["identifier"]).begins_with("B-1("):
			var heavy_points: Array = sim.get_aircraft_hardpoints(entry["identifier"])
			check(int(heavy_points[0]["mirror"]) == 1 and int(heavy_points[1]["mirror"]) == 0, "usable stations pair despite overlapping empty DAT placeholders")
			break
	var pair := -1
	for i in model.points.size():
		if int(model.points[i]["mirror"]) >= 0 and model.options(i).size() > 1:
			pair = i
			break
	check(pair >= 0, "paired station available")
	if pair >= 0:
		hangar._editor.select_station(pair)
		var options: Array = model.options(pair)
		model.set_weapon(options[2 if options.size() > 2 else 1]["weapon"], 1)
		hangar._editor.bind_model(model)
		var mirror := int(model.points[pair]["mirror"])
		check(model.slots[pair]["weapon"] == model.slots[mirror]["weapon"] and model.slots[mirror]["count"] == 1, "station editing mirrors opposite side")
		var bad: Array = model.slots.duplicate(true)
		bad[mirror] = {"station": mirror, "weapon": "EMPTY", "count": 0}
		check(not sim.validate_aircraft_configuration(model.identifier, 50, bad).get("ok", true), "native rejects asymmetric loadout")
		bad = model.slots.duplicate(true)
		bad[pair]["count"] = 100000
		check(not sim.validate_aircraft_configuration(model.identifier, 50, bad).get("ok", true), "native rejects over-capacity")
	# Explicit gaps distinguish station assignment from YS's aggregate auto-distribution.
	model.selected = 2
	model.set_weapon("EMPTY", 0)
	model.selected = 4
	model.set_weapon("B250", 1)
	model.selected = pair
	check(int(model.slots[2]["count"]) == 0 and int(model.slots[3]["count"]) == 0 and int(model.slots[4]["count"]) == 1, "loadout retains empty paired stations and loaded centreline")
	model.fuel = 37
	hangar._editor.bind_model(model)
	var preview: SubViewportContainer = hangar.preview
	check(preview.viewport.own_world_3d, "preview world isolated")
	check(preview.get_child_count() == 1, "no hardpoint callout overlay")
	var room_mesh: ArrayMesh = preview._room.get_node("HangarAndAirfield").mesh
	check(room_mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR].size() > 100
		and room_mesh.surface_get_material(0).vertex_color_use_as_albedo, "hangar and airfield use batched vertex colours")
	for asset_name in ["BigHangar", "AlertShedsLeft", "FuelEquipment", "LuaviRidge"]:
		var source_mesh: ArrayMesh = preview._room.get_node(asset_name).mesh
		var source: String = source_mesh.get_meta("source")
		check(source_mesh.get_meta("source_sha256") == FileAccess.get_sha256(source), "source geometry provenance: " + asset_name)
	preview.reset_camera()
	var parked_pose: Transform3D = preview._model.transform
	var before_orbit: Vector3 = preview._camera.position
	preview._process(1.0)
	check(preview._model.transform == parked_pose and not preview._camera.position.is_equal_approx(before_orbit), "presentation orbits camera around stationary aircraft")
	check((-preview._model.basis.z).dot(preview._room.get_meta("door_forward")) > 0.999, "aircraft faces straight out through hangar exit")
	var orbit_position: Vector3 = preview._camera.position
	preview.set_active(false)
	preview._process(1.0)
	check(preview._model.transform == parked_pose and preview._camera.position == orbit_position and not preview.is_processing(), "hidden hangar stops presentation processing")
	preview.set_active(true)
	var before_focus: Vector3 = preview._camera.position
	hangar._editor.select_station(pair)
	check(not preview._auto_orbit and preview._camera.position.is_equal_approx(before_focus), "station selection stops orbit without snapping camera")
	await create_timer(0.35).timeout
	var mid_focus: Vector3 = preview._camera.position
	check(not mid_focus.is_equal_approx(before_focus) and preview._focus_tween.is_running(), "station camera eases during transition")
	await create_timer(0.65).timeout
	check(preview._target.is_equal_approx(preview._model.to_global(model.points[pair]["position"]))
		and not preview._camera.position.is_equal_approx(mid_focus), "station camera finishes on chosen hardpoint")
	preview.reset_camera()
	var selected_weapon: int = hangar._editor._weapon.selected
	hangar._editor._weapon_changed(selected_weapon)
	check(not preview._auto_orbit and preview._focus_tween != null, "weapon choice requests station focus")
	var before_camera: Vector3 = preview._camera.position
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.relative = Vector2(80, 0)
	preview._input_camera(motion)
	check(not preview._camera.position.is_equal_approx(before_camera), "drag orbits preview camera")
	check(not preview._auto_orbit and preview._focus_tween == null, "manual orbit cancels automatic movement")
	motion.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	motion.relative = Vector2(0, -10000)
	preview._input_camera(motion)
	check(preview._camera.position.y <= preview._ceiling - 0.29, "camera height stays below ceiling")
	motion.relative = Vector2(0, 10000)
	preview._input_camera(motion)
	check(preview._camera.position.y >= 0.29, "camera height stays above floor")
	preview._distance = preview._fit_distance * 1.5
	preview._yaw = PI * 0.5
	preview._update_camera()
	var camera_bounds: AABB = preview._room.get_meta("camera_bounds")
	check(preview._camera.position.x <= camera_bounds.end.x, "wide orbit stays inside hangar walls")
	var overview := InputEventMouseButton.new()
	overview.button_index = MOUSE_BUTTON_LEFT
	overview.pressed = true
	overview.double_click = true
	preview._input_camera(overview)
	check(preview._auto_orbit, "double click restores overview and automatic orbit")
	check(sim.get_airplane_transforms().is_empty(), "hangar remains outside live map")
	var fighter_room: Node3D = preview._room
	var fighter_distance: float = preview._camera.position.distance_to(preview._target)
	var fighter_fit: float = preview._fit_distance
	var scenery_pose: Transform3D = fighter_room.get_node("AlertShedsLeft").transform
	var floor_bounds: AABB = fighter_room.get_node("HangarAndAirfield").mesh.get_aabb()
	if "--capture" in args:
		await _capture("after_hangar_1920.png")
		hangar._editor.select_station(pair)
		await create_timer(1.0).timeout
		await _capture("after_hardpoint_focus_1920.png")
		preview.reset_camera()
		DisplayServer.window_set_size(Vector2i(2560, 1440))
		await _capture("after_hangar_2560.png")
	# A heavy must change framing without changing the physical room or aircraft scale.
	for i in hangar._choices.size():
		if str(hangar._choices[i]["identifier"]).begins_with("B-1("):
			hangar._select_aircraft(i)
			check(preview._room == fighter_room and preview._room.get_node("BigHangar").scale == Vector3.ONE
				and preview._room.get_node("AlertShedsLeft").transform == scenery_pose
				and preview._room.get_node("HangarAndAirfield").mesh.get_aabb() == floor_bounds,
				"heavy reuses the same hangar, scenery positions and floor dimensions")
			check(preview._model.scale == Vector3.ONE, "heavy aircraft retains native scale")
			var heavy_distance: float = preview._camera.position.distance_to(preview._target)
			check(preview._fit_distance > fighter_fit and heavy_distance > fighter_distance,
				"heavy camera pulls back: %.1f m vs fighter %.1f m" % [heavy_distance, fighter_distance])
			if "--capture" in args:
				await _capture("after_transport_2560.png")
			break
	await _check_tornado_preview(hangar, "--capture" in args)
	var name: String = model.identifier
	var opposite := "AI_RED_CAP_01" # use the real opposing start below
	for start in sim.get_start_position_names():
		if start.begins_with("AI_RED_"):
			opposite = start
			break
	check(not sim.spawn_player_custom(name, opposite, 0, 37, model.slots).get("ok", true), "native rejects opposing STP")
	var start: String = session.start_positions()[0]
	var spawned: Dictionary = session.spawn_custom(name, start, 37, model.slots)
	check(spawned.get("ok", false), "custom spawn: " + str(spawned.get("error", "")))
	var actual: Dictionary = sim.get_player_configuration()
	var rejected: Dictionary = sim.spawn_player_custom(name, "[IFF1]MISSING_START", 0, 37, model.slots)
	check(not rejected.get("ok", true) and sim.get_player_configuration() == actual, "rejected spawn preserves live player")
	check(absf(float(actual.get("internal_fuel_kg", 0)) - float(actual.get("max_fuel_kg", 1)) * 0.37) < 0.1, "fuel applied before unpause")
	check(actual.get("slots", []) == sim.validate_aircraft_configuration(name, 37, model.slots).get("slots", []), "station indices survive spawning")
	check(preview.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "preview disabled while flying")
	check(not session.in_menu and not paused, "Fly Now closes menu")
	var local_preview_transform: Transform3D = preview._model.transform
	var before_origin: Vector3 = sim.get_render_origin()
	sim.set_render_origin_threshold(1.0)
	if not event:
		sim.debug_move_airplane(int(spawned["search_key"]), 50000.0, 5000.0, 50000.0)
		for i in 30:
			await process_frame
			if sim.get_render_origin() != before_origin:
				break
		check(preview._model.transform == local_preview_transform, "live origin shifts leave preview local transform unchanged")
		check(sim.get_render_origin() != before_origin, "origin isolation check actually crosses an origin shift")
	if event:
		check(not sim.is_physics_processing() and session.countdown_left > 0, "combat frozen during countdown")
		check(float(sim.get_event_state().get("time_left", 0)) == float(session.config["duration_min"]) * 60.0, "event clock held during countdown")
		session._process(30.0)
		check(sim.is_physics_processing() and session._started, "countdown releases simulation")
		for i in 25:
			await physics_frame
		check(session.roster().size() == int(session.config["team_size"]) * 2, "match roster includes human plus bots")
		var enemy_key := -1
		var friend_key := -1
		for pilot in session.roster():
			if pilot.get("alive", false) and not pilot.get("player", false):
				if pilot["team"] == "red":
					enemy_key = pilot["key"]
				else:
					friend_key = pilot["key"]
		check(enemy_key >= 0 and not session.spectate(enemy_key), "enemy spectator target rejected")
		session.leave_jet()
		check(session.spectate(friend_key), "own-team roster spectator")
		check(_game.camera_rig._session_spectator_iff == 0, "spectator camera cycles only chosen team")
	else:
		session.show_lobby()
		check(paused and session.can_resume(), "Free Flight menu pauses and can resume")
		session.resume_flight()
		check(not paused and session.in_flight(), "resume Free Flight")
		check(_game.camera_rig.mode == _game.camera_rig.CamMode.HORIZON_CHASE, "resume restores flight camera")
		sim.event_leave_jet()
		session._process(3.1)
		check(session.in_menu and session.menu_screen == "hangar", "death returns to aircraft selection")
	session.send_message("<local> message")
	check(session.messages.back().contains("<local> message"), "local session chat")
	print("PREFLIGHT RESULT: %d/%d passed" % [_checks - _failed, _checks])
	paused = false
	root.remove_child(_game)
	_game.queue_free()
	await process_frame
	quit(0 if _failed == 0 else 1)

func _check_tornado_preview(hangar: Control, capture: bool) -> void:
	var preview: Control = hangar.preview
	var room: Node3D = preview._room
	var found := false
	for i in hangar._choices.size():
		if not str(hangar._choices[i]["identifier"]).begins_with("TORNADO("):
			continue
		found = true
		hangar._select_aircraft(i)
		var bounds: AABB = preview._bounds
		check(bounds.size.y < 10.0 and bounds.size.x > 8.0 and bounds.size.z > 12.0
			and bounds.size.x < 30.0 and bounds.size.z < 30.0,
			"Tornado framing measures physical aircraft, excluding distant light effects: " + str(bounds))
		check(preview._model.position.y > 2.0 and preview._model.position.y < 5.0,
			"Tornado stays on the hangar floor")
		check(preview._fit_distance > 10.0 and preview._fit_distance < 60.0
			and preview._camera.position.y < preview._ceiling - 1.0,
			"Tornado overview camera remains below ceiling with aircraft-sized distance")
		check(preview._model.scale == Vector3.ONE and preview._room == room,
			"Tornado retains native scale and the same fixed hangar")
		var before: Vector3 = preview._camera.position
		var parked: Transform3D = preview._model.transform
		for step in 5:
			preview._process(1.0 / 30.0)
			var after: Vector3 = preview._camera.position
			check(after.distance_to(before) > 0.001 and after.distance_to(before) < 0.3
				and preview._model.transform == parked, "Tornado orbit advances without getting stuck: step %d" % step)
			before = after
		# A payload edit rebuilds the native visual without resetting its inspection camera.
		var loadout: RefCounted = hangar._model
		var snapshot: Dictionary = loadout.snapshot()
		hangar._editor.select_station(4)
		hangar._editor._weapon_changed(0) # EMPTY
		check(preview._bounds == bounds and preview._model.transform == parked,
			"Tornado loadout rebuild preserves physical bounds and parked height")
		hangar._editor.select_station(4)
		await create_timer(1.0).timeout
		check(preview._target.is_equal_approx(preview._model.to_global(loadout.points[4]["position"]))
			and preview._camera.position.distance_to(preview._target) < 20.0,
			"Tornado station focus reaches aircraft instead of distant lights")
		loadout.restore(snapshot)
		hangar._editor.bind_model(loadout)
		preview.reset_camera()
		if capture:
			await _capture("after_tornado_2560.png")
			DisplayServer.window_set_size(Vector2i(1920, 1080))
			await _capture("after_tornado_1920.png")
		break
	check(found, "Tornado regression actually selected the blue Tornado")

func _check_aircraft_sections(hangar: Control, team: String) -> void:
	var headings: Array[String] = []
	var heading := ""
	var mapped := true
	var selectable := true
	var filtered := true
	for row in hangar._aircraft.item_count:
		var index := int(hangar._aircraft.get_item_metadata(row))
		if index < 0:
			heading = hangar._aircraft.get_item_text(row)
			headings.append(heading)
			selectable = selectable and not hangar._aircraft.is_item_selectable(row)
		else:
			var entry: Dictionary = hangar._choices[index]
			mapped = mapped and entry["role"] == heading and hangar._choice_rows[index] == row and entry["team"] == team
			filtered = filtered and entry["role"] != "UCAV" and not str(entry["identifier"]).contains("/BVR)")
	check(headings == ["GUNNER", "MULTIROLE", "ATTACKER", "STEALTH", "HEAVY", "CAS"], team + " aircraft sections follow the six requested classes")
	check(mapped and selectable, team + " grouped rows map to aircraft and headings cannot be selected")
	check(filtered, team + " selection omits defunct BVR and UCAV aircraft")
	var last_row: int = hangar._choice_rows[-1]
	hangar._aircraft_row_selected(last_row)
	var selected: String = hangar._current
	hangar._aircraft_row_selected(0)
	check(selected == hangar._choices[-1]["identifier"] and hangar._current == selected, team + " row selection resolves aircraft without selecting a heading")

func _capture(filename: String) -> void:
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	if AppState.mode == "event":
		filename = filename.replace("after_", "after_event_")
	var destination := ProjectSettings.globalize_path(_capture_folder.path_join(filename))
	root.get_texture().get_image().save_png(destination)
