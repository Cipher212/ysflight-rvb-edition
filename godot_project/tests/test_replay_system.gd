extends SceneTree

# ==============================================================================
# Automated Test Suite: Replay, Spectator, and Scoreboard Subsystems
# ==============================================================================
# Tests .ysrvb serialization, directory resolution, highlights clustering,
# tactical statistics aggregation, and timepoint-aware dynamic scoreboard progression.
#
# FULL SPECIFICATION & ARCHITECTURE REFERENCE:
# -> planning/replay_and_spectator_system.md
# ==============================================================================

const ReplayManager := preload("res://core/replay_manager.gd")
const ScoreboardScript := preload("res://ui/scoreboard.gd")

func _init() -> void:
	print("--- BEGIN REPLAY & SPECTATOR SYSTEM TEST ---")
	_test_directory_resolution()
	var test_path := _test_save_and_load()
	_test_highlights_clustering()
	_test_statistics_computation()
	_test_scoreboard_progression()

	# Cleanup test file
	if FileAccess.file_exists(test_path):
		DirAccess.remove_absolute(test_path)
		print("CLEANUP: Removed test replay file.")

	print("--- ALL REPLAY & SPECTATOR SYSTEM CHECKS PASSED ---")
	quit(0)

func _test_directory_resolution() -> void:
	var dir := ReplayManager.get_replay_dir()
	assert(not dir.is_empty(), "Replay directory must not be empty")
	assert(DirAccess.dir_exists_absolute(dir), "Replay directory must exist on disk: " + dir)
	print("CHECK 1 PASSED: Replay directory resolved and verified: ", dir)

func _test_save_and_load() -> String:
	var mock_replay: Dictionary = {
		"metadata": {
			"version": 1,
			"map": "LUAVI",
			"duration": 45.0,
			"player_callsign": "TEST_PILOT",
			"created_at": Time.get_unix_time_from_system()
		},
		"roster": [
			{"name": "Alpha", "team": "blue", "aircraft": "F-16", "role": "FIGHTER"},
			{"name": "Bravo", "team": "red", "aircraft": "MIG-29", "role": "INTERCEPTOR"}
		],
		"frames": [
			{
				"time": 0.0,
				"aircraft": [{"id": 0, "pos": [0, 1000, 0], "speed_kt": 450.0}],
				"weapons": []
			},
			{
				"time": 10.0,
				"aircraft": [{"id": 0, "pos": [100, 1000, 500], "speed_kt": 520.0}],
				"weapons": [{"id": 1, "type": 1, "pos": [120, 1000, 520], "life": 4.5}]
			}
		],
		"events": [
			{
				"time": 12.5,
				"type": "kill",
				"killer_name": "Alpha",
				"killer_team": "blue",
				"killer_aircraft": "F-16",
				"victim_name": "Bravo",
				"victim_team": "red",
				"victim_aircraft": "MIG-29",
				"weapon": "AIM9",
				"ground": false,
				"pos": [150.0, 1000.0, 550.0]
			}
		]
	}

	var saved_path := ReplayManager.save_replay(mock_replay, "TEST_SUITE_REPLAY")
	assert(not saved_path.is_empty(), "Replay save failed")
	assert(FileAccess.file_exists(saved_path), "Saved file must exist: " + saved_path)

	var loaded := ReplayManager.load_replay(saved_path)
	assert(not loaded.is_empty(), "Replay load failed")
	assert(loaded["metadata"]["player_callsign"] == "TEST_PILOT", "Metadata player callsign mismatch")
	assert(loaded["frames"].size() == 2, "Expected 2 frames")
	assert(loaded["events"].size() == 1, "Expected 1 combat event")
	assert(loaded["frames"][1]["weapons"].size() == 1, "Expected 1 active weapon in frame 1")
	print("CHECK 2 PASSED: .ysrvb serialization and weapon trajectory loading verified.")
	return saved_path

