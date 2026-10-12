extends SceneTree

# Unit test suite for Radar UI and BVR HUD Overhaul
const ControlsScript := preload("res://controls.gd")
const SettingsSchema := preload("res://controls/settings_schema.gd")
const RadarScopeScript := preload("res://radar_scope.gd")
const HUDScript := preload("res://hud.gd")

func _init() -> void:
	print("--- BEGIN RADAR & BVR HUD OVERHAUL TESTS ---")
	test_settings_schema_entries()
	test_filter_mode_cycling()
	test_enlarge_toggle()
	test_controls_action_dispatch()
	print("--- ALL RADAR & BVR HUD OVERHAUL TESTS PASSED ---")
	quit(0)

func test_settings_schema_entries() -> void:
	print("Testing SettingsSchema entries...")
	var keys: Array[String] = []
	for s in SettingsSchema.SETTINGS:
		keys.append(s["key"])
	
	assert(keys.has("radar_filter_mode"), "Missing radar_filter_mode in schema")
	assert(keys.has("radar_filter"), "Missing radar_filter binding in schema")
	assert(keys.has("radar_enlarge"), "Missing radar_enlarge binding in schema")
	print("  PASS: Settings schema entries verified.")

func test_filter_mode_cycling() -> void:
	print("Testing radar filter mode cycling...")
	var scope = RadarScopeScript.new()
	root.add_child(scope)
	
	assert(scope.filter_mode == RadarScopeScript.FilterMode.ALL, "Default filter mode must be ALL")
	
	scope.cycle_filter_mode()
	assert(scope.filter_mode == RadarScopeScript.FilterMode.AIR_ONLY, "First cycle must be AIR_ONLY")
	
	scope.cycle_filter_mode()
	assert(scope.filter_mode == RadarScopeScript.FilterMode.GROUND_ONLY, "Second cycle must be GROUND_ONLY")
	
	scope.cycle_filter_mode()
	assert(scope.filter_mode == RadarScopeScript.FilterMode.ALL, "Third cycle must return to ALL")
	
	scope.queue_free()
	print("  PASS: Filter mode cycling verified.")

func test_enlarge_toggle() -> void:
	print("Testing radar enlarge toggle...")
	var scope = RadarScopeScript.new()
	root.add_child(scope)
	
	assert(scope._enlarged == false, "Initial enlarged state must be false")
	
	scope.toggle_enlarge()
	assert(scope._enlarged == true, "First toggle must enlarge")
	
	scope.toggle_enlarge()
	assert(scope._enlarged == false, "Second toggle must return to normal size")
	
	scope.queue_free()
	print("  PASS: Enlarge toggle verified.")

class MockMain extends Node:
	var radar_scope: Node = null

func test_controls_action_dispatch() -> void:
	print("Testing controls action handling...")
	var controls = ControlsScript.new()
	var mock_main = MockMain.new()
	var scope = RadarScopeScript.new()
	mock_main.radar_scope = scope
	controls.main = mock_main
	root.add_child(controls)
	root.add_child(mock_main)
	root.add_child(scope)
	
	# Test radar_filter dispatch
	controls._on_action_pressed("radar_filter")
	assert(scope.filter_mode == RadarScopeScript.FilterMode.AIR_ONLY, "Controls action must cycle filter")
	
	# Test radar_enlarge dispatch
	controls._on_action_pressed("radar_enlarge")
	assert(scope._enlarged == true, "Controls action must toggle enlarge")
	
	controls.queue_free()
	mock_main.queue_free()
	scope.queue_free()
	print("  PASS: Controls action dispatch verified.")
