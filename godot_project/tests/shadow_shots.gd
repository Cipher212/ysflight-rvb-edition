extends Node

# Screenshot harness for the sun-angled shadows (main.gd --shadow-shots <dir>): sets each time of day in turn
# and saves two screenshots per preset - the default chase camera (the player's jet) and a fixed camera looking
# at the building-sized ground object nearest the player - then quits. Run with tools/shadow_shots.py.

const SETTLE_S := 6.0       # mission load, ground shadow bake, the chase camera settling behind the jet
const PER_PRESET_S := 1.2   # the day cycle applies at 1 Hz
const PRESETS := ["DAWN", "DAYLIGHT", "SUNSET", "NIGHT"]
const MIN_SIZE_M := 12.0    # a building, not a light pole
const MAX_SIZE_M := 120.0
const VIEW_BACK := 2.2      # camera distance in building sizes
const VIEW_UP := 1.1

var main: Node = null
var out_dir := ""

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	await get_tree().create_timer(SETTLE_S).timeout
	var chase: Camera3D = get_viewport().get_camera_3d()
	var building_cam := _building_camera()
	for preset in PRESETS:
		main.day_cycle.set_time_mode(preset)
		await get_tree().create_timer(PER_PRESET_S).timeout
		await _save("%s_jet" % preset.to_lower())
		if building_cam != null:
			building_cam.make_current()
			await _save("%s_building" % preset.to_lower())
			chase.make_current()
	get_tree().quit(0)

func _save(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_jpg(out_dir.path_join(shot_name + ".jpg"), 0.9)

# A camera south-west of and above the nearest building-sized ground model, looking at it.
func _building_camera() -> Camera3D:
	var grounds: Node = main.ysflight_sim.get_node_or_null("GroundsRoot")
	if grounds == null:
		return null
	var player: Vector3 = main.ysflight_sim.get_player_transform().origin
	var best_box := AABB()
	var best_d := INF
	for g in grounds.get_children():
		if not (g is Node3D) or not g.visible:
			continue
		var box := _world_box(g)
		var size: float = maxf(box.size.x, box.size.z)
		var d: float = box.get_center().distance_to(player)
		if size >= MIN_SIZE_M and size <= MAX_SIZE_M and box.size.y < size and d < best_d:
			best_d = d
			best_box = box
	if best_d == INF:
		return null
	var size: float = maxf(best_box.size.x, best_box.size.z)
	var target := best_box.get_center() - Vector3(0.0, best_box.size.y * 0.5, 0.0)
	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = target + Vector3(-1.0, 0.0, 1.0).normalized() * size * VIEW_BACK + Vector3.UP * size * VIEW_UP
	cam.look_at(target, Vector3.UP)
	cam.fov = 60.0
	return cam

func _world_box(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for c in node.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null:
			continue
		var b: AABB = mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box
