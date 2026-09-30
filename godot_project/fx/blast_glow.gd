extends MeshInstance3D

# Screen glow of nearby explosions (shaders/blast_glow.gdshader): a soft bloom around each blast plus a brief
# brightening of the whole view for very close ones - no lights. A full-screen quad on the camera, drawn only
# while a flash is fading (hidden otherwise: no cost); the shader drops a bloom when terrain covers the blast.
# Fed by fx/explosion_fx.gd.

const MAX_BLASTS := 4       # the shader takes them as the columns of a mat4
const LIFE_S := 0.35
const RANGE_M := 2500.0     # further blasts only get their 3D flash

var enabled := true # Graphics setting "Sun & Explosion Glare"
var _camera: Camera3D = null
var _mat := ShaderMaterial.new()
var _blasts := PackedVector4Array() # xyz position, w size (m)
var _age := PackedFloat32Array()
var _strength := PackedFloat32Array()

func setup(camera: Camera3D) -> void:
	name = "BlastGlow"
	_camera = camera
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mesh = quad
	_mat.shader = preload("res://shaders/blast_glow.gdshader")
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	position = Vector3(0.0, 0.0, -1.0) # in front of the camera, so it is never culled
	_blasts.resize(MAX_BLASTS)
	_age.resize(MAX_BLASTS)
	_age.fill(LIFE_S)
	_strength.resize(MAX_BLASTS)
	visible = false
	camera.add_child(self)

func add(pos: Vector3, size: float) -> void:
	if not enabled or _camera.global_position.distance_to(pos) > RANGE_M:
		return
	var slot := 0
	for i in MAX_BLASTS: # the oldest slot
		if _age[i] > _age[slot]:
			slot = i
	_blasts[slot] = Vector4(pos.x, pos.y, pos.z, size)
	_age[slot] = 0.0
	visible = true

func update(delta: float) -> void:
	if not visible:
		return
	var any := false
	for i in MAX_BLASTS:
		_age[i] += delta
		var k := clampf(1.0 - _age[i] / LIFE_S, 0.0, 1.0)
		_strength[i] = k * k
		any = any or k > 0.0
	if not any:
		visible = false
		return
	_mat.set_shader_parameter("blasts", Projection(_blasts[0], _blasts[1], _blasts[2], _blasts[3]))
	_mat.set_shader_parameter("strength", Vector4(_strength[0], _strength[1], _strength[2], _strength[3]))
