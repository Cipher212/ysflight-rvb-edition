extends Control

# F-16-only collimated vectors, clipped to the actual two-patch combiner.
# All world positions are fresh render-space values; no history survives an origin shift.
const Symbols = preload("res://ui/cockpit/f16_hud_symbols.gd")
const AIRCRAFT := "F-16(BLUE/MULTIROLE)"
const SOURCE := "res://user/RvB/blue/f16hud.srf"
const COAMING_MARGIN := 22.0 # pixels at the normal 65-degree cockpit field of view
const FRAME_MARGIN := 2.0
var camera: Camera3D
var aircraft := Transform3D.IDENTITY
var telemetry: Dictionary = {}
var target: Dictionary = {}
var aperture := PackedVector2Array()
var hud_min := Vector2.ZERO
var hud_max := Vector2.ZERO
var hud_center := Vector2.ZERO
var hud_size := Vector2.ZERO
var _vertices := PackedVector3Array()
var _mask: Polygon2D
var _symbols: Control
var _view := Basis.IDENTITY
var _view_aircraft := Basis.IDENTITY
var _forward := Vector3.FORWARD
var _right := Vector3.RIGHT
var _center := Vector2.ZERO
var _focal := Vector2.ONE
var _scale := 1.0
var _last_relative := Transform3D.IDENTITY
var _last_projection := Projection()
var _last_size := Vector2.ZERO
var _aperture_ready := false
var _controls: Node
var _enabled := true

func setup(controls: Node) -> void:
	_controls = controls
	_controls.changed.connect(_on_setting_changed)
	_on_setting_changed("cockpit_hud")

func _on_setting_changed(key: String) -> void:
	if key == "cockpit_hud" or key.is_empty():
		_enabled = bool(_controls.get_value("cockpit_hud", true))
		if not _enabled: visible = false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# These SRF vertices are aircraft-local (Mesh.001 has identity POS/CNT).
	var file := FileAccess.open(SOURCE, FileAccess.READ)
	if file != null:
		for line in file.get_as_text().split("\n"):
			var words := line.strip_edges().split(" ", false)
			if words.size() > 0 and words[0] == "F": break
			if words.size() >= 4 and words[0] == "V":
				_vertices.append(Vector3(float(words[1]), float(words[2]), -float(words[3])))
	_mask = Polygon2D.new()
	_mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	add_child(_mask)
	_symbols = Symbols.new()
	_symbols.hud = self
	_symbols.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mask.add_child(_symbols)
	visible = false

func update_display(cam: Camera3D, tfm: Transform3D, tel: Dictionary,
		airplanes: Dictionary, grounds: Dictionary, player_cockpit: bool) -> bool:
	var active: bool = _enabled and player_cockpit and tel.get("identifier", "") == AIRCRAFT \
		and bool(tel.get("is_alive", false)) and _vertices.size() >= 3
	if not active:
		if visible: visible = false
		return false
	camera = cam
	aircraft = tfm
	telemetry = tel
	# Cache the optical projection once. Camera.unproject_position repeats camera transforms
	# and projection setup for every vertex; that dominated the first prototype's CPU cost.
	_view = camera.global_basis.transposed()
	_view_aircraft = _view * aircraft.basis
	_center = camera.get_viewport().get_visible_rect().size * 0.5
	var projection := camera.get_camera_projection()
	_focal = Vector2(projection.x.x * _center.x, projection.y.y * _center.y)
	_scale = at(1.0, 0.0).distance_to(at(0.0, 0.0)) / 15.0
	_forward = -aircraft.basis.z
	_forward.y = 0.0
	_forward = _forward.normalized() if _forward.length_squared() > 0.00001 else Vector3.FORWARD
	_right = _forward.cross(Vector3.UP)
	target = airplanes.get(int(tel.get("locked_air_target_key", -1)), {})
	if target.is_empty():
		target = grounds.get(int(tel.get("locked_ground_target_key", -1)), {})
	# The glass silhouette depends on the eye relative to the aircraft, not map position.
	# Rebuild its offset polygon only after head motion / zoom / resize, not every flight frame.
	var relative := aircraft.affine_inverse() * camera.global_transform
	if not _aperture_ready or not relative.is_equal_approx(_last_relative) \
			or projection != _last_projection or _center != _last_size:
		_last_relative = relative
		_last_projection = projection
		_last_size = _center
		_aperture_ready = _update_aperture()
	if not _aperture_ready:
		visible = false
		return false
	if not visible: visible = true
	_symbols.queue_redraw()
	return true

func _update_aperture() -> bool:
	var points := PackedVector2Array()
	for vertex in _vertices:
		var world := aircraft * vertex
		if camera.is_position_behind(world) or camera.global_position.distance_to(world) < camera.near:
			return false
		points.append(camera.unproject_position(world))
	aperture = Geometry2D.convex_hull(points)
	if aperture.size() > 1 and aperture[0] == aperture[-1]:
		aperture.remove_at(aperture.size() - 1)
	# The coaming covers the bottom centre of this glass. Stay above its highest edge;
	# a 2D mask has no depth buffer with which to test cockpit occlusion.
	var bottom := -INF
	for point in aperture: bottom = maxf(bottom, point.y)
	for index in aperture.size():
		aperture[index].y = minf(aperture[index].y, bottom - COAMING_MARGIN * _scale)
	var inset := Geometry2D.offset_polygon(aperture, -FRAME_MARGIN * _scale)
	if not inset.is_empty(): aperture = inset[0]
	if _mask.polygon != aperture:
		_mask.polygon = aperture
	hud_min = Vector2(INF, INF)
	hud_max = Vector2(-INF, -INF)
	for p in aperture:
		hud_min.x = minf(hud_min.x, p.x)
		hud_min.y = minf(hud_min.y, p.y)
		hud_max.x = maxf(hud_max.x, p.x)
		hud_max.y = maxf(hud_max.y, p.y)
	hud_center = (hud_min + hud_max) * 0.5
	hud_size = hud_max - hud_min
	return true

func screen_pos(u: float, v: float) -> Vector2:
	return hud_min + Vector2(u * hud_size.x, v * hud_size.y)

func project_direction(direction: Vector3) -> Vector2:
	# Eye-relative direction projection removes translation, hence no head-motion parallax.
	return _project_local(_view * direction)

func _project_local(local: Vector3) -> Vector2:
	if local.z >= -0.00001: return Vector2(-100000.0, -100000.0)
	return _center + Vector2(local.x * _focal.x, -local.y * _focal.y) / -local.z

func at(yaw_deg: float, pitch_deg: float) -> Vector2:
	return _project_local(_view_aircraft * Vector3(tan(deg_to_rad(yaw_deg)),
		tan(deg_to_rad(pitch_deg)), -1.0))

func world_angle(yaw_deg: float, pitch_deg: float) -> Vector2:
	var yaw := deg_to_rad(yaw_deg)
	var pitch := deg_to_rad(pitch_deg)
	return project_direction((_forward * cos(yaw) + _right * sin(yaw))
		* cos(pitch) + Vector3.UP * sin(pitch))

func optical_scale() -> float:
	return _scale
