extends SceneTree

# Focused verification for differentiated explosion incidents and sprite effects.
# Verifies:
#   - Category constants & mapping (0..5)
#   - Bridge dictionary keys (incident_type, weapon_type, slot_id, uid, exp_type, etc.)
#   - Land & water incident retention (both origin & exp_type)
#   - Slot reuse without stale metadata
#   - Unknown/default/replay activation fallback
#   - UID deduplication & mission-reset behavior
#   - Gun hits produce 0 light & 0 screen-glow requests
#   - Continuing wreck fire suppression
#   - Bounded pool saturation & quality scaling

const ExplosionFXScript = preload("res://fx/explosion_fx.gd")
const CrashFXScript = preload("res://fx/crash_fx.gd")
const PuffSystem = preload("res://fx/puff_system.gd")
const BlastGlow = preload("res://fx/blast_glow.gd")

var _failures: int = 0

func _init() -> void:
	print("[ExplosionIncidentsTest] Starting verification...")
	test_category_constants()
	test_sprite_atlas()
	test_incident_profiles_and_glow_suppression()
	test_continuing_fire_suppression()
	test_water_plumes()
	test_water_splash_mesh_and_pool()
	test_heavy_bomb_whitelist_and_clamping()
	test_uid_deduplication_and_reset()
	test_slot_reuse_and_defaults()
	test_quality_scaling()
	test_dead_aircraft_water_crash()
	test_water_crash_deduplication()
	
	print("\n[ExplosionIncidentsTest] Results: %d failures." % _failures)
	quit(_failures)

