extends Node

# Render precision probe (main.gd starts it with "-- --precision-probe"; tools/precision_probe.py runs it and
# prints the result). The AI flies the player jet in cockpit view; the jet is moved to points near and far from
# the map centre and, every frame, the jet model's position as the camera sees it is measured. With the camera
# fixed to the cockpit that position never changes, so its frame-to-frame jerk (second difference) is pure
# float rounding = the shake; a jump at a render origin shift would show up as a huge value.
# Maths in 64-bit floats on the 32-bit values Godot draws with.
# Writes probe.json (per scenario: jerk mean / p99 / max in mm and in pixels on a panel 1 m away) and quits.

const SETTLE_S := 1.5
const SAMPLE_FRAMES := 240
# Absolute YS positions (x east, y up, z north) the player is moved to.
const SCENARIOS := [
	{"name": "near centre", "pos": Vector3.ZERO, "move": false},
	{"name": "8 km out, 2 km up", "pos": Vector3(6000.0, 2000.0, -5300.0), "move": true},
	{"name": "25 km out, 2 km up", "pos": Vector3(18000.0, 2000.0, 17000.0), "move": true},
	{"name": "25 km out, 9 km up", "pos": Vector3(18000.0, 9000.0, 17000.0), "move": true},
	{"name": "45 km out, 3 km up", "pos": Vector3(-32000.0, 3000.0, 32000.0), "move": true},
]

var main: Node = null
var sim: YSFlightSimulation = null
var out_dir: String = ""

var _sampling := false
var _samples: Array = [] # camera-space jet positions, [x, y, z] in 64-bit floats
var _shifts: int = 0

func setup(p_main: Node, p_out_dir: String) -> void:
	main = p_main
	sim = main.ysflight_sim
	process_priority = 10 # after main.gd placed the camera for this frame
	out_dir = p_out_dir
	DirAccess.make_dir_recursive_absolute(out_dir)
	if sim.has_signal("render_origin_shifted"):
		sim.render_origin_shifted.connect(func(_d: Vector3) -> void: _shifts += 1)
	_run.call_deferred()

func _process(_delta: float) -> void:
	if not _sampling:
		return
	var model := _player_model()
	if model == null or main.camera_rig.mode != main.camera_rig.CamMode.COCKPIT:
		return
	var cam: Transform3D = main.camera.global_transform
	var obj: Transform3D = model.global_transform
	# r = camera_basis^T * (object_origin - camera_origin), every component as a 64-bit float
	var d := [float(obj.origin.x) - float(cam.origin.x), float(obj.origin.y) - float(cam.origin.y),
		float(obj.origin.z) - float(cam.origin.z)]
	var r := []
	for axis in [cam.basis.x, cam.basis.y, cam.basis.z]:
		r.append(float(axis.x) * d[0] + float(axis.y) * d[1] + float(axis.z) * d[2])
	_samples.append(r)

# The player's exterior model: updated every frame (the cockpit shell is drawn at the same transform).
func _player_model() -> Node3D:
	var key := _player_key()
	if key < 0 or not bool(sim.get_player_telemetry().get("is_alive", false)):
		return null
	var found := sim.find_children("Airplane_%d" % key, "Node3D", true, false)
	return found[0] if found.size() > 0 else null

func _player_key() -> int:
	var air: Dictionary = sim.get_airplane_transforms()
	for k in air:
		if bool(air[k].get("is_player", false)):
			return int(k)
	return -1

func _run() -> void:
	await _seconds(3.0)
	var results: Array = []
	for sc in SCENARIOS:
		main.camera_rig.set_mode(main.camera_rig.CamMode.COCKPIT)
		if sc["move"]:
			var p: Vector3 = sc["pos"]
			sim.debug_move_airplane(_player_key(), p.x, p.y, p.z)
		await _seconds(SETTLE_S)
		_samples.clear()
		_shifts = 0
		_sampling = true
		while _samples.size() < SAMPLE_FRAMES:
			await get_tree().process_frame
		_sampling = false
		var stats := _jerk_stats(_samples)
		stats["name"] = sc["name"]
		stats["camera_render_pos"] = str(main.camera.global_position)
		stats["render_origin"] = str(sim.get_render_origin()) if sim.has_method("get_render_origin") else "n/a (no floating origin)"
		stats["origin_shifts"] = _shifts
		results.append(stats)
		print("PROBE %s: jerk mean %.4f mm, p99 %.4f mm, max %.4f mm (%.2f px max), camera at %s" % [
			sc["name"], stats["mean_mm"], stats["p99_mm"], stats["max_mm"], stats["max_px"], stats["camera_render_pos"]])
	var f := FileAccess.open(out_dir.path_join("probe.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"scenarios": results}, "\t"))
	f.close()
	get_tree().quit(0)

# Frame-to-frame jerk |r(t) - 2 r(t-1) + r(t-2)|: smooth motion gives ~0, rounding noise does not.
func _jerk_stats(samples: Array) -> Dictionary:
	var jerks := PackedFloat64Array()
	for i in range(2, samples.size()):
		var s := 0.0
		for a in 3:
			var j: float = samples[i][a] - 2.0 * samples[i - 1][a] + samples[i - 2][a]
			s += j * j
		jerks.append(sqrt(s) * 1000.0)
	var sorted := jerks.duplicate()
	sorted.sort()
	var mean := 0.0
	for v in jerks:
		mean += v
	mean /= maxi(jerks.size(), 1)
	var n := sorted.size()
	# Pixels at 1080p for a point 1 m in front of the eye (panel distance), at the cockpit FOV.
	var px_per_mm: float = 540.0 / tan(deg_to_rad(main.camera.fov) * 0.5) / 1000.0
	return {
		"frames": n,
		"mean_mm": mean,
		"p99_mm": sorted[int(n * 0.99)] if n > 0 else 0.0,
		"max_mm": sorted[n - 1] if n > 0 else 0.0,
		"max_px": (sorted[n - 1] if n > 0 else 0.0) * px_per_mm,
		"mean_px": mean * px_per_mm,
	}

func _seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout
