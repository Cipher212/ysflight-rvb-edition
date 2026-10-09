extends Node3D

# Smoke puffs for explosions and crash plumes: one MultiMesh ring buffer aged on the GPU
# (shaders/smoke_puff.gdshader). spawn() writes one instance and nothing is done per puff afterwards; the
# oldest puff is overwritten when the pool is full. Trails (missiles, damage, death smoke) are not puffs:
# they are ribbons drawn by the C++ trail renderer.
# Positions in are render space (relative to the floating render origin); the MultiMeshInstance3D sits at
# -render_origin, so the puffs are stored in absolute coordinates and nothing moves when the origin shifts.

const SHADER := preload("res://shaders/smoke_puff.gdshader")
const POOL_SIZE := [256, 512, 1024] # by effects quality (low, medium, high)

var spawned: int = 0

var _mm: MultiMesh = null
var _mmi: MultiMeshInstance3D = null
var _material: ShaderMaterial = null
var _head: int = 0
var _time: float = 0.0
var _rng := RandomNumberGenerator.new()

func _init() -> void:
	name = "Puffs"
	_rng.randomize()
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = _material
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	_mm.mesh = quad
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.custom_aabb = AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7))
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mmi)
	set_quality(1)

# At setup and whenever the render origin moves (main.gd).
func set_render_origin(origin: Vector3) -> void:
	_mmi.position = -origin

# Resizes the pool (existing puffs are dropped).
func set_quality(quality: int) -> void:
	var count: int = POOL_SIZE[clampi(quality, 0, 2)]
	if _mm.instance_count == count:
		return
	_mm.instance_count = count
	var dead := Transform3D(Basis(Vector3.ZERO, Vector3(0.0, 0.0, 0.1), Vector3(-1000.0, 0.0, 0.0)), Vector3.ZERO)
	for i in count:
		_mm.set_instance_transform(i, dead)
		_mm.set_instance_color(i, Color(0.0, 0.0, 0.0, 0.0))
		_mm.set_instance_custom_data(i, Color(0.0, 0.0, 0.0, 0.0))
	_mm.visible_instance_count = count
	_head = 0

func advance(delta: float) -> void:
	_time += delta
	_material.set_shader_parameter("now", _time)

func random() -> RandomNumberGenerator:
	return _rng

# vel: start velocity (horizontal part slows down). heat > 0 adds a fire glow that cools in the first third.
# grey_out 0..1: how far the colour drifts towards light grey by the end of the puff's life.
func spawn(pos: Vector3, vel: Vector3, size0: float, size1: float, life: float, color: Color, heat: float = 0.0, grey_out: float = 0.0) -> void:
	var slot := _head
	_head = (_head + 1) % _mm.instance_count
	spawned += 1
	_mm.set_instance_transform(slot, Transform3D(Basis(vel, Vector3(size0, size1, maxf(life, 0.1)), Vector3(_time, 0.0, 0.0)), pos - _mmi.position))
	_mm.set_instance_color(slot, color)
	_mm.set_instance_custom_data(slot, Color(heat, grey_out, 0.0, 0.0))
