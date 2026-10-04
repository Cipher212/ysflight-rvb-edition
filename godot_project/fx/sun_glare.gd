extends MeshInstance3D

# Sun glare and faint PS2-style lens-flare ghosts when looking towards the sun (shaders/sun_glare.gdshader).
# A full-screen quad on the camera, only drawn while the sun is within VIEW_ANGLE_DEG of the view direction
# (otherwise hidden: no cost). The shader dims it when terrain or an aircraft covers the sun.

const VIEW_ANGLE_DEG := 70.0 # the shader fades the glare in from here
const FULL_ANGLE_DEG := 45.0

var enabled := true # Graphics setting "Sun & Explosion Glare"
var _camera: Camera3D = null
var _to_sun := Vector3.UP
var _cos_view := 0.0
var _sun_strength := 1.0
var _mat: ShaderMaterial = null

func setup(camera: Camera3D, sun: DirectionalLight3D) -> void:
	name = "SunGlare"
	_camera = camera
	_to_sun = (sun.global_basis.z if sun.is_inside_tree() else sun.basis.z).normalized() # the light shines along -Z
	_cos_view = cos(deg_to_rad(VIEW_ANGLE_DEG))
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mesh = quad
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://shaders/sun_glare.gdshader")
	_mat.set_shader_parameter("to_sun", _to_sun)
	_mat.set_shader_parameter("fade_from", _cos_view)
	_mat.set_shader_parameter("fade_full", cos(deg_to_rad(FULL_ANGLE_DEG)))
	_mat.set_shader_parameter("sun_strength", _sun_strength)
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	position = Vector3(0.0, 0.0, -1.0) # in front of the camera, so it is never culled
	camera.add_child(self)

func set_sun(to_sun_dir: Vector3, strength: float) -> void:
	_to_sun = to_sun_dir.normalized()
	_sun_strength = clampf(strength, 0.0, 1.0)
	if _mat != null:
		_mat.set_shader_parameter("to_sun", _to_sun)
		_mat.set_shader_parameter("sun_strength", _sun_strength)

func update() -> void:
	var on := enabled and _sun_strength > 0.01 and -_camera.global_basis.z.dot(_to_sun) > _cos_view
	if on != visible:
		visible = on
