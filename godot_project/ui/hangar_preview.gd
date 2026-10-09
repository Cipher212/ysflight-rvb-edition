extends SubViewportContainer

# Local presentation world. Animation stops completely when the hangar is hidden.
const Room := preload("res://ui/hangar_room.gd")
const ColorGrade := preload("res://world/color_grade.gd")
const DayCycle := preload("res://world/day_cycle.gd")
const DAYLIGHT: Dictionary = DayCycle.KEYFRAMES[2]
const FOV_DEG := 42.0
const ORBIT_SPEED := 0.008
const AUTO_ORBIT_SPEED_RAD := 0.10
const AUTO_ORBIT_STEP_S := 1.0 / 30.0
const FOCUS_DURATION_S := 0.85
const DEFAULT_YAW := -PI + 0.48
const DEFAULT_PITCH := 0.16
var viewport: SubViewport
var _world: Node3D
var _room: Node3D
var _model: Node3D
var _camera: Camera3D
var _points: Array = []
var _bounds := AABB()
var _target := Vector3.ZERO
var _yaw := DEFAULT_YAW
var _pitch := DEFAULT_PITCH
var _distance := 30.0
var _fit_distance := 30.0
var _ceiling := 15.0
var _active := false
var _height_offset := 0.0
var _auto_orbit := false
var _orbit_accumulator := 0.0
var _focus_tween: Tween

func _ready() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(false)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(viewport)
	_world = Node3D.new()
	viewport.add_child(_world)
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	var sky_material := ShaderMaterial.new()
	sky_material.shader = preload("res://shaders/sky.gdshader")
	sky_material.set_shader_parameter("sky_top", DAYLIGHT["sky_top"])
	sky_material.set_shader_parameter("haze", DAYLIGHT["haze"])
	sky_material.set_shader_parameter("ground", Color8(65, 103, 63))
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = DAYLIGHT["ambient_color"]
	env.ambient_light_energy = DAYLIGHT["ambient_energy"]
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	ColorGrade.apply(env)
	environment.environment = env
	_world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-32, 155, 0)
	sun.light_color = DAYLIGHT["sun_color"]
	sun.light_energy = DAYLIGHT["sun_energy"]
	sun.shadow_enabled = true
	_world.add_child(sun)
	_camera = Camera3D.new()
	_camera.fov = FOV_DEG
	_camera.near = 0.15
	_world.add_child(_camera)
	_camera.make_current()
	resized.connect(_resize_preview)
	gui_input.connect(_input_camera)

func set_active(active: bool) -> void:
	_active = active
	set_process(active and _auto_orbit)
	if _focus_tween != null and _focus_tween.is_valid():
		if active:
			_focus_tween.play()
		else:
			_focus_tween.pause()
	if viewport != null:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE if active else SubViewport.UPDATE_DISABLED

func show_aircraft(sim: YSFlightSimulation, identifier: String, fuel: float, slots: Array, points: Array, reset: bool) -> bool:
	var replacement: Node3D = sim.create_aircraft_preview(identifier, fuel, slots)
	if replacement == null:
		return false
	if _model != null:
		_world.remove_child(_model)
		_model.queue_free()
	_model = replacement
	_world.add_child(_model)
	_bounds = _model.get_meta("aircraft_bounds", AABB())
	_model.position.y = maxf(float(_model.get_meta("standing_height", 0.0)), -_bounds.position.y)
	_points = points
	if reset:
		if _room == null:
			_build_room()
		reset_camera()
	_update_camera()
	return true

func _build_room() -> void:
	_room = Room.new()
	_world.add_child(_room)
	_ceiling = _room.build()
	_camera.far = _room.get_meta("far_distance")

func reset_camera() -> void:
	_stop_focus()
	_yaw = DEFAULT_YAW
	_pitch = DEFAULT_PITCH
	_height_offset = 0.0
	_target = _model.to_global(_bounds.get_center()) if _model != null else Vector3.ZERO
	var aspect := maxf(size.x / maxf(size.y, 1.0), 0.25)
	# Fit the silhouette from every orbit angle without changing the parked aircraft pose.
	var radius := Vector2(_bounds.size.x, _bounds.size.z).length() * 0.5
	var half_height := _bounds.size.y * 0.5
	_fit_distance = maxf(radius / sin(atan(tan(deg_to_rad(FOV_DEG * 0.5)) * aspect)),
		(radius * sin(_pitch) + half_height * cos(_pitch)) / tan(deg_to_rad(FOV_DEG * 0.5)) + radius)
	_fit_distance = maxf(_fit_distance * 1.08, 5.0)
	_distance = _fit_distance
	_auto_orbit = true
	_orbit_accumulator = 0.0
	set_process(_active)
	_update_camera()

