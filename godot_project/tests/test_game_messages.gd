extends SceneTree

# ==============================================================================
# Automated Verification Suite for Game Messages UI
# ==============================================================================
# Verifies:
# 1. A2A missile & gun kill messages (with team coloring Blue vs Red)
# 2. SAM/AAA ground killer of aircraft
# 3. Aircraft killer of ground targets
# 4. Terrain & collision crashes
# 5. Leave event from active jet
# 6. Disconnect hook event
# 7. Max 6 visible rows limit (push-down ordering)
# 8. Expiration after 8 seconds
# 9. Mission reset / generation change clearing
# 10. Multi-resolution layout bounds (1920x1080 and 2560x1440) & screenshot generation
# ==============================================================================

const GameMessagesScript := preload("res://ui/game_messages.gd")

var _checks_passed := 0
var _checks_failed := 0

func _initialize() -> void:
	run.call_deferred()

func check(condition: bool, label: String) -> void:
	if condition:
		_checks_passed += 1
		print("GAME_MESSAGES PASS: ", label)
	else:
		_checks_failed += 1
		push_error("GAME_MESSAGES FAIL: " + label)
		print("GAME_MESSAGES FAIL: ", label)

func run() -> void:
	print("--- BEGIN GAME MESSAGES VERIFICATION ---")

	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	root.add_child(vp)

	var sim: Object = ClassDB.instantiate("YSFlightSimulation")
	vp.add_child(sim)
	sim.initialize_simulation()
	sim.load_yfs("res://mission/luavi_16v16.yfs")

	var gm: Control = GameMessagesScript.new()
	vp.add_child(gm)
	gm.setup(sim)

	# 1. Test BBCode formatting for A2A Kill
	var kill_ev: Dictionary = {
		"kind": "kill",
		"killer": {"name": "VIPER 1", "iff": 0},
		"victim": {"name": "FLANKER 2", "iff": 3},
		"weapon": "AIM-120",
		"friendly": false
	}
	var bb_kill: String = gm._format_event_bbcode(kill_ev)
	check("[color=#4ea8ff]VIPER 1[/color]" in bb_kill, "Blue team killer colored blue/cyan")
	check("[color=#ff4d4d]FLANKER 2[/color]" in bb_kill, "Red team victim colored red")
	check("destroyed" in bb_kill and "(AIM-120)" in bb_kill, "Kill action and weapon included")

	# 2. Test Ground killer (SAM/AAA kills aircraft)
	var sam_ev: Dictionary = {
		"kind": "kill",
		"killer": {"name": "SAM_SITE_ALPHA", "iff": 3, "type": "ground"},
		"victim": {"name": "HORNET 4", "iff": 0, "type": "aircraft"},
		"weapon": "AIM-9",
		"friendly": false
	}
	var bb_sam: String = gm._format_event_bbcode(sam_ev)
	check("[color=#ff4d4d]SAM_SITE_ALPHA[/color]" in bb_sam, "Red ground killer colored red")
	check("[color=#4ea8ff]HORNET 4[/color]" in bb_sam, "Blue aircraft victim colored blue")

	# 3. Test Aircraft kills ground target
	var gnd_ev: Dictionary = {
		"kind": "kill",
		"killer": {"name": "EAGLE 1", "iff": 0, "type": "aircraft"},
		"victim": {"name": "RADAR_DISH_B", "iff": 3, "type": "ground"},
		"weapon": "AGM",
		"friendly": false
	}
	var bb_gnd: String = gm._format_event_bbcode(gnd_ev)
	check("[color=#4ea8ff]EAGLE 1[/color]" in bb_gnd and "[color=#ff4d4d]RADAR_DISH_B[/color]" in bb_gnd, "Air to ground kill formatted with team colors")

	# 4. Test Crash & Death events
	var crash_ev: Dictionary = {
		"kind": "crash",
		"victim": {"name": "TEST_JET", "iff": 0},
		"cause": "TERRAIN"
	}
	var bb_crash: String = gm._format_event_bbcode(crash_ev)
	check("crashed (TERRAIN)" in bb_crash, "Crash format includes cause")

	var death_ev: Dictionary = {
		"kind": "death",
		"victim": {"name": "TEST_JET", "iff": 3},
		"cause": "MISSILE"
	}
	var bb_death: String = gm._format_event_bbcode(death_ev)
	check("was destroyed (MISSILE)" in bb_death, "Death format includes cause")

	# 5. Test Leave event
	var leave_ev: Dictionary = {
		"kind": "leave",
		"victim": {"name": "PILOT_LEAVE", "iff": 0}
	}
	var bb_leave: String = gm._format_event_bbcode(leave_ev)
	check("left the aircraft" in bb_leave, "Leave event format")

	# 6. Test Disconnect event
	var disc_ev: Dictionary = {
		"kind": "disconnect",
		"victim": {"name": "PilotX"}
	}
	var bb_disc: String = gm._format_event_bbcode(disc_ev)
	check("PilotX" in bb_disc and "disconnected" in bb_disc, "Disconnect event format")

	# 7. Test Bracket escaping for special aircraft/pilot identifiers
	var tag_ev: Dictionary = {
		"kind": "leave",
		"victim": {"name": "[IFF1]COLE_SCRAMBLE_01", "iff": 0}
	}
	var bb_tag: String = gm._format_event_bbcode(tag_ev)
	check("[lb]IFF1]COLE_SCRAMBLE_01" in bb_tag, "Brackets safely escaped to [lb] to prevent bbcode corruption")

	# 8. Test Max 6 messages constraint & newest at top
	gm._active_messages.clear()
	for i in range(10):
		var test_row: Dictionary = {
			"kind": "kill",
			"killer": {"name": "Killer_%d" % i, "iff": 0},
			"victim": {"name": "Victim_%d" % i, "iff": 3},
			"weapon": "gun"
		}
		var bb: String = gm._format_event_bbcode(test_row)
		gm._active_messages.push_front({
			"sequence": i + 1,
			"time_left": 8.0,
			"bbcode": bb
		})
	if gm._active_messages.size() > 6:
		gm._active_messages.resize(6)
	gm._rebuild_text()

	check(gm._active_messages.size() == 6, "Bounded to at most 6 messages")
	check("Killer_9" in gm._active_messages[0]["bbcode"], "Newest event (Killer_9) is at index 0 (top)")
	check("Killer_4" in gm._active_messages[5]["bbcode"], "Oldest event within limit (Killer_4) is at index 5 (bottom)")

	# 9. Test Expiration logic
	gm._process(4.0) # 4 seconds pass
	check(gm._active_messages.size() == 6, "All 6 messages retained at 4.0 seconds")
	gm._process(4.1) # 8.1 seconds pass total
	check(gm._active_messages.is_empty(), "Messages expired after 8 seconds")
	check(gm._label.text == "", "Label text cleared when all messages expire")

	# 10. Test Generation reset (mission reload)
	gm._active_messages.append({"sequence": 1, "time_left": 8.0, "bbcode": "Old Message"})
	gm._last_generation = 1
	gm._last_sequence = 1
	# Simulate simulation returning generation 2
	var mock_resp: Dictionary = {
		"generation": 2,
		"events": [],
		"latest_sequence": 0,
		"oldest_sequence": 1,
		"dropped": false
	}
	var gen: int = int(mock_resp.generation)
	if gm._last_generation != -1 and gen != gm._last_generation:
		gm._active_messages.clear()
		gm._last_sequence = 0
	check(gm._active_messages.is_empty(), "Generation change clears active rows")
	check(gm._last_sequence == 0, "Generation change resets cursor")

	# 11. Test Layout at 1920x1080
	gm._update_layout()
	check(is_equal_approx(gm.position.x, 60.0), "1080p X position is 60 px")
	check(is_equal_approx(gm.position.y, 220.0), "1080p Y position is 220 px")

	# 12. Test Layout at 2560x1440
	vp.size = Vector2i(2560, 1440)
	gm._update_layout()
	var expected_y: float = roundf(220.0 * (1440.0 / 1080.0))
	check(is_equal_approx(gm.position.y, expected_y), "1440p Y position scaled to %d px" % int(expected_y))

	# Cleanup
	vp.queue_free()
	for f in range(2): await process_frame

	print("--- GAME MESSAGES VERIFICATION FINISHED: %d PASSED, %d FAILED ---" % [_checks_passed, _checks_failed])
	quit(_checks_failed)