func _test_highlights_clustering() -> void:
	var events: Array = [
		{"time": 10.0, "type": "kill", "pos": [100, 500, 100]},
		{"time": 18.0, "type": "kill", "pos": [400, 550, 300]}, # Within 20s and 500m
		{"time": 85.0, "type": "kill", "pos": [5000, 1200, 5000]} # Isolated kill
	]

	var highlights := ReplayManager.detect_highlights(events, 20.0, 2, 3500.0)
	assert(highlights.size() == 1, "Expected 1 highlight cluster, got %d" % highlights.size())
	assert(highlights[0]["kill_count"] == 2, "Expected cluster to contain 2 kills")
	assert(highlights[0]["start_time"] == 5.0, "Start time should be 10.0 - 5.0 = 5.0")
	print("CHECK 3 PASSED: Highlights reel clustering detected multi-kill furball.")

func _test_statistics_computation() -> void:
	var mock_replay: Dictionary = {
		"roster": [
			{"name": "P1", "aircraft": "F-16", "team": "blue"},
			{"name": "P2", "aircraft": "F-16", "team": "blue"},
			{"name": "P3", "aircraft": "A-10", "team": "blue"},
			{"name": "P4", "aircraft": "SU-27", "team": "red"}
		],
		"events": [
			{"type": "kill", "killer_aircraft": "F-16", "victim_aircraft": "SU-27", "ground": false},
			{"type": "kill", "killer_aircraft": "A-10", "victim_aircraft": "TANK_T72", "victim_name": "T-72", "ground": true},
			{"type": "kill", "killer_name": "SAM_SA6", "killer_is_ground": true, "victim_aircraft": "F-16", "ground": false}
		]
	}

	var ac_stats := ReplayManager.compute_aircraft_statistics(mock_replay)
	assert(ac_stats.size() >= 3, "Expected at least 3 aircraft types")
	assert(ac_stats[0]["aircraft"] == "F-16", "Most flown aircraft should be F-16")
	assert(ac_stats[0]["sorties"] == 2, "F-16 sorties should be 2")
	assert(ac_stats[0]["air_kills"] == 1, "F-16 air kills should be 1")

	var gnd_stats := ReplayManager.compute_ground_statistics(mock_replay)
	assert(gnd_stats["most_destroyed"].size() == 1, "Expected 1 destroyed ground target")
	assert(gnd_stats["most_destroyed"][0]["target"] == "T-72", "Destroyed target should be T-72")
	assert(gnd_stats["most_deadly"][0]["threat"] == "SAM_SA6", "Most deadly ground threat should be SAM_SA6")
	print("CHECK 4 PASSED: Tactical statistics engine aggregations verified.")

func _test_scoreboard_progression() -> void:
	var sb := ScoreboardScript.new()
	root.add_child(sb)

	var mock_replay: Dictionary = {
		"roster": [
			{"name": "Viper", "team": "blue", "aircraft": "F-16", "role": "FIGHTER"},
			{"name": "Cobra", "team": "red", "aircraft": "MIG-29", "role": "INTERCEPTOR"}
		],
		"events": [
			{
				"time": 20.0,
				"type": "kill",
				"killer_name": "Viper",
				"killer_team": "blue",
				"victim_name": "Cobra",
				"victim_team": "red",
				"ground": false
			}
		]
	}

	sb.setup_replay(mock_replay)

	# Before the kill at t = 10.0
	sb.update_replay_timepoint(10.0)
	assert(sb._blue_score_lbl.text == "BLUE: 0", "Score at t=10s should be 0")

	# After the kill at t = 25.0
	sb.update_replay_timepoint(25.0)
	assert(sb._blue_score_lbl.text == "BLUE: 3", "Score at t=25s should be 3")

	# Scrub backwards to t = 5.0 (score must rewind!)
	sb.update_replay_timepoint(5.0)
	assert(sb._blue_score_lbl.text == "BLUE: 0", "Score after rewind to t=5s must revert to 0")

	sb.queue_free()
	print("CHECK 5 PASSED: Scoreboard dynamic timepoint progression & rewind verified.")