func focus_station(index: int) -> void:
	if _model == null or index < 0 or index >= _points.size():
		return
	_stop_presentation()
	var local_point: Vector3 = _points[index]["position"]
	var destination := _model.to_global(local_point)
	# Approach from the station's own side, slightly forward, to see under the wing.
	var side := signf(local_point.x)
	if is_zero_approx(side):
		side = -1.0
	var direction := _model.basis * Vector3(side * 0.86, 0.18, -0.50).normalized()
	var desired_yaw := atan2(direction.x, -direction.z)
	var distance := clampf(maxf(_bounds.size.x, _bounds.size.z) * 0.26, 3.5, _fit_distance * 0.65)
	_focus_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_focus_tween.tween_property(self, "_target", destination, FOCUS_DURATION_S)
	_focus_tween.tween_property(self, "_yaw", _yaw + angle_difference(_yaw, desired_yaw), FOCUS_DURATION_S)
	_focus_tween.tween_property(self, "_pitch", 0.18, FOCUS_DURATION_S)
	_focus_tween.tween_property(self, "_distance", distance, FOCUS_DURATION_S)
	_focus_tween.tween_property(self, "_height_offset", 0.0, FOCUS_DURATION_S)
	# A method track updates the camera throughout interpolation, including while Free Flight is paused.
	_focus_tween.tween_method(func(_value: float) -> void: _update_camera(), 0.0, 1.0, FOCUS_DURATION_S)
	_focus_tween.set_parallel(false).tween_callback(_update_camera)
	if not _active:
		_focus_tween.pause()

func _stop_focus() -> void:
	if _focus_tween != null and _focus_tween.is_valid():
		_focus_tween.kill()
	_focus_tween = null

func _stop_presentation() -> void:
	_stop_focus()
	_auto_orbit = false
	set_process(false)

func _process(delta: float) -> void:
	if _active and _auto_orbit and _model != null:
		_orbit_accumulator += delta
		if _orbit_accumulator < AUTO_ORBIT_STEP_S:
			return
		_yaw = wrapf(_yaw + _orbit_accumulator * AUTO_ORBIT_SPEED_RAD, -PI, PI)
		_orbit_accumulator = 0.0
		_update_camera()

func _resize_preview() -> void:
	if _model != null:
		reset_camera.call_deferred()

func _input_camera(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
			reset_camera()
			accept_event()
			return
		if event.button_index not in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			return
		_stop_presentation()
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(_distance * 0.9, _fit_distance * 0.12)
		else:
			_distance = minf(_distance * 1.1, _fit_distance * 1.5)
		accept_event()
		_update_camera()
	elif event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_MIDDLE or (event.shift_pressed and event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			_stop_presentation()
			_height_offset = clampf(_height_offset - event.relative.y * _distance * 0.002, -_ceiling, _ceiling)
		elif event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT):
			_stop_presentation()
			_yaw -= event.relative.x * ORBIT_SPEED
			_pitch = clampf(_pitch + event.relative.y * ORBIT_SPEED, -0.2, 1.1)
		else:
			return
		accept_event()
		_update_camera()

func _update_camera() -> void:
	if _camera == null or not _camera.is_inside_tree():
		return
	var target := _target + Vector3.UP * _height_offset
	target.y = clampf(target.y, 0.5, _ceiling - 0.5)
	var offset := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), -cos(_yaw) * cos(_pitch)) * _distance
	var camera_pos := target + offset
	camera_pos.y = clampf(camera_pos.y, 0.3, _ceiling - 0.3)
	if _room != null:
		var limits: AABB = _room.get_meta("camera_bounds")
		camera_pos = camera_pos.clamp(limits.position, limits.end)
	_camera.position = camera_pos
	_camera.look_at(target)
	if _active:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
