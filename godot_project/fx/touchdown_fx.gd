extends Node

const PuffSystem := preload("res://fx/puff_system.gd")

# Touchdown tire smoke: spawns a brief burst of white/grey rubber smoke puffs at the left and right main
# landing gear when the player aircraft (or a nearby landing aircraft) touches down at landing speed.
# Uses the shared GPU-aged PuffSystem pool (zero extra draw calls or shaders).

const TIRE_SMOKE_COLOR := Color(0.90, 0.91, 0.92, 0.72)
const MIN_TOUCHDOWN_SPEED_MS := 22.0
const COOLDOWN_SECONDS := 2.5

var puffs: PuffSystem = null
var quality: int = 1
var bursts_spawned: int = 0
var _player_cooldown_s: float = 0.0

func setup(p_puffs: PuffSystem) -> void:
	puffs = p_puffs

func trigger_burst(tfm: Transform3D, vel: Vector3, radius: float = 8.0) -> void:
	if puffs == null or _player_cooldown_s > 0.0:
		return
	if vel.length() < MIN_TOUCHDOWN_SPEED_MS:
		return
	_player_cooldown_s = COOLDOWN_SECONDS
	var rng := puffs.random()
	var scale_f: float = clampf(radius / 8.0, 0.65, 2.2)
	var right: Vector3 = tfm.basis.x.normalized()
	var up: Vector3 = tfm.basis.y.normalized()
	var back: Vector3 = tfm.basis.z.normalized() # +Z in Godot is aft
	var gear_y: float = -1.55 * scale_f
	var gear_x: float = 1.55 * scale_f
	var gear_z: float = 1.10 * scale_f
	var puffs_per_wheel: int = 2 if quality <= 0 else (3 if quality == 1 else 4)
	var base_drift: Vector3 = vel * 0.18 + back * 4.0
	for side in [-1.0, 1.0]:
		var wheel_pos: Vector3 = tfm.origin + right * (side * gear_x) + up * gear_y + back * gear_z
		for i in puffs_per_wheel:
			var frac: float = float(i) / float(maxi(puffs_per_wheel - 1, 1))
			var pos: Vector3 = wheel_pos + back * (frac * 2.2 * scale_f) + Vector3(
				rng.randf_range(-0.35, 0.35),
				rng.randf_range(-0.10, 0.20),
				rng.randf_range(-0.35, 0.35)
			) * scale_f
			var puff_vel: Vector3 = base_drift + right * (side * rng.randf_range(0.8, 2.4)) + Vector3(
				rng.randf_range(-0.8, 0.8),
				rng.randf_range(0.6, 1.8),
				rng.randf_range(-0.8, 0.8)
			)
			var size0: float = rng.randf_range(1.4, 2.2) * scale_f
			var size1: float = rng.randf_range(4.8, 7.2) * scale_f
			var life: float = rng.randf_range(1.2, 1.9)
			puffs.spawn(pos, puff_vel, size0, size1, life, TIRE_SMOKE_COLOR, 0.0, 0.35)
	bursts_spawned += 1

func update(delta: float, _cam_pos: Vector3, _player_tfm: Transform3D, _tel: Dictionary, _airplanes: Dictionary) -> void:
	if _player_cooldown_s > 0.0:
		_player_cooldown_s = maxf(0.0, _player_cooldown_s - delta)
