extends SceneTree

# Quick script to fly the jet toward and into a cloud bank and capture proof screenshots.
func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var main_scene = load("res://main.tscn").instantiate()
	root.add_child(main_scene)

	var main = main_scene
	var sim = main.ysflight_sim
	var cam_rig = main.camera_rig

	# Teleport player right in front of Cloud 1
	var cloud1_pos: Vector3 = main.low_cloud_layer._cloud_pos[1]
	# Place player 1.2 km outside cloud, heading towards center
	var spawn_pos := cloud1_pos + Vector3(0.0, -100.0, 3200.0)
	var spawn_tfm := Transform3D(Basis(Vector3.UP, PI), spawn_pos)
	sim.set_player_transform(spawn_tfm)

	# Stabilize for a few frames
	for f in 20:
		await process_frame

	var out_dir := ProjectSettings.globalize_path("res://../crashlog/clouds")
	DirAccess.make_dir_recursive_absolute(out_dir)

	# Screenshot 1: F2 Horizon Chase view outside entering the cloud
	cam_rig.set_mode(cam_rig.CamMode.HORIZON_CHASE)
	for f in 10:
		await process_frame
	await RenderingServer.frame_post_draw
	var img1 := root.get_texture().get_image()
	if img1:
		img1.save_jpg(out_dir.path_join("proof_chase_cloud_approach.jpg"), 0.90)

	# Now move player inside the cloud bank
	var inside_pos := cloud1_pos + Vector3(0.0, 0.0, 500.0)
	var inside_tfm := Transform3D(Basis(Vector3.UP, PI), inside_pos)
	sim.set_player_transform(inside_tfm)

	# Screenshot 2: Cockpit view (F1) inside the cloud bank
	cam_rig.set_mode(cam_rig.CamMode.COCKPIT)
	for f in 25:
		main.low_cloud_layer.update(0.05, inside_pos, false)
		await process_frame
	await RenderingServer.frame_post_draw
	var img2 := root.get_texture().get_image()
	if img2:
		img2.save_jpg(out_dir.path_join("proof_cockpit_inside_cloud.jpg"), 0.90)

	print("[FlightProof] Screenshots captured successfully.")
	quit(0)
