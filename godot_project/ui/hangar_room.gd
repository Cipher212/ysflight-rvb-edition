extends Node3D

# Scenery baked from the owner's SRFs and Luavi TER data; shared meshes, local presentation only.
const BIG_HANGAR: ArrayMesh = preload("res://ui/hangar_assets/big_hangar.res")
const ALERT_SHEDS: ArrayMesh = preload("res://ui/hangar_assets/alert_sheds.res")
const FUEL_EQUIPMENT: ArrayMesh = preload("res://ui/hangar_assets/fuel_equipment.res")
const LUAVI_HILLS: ArrayMesh = preload("res://ui/hangar_assets/luavi_hills.res")
const GRASS := Color8(65, 103, 63)
const CONCRETE := Color8(121, 123, 134)
const ASPHALT := Color8(81, 83, 89)
const SEA := Color8(75, 107, 126)
const TAXI_YELLOW := Color8(186, 167, 88)
const CEILING_HEIGHT := 20.0
const DOOR_Z := -39.5 # SRF +Z doorway becomes Godot -Z, matching aircraft forward.
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()

func build() -> float:
	name = "LuaviHangar"
	# Aircraft and scenery keep their real dimensions; only the camera adapts to aircraft size.
	set_meta("camera_bounds", AABB(Vector3(-45, 0.3, -37), Vector3(90, 19.4, 74)))
	set_meta("door_forward", Vector3.FORWARD)
	set_meta("far_distance", 18000.0)
	_instance(BIG_HANGAR, "BigHangar", Vector3.ZERO)
	_instance(FUEL_EQUIPMENT, "FuelEquipment", Vector3(-29, 0.02, 26))
	_box(Vector3(97, 0.20, 81), Vector3(0, -0.12, 0), CONCRETE)
	for i in range(-4, 5):
		_stripe(Vector3(-48, 0.008, i * 10),
			Vector3(48, 0.008, i * 10), 0.025, Color8(85, 88, 95))
	for side in [-1.0, 1.0]:
		_stripe(Vector3(side * 17, 0.018, 27),
			Vector3(side * 17, 0.018, -30), 0.15, TAXI_YELLOW)
		for i in 8:
			_stripe(Vector3(side * 35, 0.025, -32 - i),
				Vector3(side * 37, 0.025, -33 - i), 0.15, TAXI_YELLOW)
	_stripe(Vector3(0, 0.02, 34), Vector3(0, 0.02, -165), 0.18, TAXI_YELLOW)
	_build_airfield()
	_flush()
	for side in [-1.0, 1.0]:
		var fill := OmniLight3D.new()
		fill.position = Vector3(side * 18, 12, 0)
		fill.light_color = Color("e6edf3")
		fill.light_energy = 0.55
		fill.omni_range = 110
		fill.shadow_enabled = false
		add_child(fill)
	return CEILING_HEIGHT

func _build_airfield() -> void:
	_box(Vector3(25000, 0.2, 25000), Vector3(0, -0.30, -7000), GRASS)
	_box(Vector3(500, 0.1, 240), Vector3(0, -0.07, DOOR_Z - 120), CONCRETE)
	var runway_z := DOOR_Z - 450
	_box(Vector3(2000, 0.10, 45), Vector3(0, -0.02, runway_z), ASPHALT)
	for side in [-1.0, 1.0]:
		_stripe(Vector3(-1000, 0.04, runway_z + side * 21),
			Vector3(1000, 0.04, runway_z + side * 21), 0.18, Color8(230, 230, 230))
	for i in range(-15, 16):
		_stripe(Vector3(i * 65, 0.04, runway_z),
			Vector3(i * 65 + 30, 0.04, runway_z), 0.4, Color8(230, 230, 230))
	var curve := PackedVector3Array([Vector3(0, 0.025, -165), Vector3(5, 0.025, -180),
		Vector3(20, 0.025, -190), Vector3(40, 0.025, -190), Vector3(55, 0.025, -205),
		Vector3(55, 0.06, runway_z)])
	for i in curve.size() - 1:
		_stripe(curve[i], curve[i + 1], 0.18, TAXI_YELLOW)
	# The source is a connected row of alert bays. Keep a clear taxi corridor between the rows.
	_instance(ALERT_SHEDS, "AlertShedsLeft", Vector3(-120, 0, -220), 1.0, PI)
	_instance(ALERT_SHEDS, "AlertShedsRight", Vector3(120, 0, -220), 1.0, PI)
	_instance(ALERT_SHEDS, "AlertShedsFar", Vector3(-360, 0, -650), 1.0, PI * 0.5)
	# The coastline and actual Luavi grid replace the synthetic triangular mountain backdrop.
	_box(Vector3(25000, 0.03, 16000), Vector3(0, -0.08, -9700), SEA)
	_instance(LUAVI_HILLS, "LuaviRidge", Vector3(1200, 0, -6500), 0.32)
	_instance(LUAVI_HILLS, "LuaviRidgeLeft", Vector3(-6500, 0, -7200), 0.35, -0.4)
	_instance(LUAVI_HILLS, "LuaviRidgeRight", Vector3(7500, 0, -7500), 0.28, 0.5)

func _instance(mesh: ArrayMesh, label: String, position: Vector3, uniform_scale: float = 1.0, yaw: float = 0.0) -> void:
	var instance := MeshInstance3D.new()
	instance.name = label
	instance.mesh = mesh
	instance.position = position
	instance.rotation.y = yaw
	instance.scale = Vector3.ONE * uniform_scale
	add_child(instance)

func _stripe(a: Vector3, b: Vector3, width: float, color: Color) -> void:
	var direction := b - a
	_box(Vector3(width, 0.008, direction.length()), (a + b) * 0.5, color, Basis(Vector3.UP, atan2(direction.x, direction.z)))

func _box(dimensions: Vector3, center: Vector3, color: Color, basis: Basis = Basis.IDENTITY) -> void:
	var box := BoxMesh.new()
	box.size = dimensions
	var arrays := box.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var offset := _vertices.size()
	for i in vertices.size():
		_vertices.append(basis * vertices[i] + center)
		_normals.append(basis * normals[i])
		_colors.append(color)
	for index in indices:
		_indices.append(offset + index)

func _flush() -> void:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertices
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_INDEX] = _indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mesh.surface_set_material(0, material)
	var instance := MeshInstance3D.new()
	instance.name = "HangarAndAirfield"
	instance.mesh = mesh
	add_child(instance)
	_vertices.clear()
	_normals.clear()
	_colors.clear()
	_indices.clear()