func _assert(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		printerr("FAIL: %s" % message)
		_failures += 1

func test_category_constants() -> void:
	_assert(ExplosionFXScript.INCIDENT_UNKNOWN == 0, "INCIDENT_UNKNOWN is 0")
	_assert(ExplosionFXScript.INCIDENT_GUN_IMPACT == 1, "INCIDENT_GUN_IMPACT is 1")
	_assert(ExplosionFXScript.INCIDENT_AIR_TO_AIR_MISSILE == 2, "INCIDENT_AIR_TO_AIR_MISSILE is 2")
	_assert(ExplosionFXScript.INCIDENT_GROUND_ORDNANCE == 3, "INCIDENT_GROUND_ORDNANCE is 3")
	_assert(ExplosionFXScript.INCIDENT_ENTITY_DESTRUCTION_OR_CRASH == 4, "INCIDENT_ENTITY_DESTRUCTION_OR_CRASH is 4")
	_assert(ExplosionFXScript.INCIDENT_CONTINUING_WRECK_FIRE == 5, "INCIDENT_CONTINUING_WRECK_FIRE is 5")

func test_sprite_atlas() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	root.add_child(fx)
	fx._ensure_init()
	_assert(fx._atlas_tex != null, "Explosion atlas ImageTexture built at startup")
	var img: Image = fx._atlas_tex.get_image()
	_assert(img.get_width() == 256 * 5 and img.get_height() == 256, "Atlas dimensions are 1280x256 (5 frames of 256x256)")
	_assert(fx.get_node_or_null("Flashes") != null, "Flash MultiMesh exists")
	_assert(fx.get_node_or_null("Sparks") != null, "Spark MultiMesh exists")
	_assert(fx._flash_mm.instance_count == ExplosionFXScript.MAX_FLASHES, "Flash pool capacity is bounded (%d)" % ExplosionFXScript.MAX_FLASHES)
	_assert(fx._spark_mm.instance_count == ExplosionFXScript.MAX_SPARKS, "Spark pool capacity is bounded (%d)" % ExplosionFXScript.MAX_SPARKS)
	fx.queue_free()

const BlastGlowClass = preload("res://fx/blast_glow.gd")

# Mock BlastGlow to verify glow requests
class MockBlastGlow extends BlastGlowClass:
	var glow_calls: int = 0
	var last_pos: Vector3 = Vector3.ZERO
	var last_size: float = 0.0

	func add(pos: Vector3, size: float) -> void:
		glow_calls += 1
		last_pos = pos
		last_size = size

func test_incident_profiles_and_glow_suppression() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	var mock_glow := MockBlastGlow.new()
	root.add_child(mock_glow)
	root.add_child(fx)
	fx.setup(null, mock_glow)

	# 1. Gun impact: must produce 0 screen glow requests
	var flash_head_before: int = fx._flash_head
	var exp_gun := [{
		"uid": 1001,
		"pos": Vector3(0, 10, 0),
		"radius": 3.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_GUN_IMPACT,
		"weapon_type": ExplosionFXScript.FSWEAPON_GUN
	}]
	fx.update(0.016, exp_gun)
	_assert(mock_glow.glow_calls == 0, "Gun hit produces 0 screen-glow requests")
	_assert(fx._flash_head == (flash_head_before + 1) % ExplosionFXScript.MAX_FLASHES, "Gun hit spawned exactly 1 small flash")

	# 2. AAM: produces screen glow
	var exp_aam := [{
		"uid": 1002,
		"pos": Vector3(100, 500, 100),
		"radius": 20.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_AIR_TO_AIR_MISSILE,
		"weapon_type": ExplosionFXScript.FSWEAPON_AIM9
	}]
	fx.update(0.016, exp_aam)
	_assert(mock_glow.glow_calls == 1, "AAM detonation triggers screen glow")

	# 3. Ground Ordnance (Bomb): produces heavy screen glow
	var exp_bomb := [{
		"uid": 1003,
		"pos": Vector3(50, 0, 50),
		"radius": 35.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_GROUND_ORDNANCE,
		"weapon_type": ExplosionFXScript.FSWEAPON_BOMB500HD
	}]
	fx.update(0.016, exp_bomb)
	_assert(mock_glow.glow_calls == 2, "Bomb impact triggers screen glow")

	mock_glow.queue_free()
	fx.queue_free()

func test_continuing_fire_suppression() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	var mock_glow := MockBlastGlow.new()
	root.add_child(mock_glow)
	root.add_child(fx)
	fx.setup(null, mock_glow)

	var flash_head_before: int = fx._flash_head
	var exp_wreck := [{
		"uid": 2001,
		"pos": Vector3(0, 10, 0),
		"radius": 15.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_CONTINUING_WRECK_FIRE,
		"weapon_type": -1
	}]
	fx.update(0.016, exp_wreck)
	_assert(fx._flash_head == flash_head_before, "Continuing wreck fire spawns 0 new flashes (suppressed)")
	_assert(mock_glow.glow_calls == 0, "Continuing wreck fire triggers 0 screen glow")

	mock_glow.queue_free()
	fx.queue_free()

func test_water_plumes() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	var mock_glow := MockBlastGlow.new()
	root.add_child(mock_glow)
	root.add_child(fx)
	fx.setup(null, mock_glow)

	var flash_head_before: int = fx._flash_head
	# Water plume with exp_type=1: spray only, zero fireball flashes, zero blast glow
	var exp_water := [{
		"uid": 3001,
		"pos": Vector3(0, 0, 0),
		"radius": 15.0,
		"exp_type": ExplosionFXScript.EXP_WATER_PLUME,
		"incident_type": ExplosionFXScript.INCIDENT_AIR_TO_AIR_MISSILE,
		"weapon_type": ExplosionFXScript.FSWEAPON_AIM9
	}]
	fx.update(0.016, exp_water)
	_assert(fx._flash_head == flash_head_before, "Water plume creates 0 orange fireball flashes")
	_assert(mock_glow.glow_calls == 0, "Water plume creates 0 fireball blast glow")

	mock_glow.queue_free()
	fx.queue_free()

func test_water_splash_mesh_and_pool() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	root.add_child(fx)
	fx._ensure_init()

	var splash = fx._water_splash
	_assert(splash != null, "Water splash child node created and initialized")
	_assert(splash._mesh != null, "Water splash mesh initialized")
	_assert(splash._mesh.get_surface_count() == 1, "Water splash mesh has exactly 1 surface")

	var arrays: Array = splash._mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	_assert(verts.size() == 64, "Water splash mesh has exactly 64 vertices (got %d)" % verts.size())
	_assert(indices.size() / 3 == 64, "Water splash mesh has exactly 64 triangles (got %d)" % (indices.size() / 3))
	_assert(splash._multimesh.instance_count == 8, "Water splash pool capacity is exactly 8 instances")

	# 1. Gun water impact: completely bypasses 8-slot splash crown pool
	var exp_gun_water := [{
		"uid": 7001,
		"pos": Vector3(10, 0, 10),
		"radius": 4.0,
		"exp_type": ExplosionFXScript.EXP_WATER_PLUME,
		"incident_type": ExplosionFXScript.INCIDENT_GUN_IMPACT,
		"weapon_type": ExplosionFXScript.FSWEAPON_GUN
	}]
	fx.update(0.016, exp_gun_water)
	var active_count: int = 0
	for i in splash.MAX_SPLASHES:
		if splash._slot_active[i]:
			active_count += 1
	_assert(active_count == 0, "Gun water impact completely bypasses 8-slot splash crown pool (0 active)")

	# 2. Heavy water impact: allocates exactly 1 splash crown slot
	var exp_heavy_water := [{
		"uid": 7002,
		"pos": Vector3(50, 0, 50),
		"radius": 20.0,
		"exp_type": ExplosionFXScript.EXP_WATER_PLUME,
		"incident_type": ExplosionFXScript.INCIDENT_AIR_TO_AIR_MISSILE,
		"weapon_type": ExplosionFXScript.FSWEAPON_AIM9
	}]
	fx.update(0.016, exp_heavy_water)
	active_count = splash.get_active_count()
	_assert(active_count == 1, "Heavy water impact allocates exactly 1 splash crown slot")

	var active_slot: int = -1
	for i in splash.MAX_SPLASHES:
		if splash._slot_active[i]:
			active_slot = i
			break
	_assert(active_slot >= 0, "Valid active splash slot found")
	if active_slot >= 0:
		_assert(splash._slot_pos[active_slot].is_equal_approx(Vector3(50, 0, 50)), "Splash contact origin matches input position")
		_assert(splash._slot_base_r[active_slot] > 0.0, "Splash base radius is positive")
		_assert(splash._slot_top_r[active_slot] > 0.0, "Splash top radius is positive")
		_assert(splash._slot_height[active_slot] > 0.0, "Splash height is positive")

	# 3. Reset behavior: clears all active slots and parameters
	fx.reset()
	_assert(splash.get_active_count() == 0, "reset() clears all active splash slots")
	var reset_clean: bool = true
	for i in splash.MAX_SPLASHES:
		if splash._slot_active[i] or splash._slot_spawn_time[i] != -1000.0 or splash._slot_height[i] != 0.0:
			reset_clean = false
	_assert(reset_clean, "reset() reverts all splash slot telemetry to default inactive state")

	fx.queue_free()

func test_heavy_bomb_whitelist_and_clamping() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	root.add_child(fx)
	fx.quality = 1 # Normal quality

	# 1. Whitelisted bomb (FSWEAPON_BOMB500HD): receives 1.5x visual scaling
	fx.update(0.016, [{
		"uid": 8001,
		"pos": Vector3(0, 0, 0),
		"radius": 30.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_GROUND_ORDNANCE,
		"weapon_type": ExplosionFXScript.FSWEAPON_BOMB500HD
	}])
	var bomb500_end_size: float = fx._last_flash_size1

	# 2. Non-whitelisted bomb (FSWEAPON_BOMB250): remains at 1.0x baseline
	fx.update(0.016, [{
		"uid": 8002,
		"pos": Vector3(100, 0, 100),
		"radius": 30.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_GROUND_ORDNANCE,
		"weapon_type": ExplosionFXScript.FSWEAPON_BOMB250
	}])
	var bomb250_end_size: float = fx._last_flash_size1

	# Expected: 30.0 * 1.5 * 1.6 = 72.0 vs 30.0 * 1.0 * 1.6 = 48.0 (1.5x ratio)
	_assert(is_equal_approx(bomb500_end_size, 72.0), "Whitelisted BOMB500HD receives 1.5x visual scaling (got %.1f, expected 72.0)" % bomb500_end_size)
	_assert(is_equal_approx(bomb250_end_size, 48.0), "Non-whitelisted BOMB250 remains at 1.0x baseline (got %.1f, expected 48.0)" % bomb250_end_size)
	_assert(is_equal_approx(bomb500_end_size / bomb250_end_size, 1.5), "Whitelisted heavy bomb is exactly 1.5x larger than non-whitelisted BOMB250")

	# 3. Normal quality upper ceiling (144.0m * 0.75 = 108.0m for flash2)
	fx.update(0.016, [{
		"uid": 8003,
		"pos": Vector3(200, 0, 200),
		"radius": 100.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_GROUND_ORDNANCE,
		"weapon_type": ExplosionFXScript.FSWEAPON_BOMB
	}])
	var huge_bomb_end_size: float = fx._last_flash_size1
	_assert(huge_bomb_end_size <= ExplosionFXScript.MAX_FLASH_END_WIDTH_NORMAL * 0.75, "Normal quality bomb flash capped by upper ceiling (%.1f <= %.1f)" % [huge_bomb_end_size, ExplosionFXScript.MAX_FLASH_END_WIDTH_NORMAL * 0.75])

	# 4. Low quality upper ceiling (70.0m * 0.75 = 52.5m for flash2)
	fx.quality = 0
	fx.update(0.016, [{
		"uid": 8004,
		"pos": Vector3(300, 0, 300),
		"radius": 40.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_GROUND_ORDNANCE,
		"weapon_type": ExplosionFXScript.FSWEAPON_BOMB
	}])
	var low_bomb_end_size: float = fx._last_flash_size1
	_assert(low_bomb_end_size <= ExplosionFXScript.MAX_FLASH_END_WIDTH_LOW * 0.75, "Low quality bomb flash strictly clamped to MAX_FLASH_END_WIDTH_LOW (%.1f <= %.1f)" % [low_bomb_end_size, ExplosionFXScript.MAX_FLASH_END_WIDTH_LOW * 0.75])
	_assert(is_equal_approx(low_bomb_end_size, ExplosionFXScript.MAX_FLASH_END_WIDTH_LOW * 0.75), "Low quality bomb flash reaches exactly the 70m ceiling limit (52.5m for secondary flash)")

	fx.queue_free()

func test_uid_deduplication_and_reset() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	root.add_child(fx)

	var exp_list := [{
		"uid": 4001,
		"pos": Vector3(0, 0, 0),
		"radius": 10.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_AIR_TO_AIR_MISSILE,
		"weapon_type": ExplosionFXScript.FSWEAPON_AIM9
	}]

	# First update: triggers effect
	fx.update(0.016, exp_list)
	var flash_head_after_first: int = fx._flash_head

	# Second update with same explosion still active in sim: must NOT trigger again
	fx.update(0.016, exp_list)
	_assert(fx._flash_head == flash_head_after_first, "Duplicate active UID does not trigger redundant emissions")

	# Reset: clears seen UIDs
	fx.reset()
	_assert(fx._seen_uids.is_empty(), "reset() clears seen UID cache")

	fx.queue_free()

func test_slot_reuse_and_defaults() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	root.add_child(fx)

	# Simulating slot 5 being used first by a bomb
	var slot_id: int = 5
	var rand1: int = 12345
	var uid1: int = (slot_id << 32) | rand1
	fx.update(0.016, [{
		"slot_id": slot_id,
		"uid": uid1,
		"pos": Vector3(0, 0, 0),
		"radius": 20.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_GROUND_ORDNANCE,
		"weapon_type": ExplosionFXScript.FSWEAPON_BOMB
	}])

	# Sim slot 5 freed and later reused by gun hit with new random number
	fx.update(0.016, []) # slot becomes inactive
	var rand2: int = 67890
	var uid2: int = (slot_id << 32) | rand2
	var head_before: int = fx._flash_head
	fx.update(0.016, [{
		"slot_id": slot_id,
		"uid": uid2,
		"pos": Vector3(10, 10, 10),
		"radius": 3.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_GUN_IMPACT,
		"weapon_type": ExplosionFXScript.FSWEAPON_GUN
	}])
	_assert(fx._flash_head != head_before, "Reused slot with new random UID triggers cleanly without stale data")

	# Legacy/unclassified dictionary without incident_type or weapon_type
	var head_before_fallback: int = fx._flash_head
	fx.update(0.016, [{
		"slot_id": 6,
		"uid": 99999,
		"pos": Vector3(20, 20, 20),
		"radius": 5.0,
		"exp_type": 0
	}])
	_assert(fx._flash_head != head_before_fallback, "Unclassified legacy dictionary safely falls back without errors")

	fx.queue_free()

func test_quality_scaling() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	root.add_child(fx)
	fx.quality = 0 # Low FX quality

	var head_before: int = fx._flash_head
	fx.update(0.016, [{
		"uid": 5001,
		"pos": Vector3(0, 0, 0),
		"radius": 25.0,
		"exp_type": 0,
		"incident_type": ExplosionFXScript.INCIDENT_AIR_TO_AIR_MISSILE,
		"weapon_type": ExplosionFXScript.FSWEAPON_AIM120
	}])
	_assert(fx._flash_head != head_before, "Low quality handles incident emissions correctly")

	fx.queue_free()

func test_dead_aircraft_water_crash() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	var crashes_node: Node = CrashFXScript.new()
	var puffs: Node3D = PuffSystem.new()
	root.add_child(puffs)
	root.add_child(fx)
	root.add_child(crashes_node)
	fx.setup(puffs, null)
	crashes_node.setup(puffs, fx)

	# Simulate shot-down / tumbling aircraft crashing into water:
	# Stride 5: [x, y, z, on_water, radius]
	var test_pos := Vector3(150.0, 0.0, -250.0)
	var outside_radius := 8.5
	var crashes := PackedFloat32Array([test_pos.x, test_pos.y, test_pos.z, 1.0, outside_radius])

	crashes_node.update(0.016, crashes)

	var splash = fx._water_splash
	_assert(splash != null, "Water splash node available")
	_assert(splash.get_active_count() == 1, "Dead aircraft water crash spawns exactly 1 splash crown")

	var slot: int = -1
	for i in splash.MAX_SPLASHES:
		if splash._slot_active[i]:
			slot = i
			break
	_assert(slot >= 0, "Active splash slot located")
	if slot >= 0:
		_assert(splash._slot_pos[slot].distance_to(test_pos) < 0.01, "Splash spawned at aircraft water contact coordinates")
		_assert(splash._slot_base_r[slot] >= 14.0 and splash._slot_base_r[slot] <= 24.0, "Splash base radius in entity crash profile range (14-24m)")
		_assert(splash._slot_top_r[slot] >= 22.0 and splash._slot_top_r[slot] <= 35.0, "Splash top radius in entity crash profile range (22-35m)")
		_assert(splash._slot_height[slot] >= 42.0 and splash._slot_height[slot] <= 62.0, "Splash height in entity crash profile range (42-62m)")
		_assert(is_equal_approx(splash._slot_life[slot], 2.2), "Splash lifetime matches entity crash profile (2.2s)")

	_assert(crashes_node.site_count() == 0, "Water crash does not create burning land crash site")

	crashes_node.queue_free()
	fx.queue_free()
	puffs.queue_free()

func test_water_crash_deduplication() -> void:
	var fx: Node3D = ExplosionFXScript.new()
	var crashes_node: Node = CrashFXScript.new()
	var puffs: Node3D = PuffSystem.new()
	root.add_child(puffs)
	root.add_child(fx)
	root.add_child(crashes_node)
	fx.setup(puffs, null)
	crashes_node.setup(puffs, fx)

	# Simulate alive aircraft crash into water where YSCE creates an explosion plume
	# AND aircraft_fx_query also reports the crash in crashes array
	var test_pos := Vector3(300.0, 0.0, 300.0)
	var exp_plume := [{
		"uid": 8801,
		"pos": test_pos,
		"radius": 42.5,
		"exp_type": ExplosionFXScript.EXP_WATER_PLUME,
		"incident_type": ExplosionFXScript.INCIDENT_ENTITY_DESTRUCTION_OR_CRASH,
		"weapon_type": -1
	}]
	var crashes := PackedFloat32Array([test_pos.x, test_pos.y, test_pos.z, 1.0, 8.5])

	# First, sim explosions are processed:
	fx.update(0.016, exp_plume)
	_assert(fx._water_splash.get_active_count() == 1, "YSCE explosion plume spawned initial splash crown")

	# Second, crashes array is processed in the same frame:
	crashes_node.update(0.016, crashes)
	_assert(fx._water_splash.get_active_count() == 1, "Duplicate water splash was cleanly suppressed by deduplication")

	crashes_node.queue_free()
	fx.queue_free()
	puffs.queue_free()
