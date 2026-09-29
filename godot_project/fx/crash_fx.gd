extends Node

const PuffSystem := preload("res://fx/puff_system.gd")

# Crash sites: a burst of black smoke and fire where a shot-down aircraft hits the ground, then a rising
# column of black smoke (fire at its base for the first seconds). Nothing on water. Input: the "crashes"
# list of get_aircraft_fx_state() (stride 5: x, y, z, on_water, radius). The falling aircraft's own smoke
# and fire trail is drawn by the C++ trail renderer.

const MAX_PLUMES := 8
const PLUME_SECONDS := 45.0
const PLUME_FIRE_SECONDS := 12.0
const SMOKE := Color(0.06, 0.06, 0.06, 0.8)
const FIRE := Color(1.0, 0.5, 0.12, 0.9)

var puffs: PuffSystem = null
var quality: int = 1

var _plumes: Array[Dictionary] = [] # { pos: Vector3, age: float, timer: float }

func setup(p_puffs: PuffSystem) -> void:
	puffs = p_puffs

func update(delta: float, crashes: PackedFloat32Array) -> void:
	var rng := puffs.random()
	for i in range(0, crashes.size(), 5):
		if crashes[i + 3] > 0.5:
			continue # water
		var pos := Vector3(crashes[i], crashes[i + 1], crashes[i + 2])
		for b in 8:
			var jitter := Vector3(rng.randf_range(-4.0, 4.0), rng.randf_range(0.0, 3.0), rng.randf_range(-4.0, 4.0))
			var vel := Vector3(rng.randf_range(-5.0, 5.0), rng.randf_range(4.0, 10.0), rng.randf_range(-5.0, 5.0))
			puffs.spawn(pos + jitter, vel, 12.0, 45.0, 9.0, SMOKE)
		for f in 5:
			var jitter := Vector3(rng.randf_range(-2.0, 2.0), rng.randf_range(0.0, 2.0), rng.randf_range(-2.0, 2.0))
			puffs.spawn(pos + jitter, Vector3(0.0, rng.randf_range(2.0, 5.0), 0.0), 7.0, 3.0, 0.9, FIRE, 1.0)
		if _plumes.size() >= MAX_PLUMES:
			_plumes.pop_front()
		_plumes.append({"pos": pos, "age": 0.0, "timer": 0.0})

	# Rising column: one smoke puff every `interval` seconds per plume
	var interval: float = 0.5 if quality <= 0 else 0.3
	var alive: Array[Dictionary] = []
	for p in _plumes:
		p["age"] += delta
		if p["age"] >= PLUME_SECONDS:
			continue
		p["timer"] = minf(p["timer"] + delta, interval * 4.0) # bounded catch-up after a long frame
		while p["timer"] >= interval:
			p["timer"] -= interval
			var base: Vector3 = p["pos"]
			puffs.spawn(base + Vector3(rng.randf_range(-1.5, 1.5), rng.randf_range(0.0, 1.0), rng.randf_range(-1.5, 1.5)),
				Vector3(rng.randf_range(-1.5, 1.5), 7.0, rng.randf_range(-1.5, 1.5)), 9.0, 50.0, 14.0, SMOKE)
			if p["age"] <= PLUME_FIRE_SECONDS:
				puffs.spawn(base + Vector3(rng.randf_range(-1.0, 1.0), 0.5, rng.randf_range(-1.0, 1.0)),
					Vector3(0.0, 2.0, 0.0), 5.0, 2.0, 0.9, FIRE, 0.8)
		alive.append(p)
	_plumes = alive
