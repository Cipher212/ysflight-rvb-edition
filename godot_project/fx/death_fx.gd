extends Node3D

const FIRE_SHADER := preload("res://shaders/fire_core.gdshader")
const SHARD_SHADER := preload("res://shaders/debris_shard.gdshader")

# Shot-down aircraft (spinning down, YS FSDEADSPIN/FLATSPIN): a flickering fireball over the airframe (one quad
# per burning jet, placed at its origin every frame) and, once at the kill, a burst of flat charred shards that
# tumble and fall (GPU-aged ring, nothing done per shard afterwards). The smoke plume is a continuous ribbon from
# the smoke point, drawn by the C++ trail renderer (render/trail_renderer.cpp, STYLE_DEATH).
# Input: "aircraft" of get_aircraft_fx_state().

const STRIDE := 21              # get_aircraft_fx_state() aircraft row (see aircraft_fx_query.h)
const COL_POS := 1
const COL_VEL := 4
const COL_STATE := 8            # 1 = dying
const COL_RADIUS := 13
const MAX_FIRES := 32
const UNUSED_FIRE := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO) # radius 0: no pixels
const MAX_SHARDS := 128
const SHARDS := Vector2i(4, 8)          # per kill (low effects quality: the minimum)
const SHARD_SIZE := Vector2(0.8, 2.2)   # m
const SHARD_KICK := Vector2(12.0, 35.0) # m/s away from the aircraft, on top of its velocity
const SHARD_SPIN := Vector2(4.0, 14.0)  # rad/s
const SHARD_LIFE := Vector2(3.5, 5.5)   # s
const SHARD_SHADE := Vector2(0.015, 0.09)

var quality: int = 1
var fires_burning: int = 0   # fireballs drawn this frame
var fires_started: int = 0   # aircraft set on fire so far (tests)
var shards_spawned: int = 0

var _fire_mm := MultiMesh.new()
var _shard_mm := MultiMesh.new()
var _shard_mat := ShaderMaterial.new()
var _shard_mmi: MultiMeshInstance3D = null # at -render_origin: shards are absolute (fx/puff_system.gd)
var _shard_head: int = 0
var _time: float = 0.0
var _burning: Dictionary = {} # aircraft key -> fireball seed
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	name = "DeathFX"
	_rng.randomize()
	var fire_mat := ShaderMaterial.new()
	fire_mat.shader = FIRE_SHADER
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = fire_mat
	_fire_mm.transform_format = MultiMesh.TRANSFORM_3D
	_fire_mm.mesh = quad
	_fire_mm.instance_count = MAX_FIRES
	for i in MAX_FIRES: # always drawn (collapsed when unused): the shader is compiled at load, not at the first kill
		_fire_mm.set_instance_transform(i, UNUSED_FIRE)
	_add_instance_node("Fireballs", _fire_mm)

	_shard_mat.shader = SHARD_SHADER
	_shard_mm.transform_format = MultiMesh.TRANSFORM_3D
	_shard_mm.use_colors = true
	_shard_mm.mesh = _shard_mesh()
	_shard_mm.instance_count = MAX_SHARDS
	var dead := Transform3D(Basis(Vector3.ZERO, Vector3(1.0, 0.1, -1000.0), Vector3.ZERO), Vector3.ZERO)
	for i in MAX_SHARDS:
		_shard_mm.set_instance_transform(i, dead)
	_shard_mmi = _add_instance_node("Shards", _shard_mm)

# At setup and whenever the render origin moves (main.gd).
func set_render_origin(origin: Vector3) -> void:
	_shard_mmi.position = -origin

func update(delta: float, aircraft: PackedFloat32Array) -> void:
	_time += delta
	_shard_mat.set_shader_parameter("now", _time)
	var n := 0
	var seen := {}
	for i in range(0, aircraft.size(), STRIDE):
		if aircraft[i + COL_STATE] < 0.5:
			continue
		var key := int(aircraft[i])
		seen[key] = true
		var pos := Vector3(aircraft[i + COL_POS], aircraft[i + COL_POS + 1], aircraft[i + COL_POS + 2])
		if not _burning.has(key):
			_burning[key] = _rng.randf_range(0.0, 100.0)
			fires_started += 1
			var vel := Vector3(aircraft[i + COL_VEL], aircraft[i + COL_VEL + 1], aircraft[i + COL_VEL + 2])
			_spawn_shards(pos, vel)
		if n < MAX_FIRES:
			# MODEL_MATRIX packing: see shaders/fire_core.gdshader
			var info := Vector3(aircraft[i + COL_RADIUS], _burning[key], 0.0)
			_fire_mm.set_instance_transform(n, Transform3D(Basis(info, Vector3.ZERO, Vector3.ZERO), pos))
			n += 1
	for i in range(n, fires_burning):
		_fire_mm.set_instance_transform(i, UNUSED_FIRE)
	fires_burning = n
	for key in _burning.keys():
		if not seen.has(key):
			_burning.erase(key)

# MODEL_MATRIX packing: see shaders/debris_shard.gdshader
func _spawn_shards(pos: Vector3, vel: Vector3) -> void:
	var count: int = SHARDS.x if quality <= 0 else _rng.randi_range(SHARDS.x, SHARDS.y)
	for k in count:
		var dir := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.5, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
		var axis := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
		var data := Vector3(_rng.randf_range(SHARD_SIZE.x, SHARD_SIZE.y), _rng.randf_range(SHARD_LIFE.x, SHARD_LIFE.y), _time)
		var v0 := vel + dir * _rng.randf_range(SHARD_KICK.x, SHARD_KICK.y)
		var spin := axis * _rng.randf_range(SHARD_SPIN.x, SHARD_SPIN.y)
		_shard_mm.set_instance_transform(_shard_head, Transform3D(Basis(v0, data, spin), pos + dir * 2.0 - _shard_mmi.position))
		var shade := _rng.randf_range(SHARD_SHADE.x, SHARD_SHADE.y)
		_shard_mm.set_instance_color(_shard_head, Color(shade, shade, shade * 0.95))
		_shard_head = (_shard_head + 1) % MAX_SHARDS
		shards_spawned += 1

# One irregular flat triangle (scaled per shard in the shader).
func _shard_mesh() -> ArrayMesh:
	var verts := PackedVector3Array([Vector3(-0.5, -0.35, 0.0), Vector3(0.55, -0.2, 0.0), Vector3(-0.1, 0.6, 0.0)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _shard_mat)
	return mesh

func _add_instance_node(node_name: String, mm: MultiMesh) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.custom_aabb = AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi
