extends Node

const PuffSystem := preload("res://fx/puff_system.gd")
const ExplosionFXScript := preload("res://fx/explosion_fx.gd")

# Crash sites: where a jet hits the ground it burns for BURN_SECONDS with black smoke rising, then the
# smoke thins out. Water impacts get no fire (water splash crown is triggered via explosion_fx.gd); the impact
# fireball itself is YS's explosion (explosion_fx.gd). Input: the "crashes" list of get_aircraft_fx_state()
# (stride 5: x, y, z, on_water, radius). The falling jet's smoke/fire trail is the C++ trail renderer's.
# Cost: at most MAX_SITES sites, ~3 puffs per second each, all from the shared GPU-aged puff pool.

const MAX_SITES := 8
const BURN_SECONDS := 30.0
const SMOKE_TAIL_SECONDS := 6.0   # smoke keeps rising (thinning) this long after the fire is out
const SMOKE := Color(0.05, 0.05, 0.05, 0.85)
const FIRE := Color(1.0, 0.5, 0.12, 0.95)

var puffs: PuffSystem = null
var explosions: ExplosionFXScript = null
var quality: int = 1

var sites_created: int = 0 # total since start (tests)
var _sites: Array[Dictionary] = [] # { pos: Vector3, size: float, age: float, timer: float }

func setup(p_puffs: PuffSystem, p_explosions: ExplosionFXScript = null) -> void:
	puffs = p_puffs
	explosions = p_explosions

func update(delta: float, crashes: PackedFloat32Array) -> void:
	var rng := puffs.random()
	for i in range(0, crashes.size(), 5):
		if crashes[i + 3] > 0.5:
			# Water impact: trigger water splash crown via ExplosionFX
			if explosions != null:
				var pos := Vector3(crashes[i], crashes[i + 1], crashes[i + 2])
				explosions.trigger_water_crash(pos, crashes[i + 4])
			continue
		var pos := Vector3(crashes[i], crashes[i + 1], crashes[i + 2])
		var size: float = clampf(crashes[i + 4] / 8.0, 0.6, 2.5) # 1.0 = fighter-sized (8 m radius)
		# Impact burst: black smoke thrown up and out, fire at the centre
		for b in 8:
			var jitter := Vector3(rng.randf_range(-5.0, 5.0), rng.randf_range(0.0, 4.0), rng.randf_range(-5.0, 5.0)) * size
			var vel := Vector3(rng.randf_range(-6.0, 6.0), rng.randf_range(6.0, 14.0), rng.randf_range(-6.0, 6.0))
			puffs.spawn(pos + jitter, vel, 14.0 * size, 50.0 * size, 9.0, SMOKE)
		for f in 6:
			var jitter := Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(0.0, 3.0), rng.randf_range(-3.0, 3.0)) * size
			puffs.spawn(pos + jitter, Vector3(0.0, rng.randf_range(3.0, 7.0), 0.0), 10.0 * size, 4.0 * size, 1.2, FIRE, 1.0)
		if _sites.size() >= MAX_SITES:
			_sites.pop_front()
		_sites.append({"pos": pos, "size": size, "age": 0.0, "timer": 0.0})
		sites_created += 1

	var interval: float = 0.5 if quality <= 0 else 0.33
	var alive: Array[Dictionary] = []
	for site in _sites:
		site["age"] += delta
		var age: float = site["age"]
		if age >= BURN_SECONDS + SMOKE_TAIL_SECONDS:
			continue
		site["timer"] = minf(site["timer"] + delta, interval * 4.0) # bounded catch-up after a long frame
		var base: Vector3 = site["pos"]
		var size: float = site["size"]
		var fade: float = clampf((BURN_SECONDS + SMOKE_TAIL_SECONDS - age) / SMOKE_TAIL_SECONDS, 0.0, 1.0)
		while site["timer"] >= interval:
			site["timer"] -= interval
			var smoke := Color(SMOKE.r, SMOKE.g, SMOKE.b, SMOKE.a * fade)
			puffs.spawn(base + Vector3(rng.randf_range(-2.0, 2.0), rng.randf_range(0.0, 2.0), rng.randf_range(-2.0, 2.0)) * size,
				Vector3(rng.randf_range(-1.5, 1.5), 8.0, rng.randf_range(-1.5, 1.5)), 8.0 * size, 45.0 * size, 12.0, smoke)
			if age < BURN_SECONDS:
				puffs.spawn(base + Vector3(rng.randf_range(-3.0, 3.0), 1.0, rng.randf_range(-3.0, 3.0)) * size,
					Vector3(0.0, rng.randf_range(3.0, 6.0), 0.0), 13.0 * size, 5.0 * size, 1.1, FIRE, 1.0)
		alive.append(site)
	_sites = alive

# The render origin moved by delta (main.gd): burning sites are stored in render space.
func rebase(delta: Vector3) -> void:
	for site in _sites:
		site["pos"] -= delta

func site_count() -> int:
	return _sites.size()
