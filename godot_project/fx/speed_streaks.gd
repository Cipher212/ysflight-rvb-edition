extends MultiMeshInstance3D

# Speed lines (fast flight) and mist (low over the sea/ground) streaking past the player's camera.
# One MultiMesh, one draw call: shaders/speed_streaks.gdshader places and moves every streak from its
# instance index and the distance flown, so per frame this only moves the node to the camera and sets a
# few uniforms. Hidden (no cost) when neither applies or the camera isn't riding with the player.

const COUNT := 64
const BOX_LEN := 120.0             # m of air the streaks cycle through (same as the shader's BOX_LEN)
const LINES_SPEED_START := 200.0   # m/s: speed lines fade in from here...
const LINES_SPEED_FULL := 350.0    # ...fully there here
const MIST_ALT_FULL := 60.0        # m above sea level: full mist below...
const MIST_ALT_END := 250.0        # ...none above
const MIST_SPEED_START := 120.0    # m/s
const MIST_SPEED_FULL := 200.0

var enabled := true # Graphics setting "Speed Lines & Mist"
var _mat := ShaderMaterial.new()
var _travel := 0.0
var _lines := -1.0
var _mist := -1.0

func setup() -> void:
	name = "SpeedStreaks"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _ribbon_mesh()
	mm.instance_count = COUNT
	for i in COUNT:
		mm.set_instance_transform(i, Transform3D.IDENTITY) # the shader places them
	mm.custom_aabb = AABB(Vector3.ONE * -BOX_LEN, Vector3.ONE * BOX_LEN * 2.0)
	multimesh = mm
	_mat.shader = preload("res://shaders/speed_streaks.gdshader")
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false

func update(delta: float, camera: Camera3D, at_player: bool, tel: Dictionary) -> void:
	var speed := float(tel.get("speed_ms", 0.0))
	var lines := smoothstep(LINES_SPEED_START, LINES_SPEED_FULL, speed)
	var mist := (1.0 - smoothstep(MIST_ALT_FULL, MIST_ALT_END, float(tel.get("agl_m", 1e4)))) \
		* smoothstep(MIST_SPEED_START, MIST_SPEED_FULL, speed)
	var on := enabled and at_player and bool(tel.get("is_alive", true)) and (lines > 0.01 or mist > 0.01)
	if on != visible:
		visible = on
	if not on:
		return
	var vel: Vector3 = tel.get("velocity", Vector3.ZERO)
	var fwd := vel.normalized() if vel.length_squared() > 1.0 else -camera.global_basis.z
	var up := Vector3.UP if absf(fwd.y) < 0.99 else Vector3.FORWARD
	global_transform = Transform3D(Basis.looking_at(fwd, up), camera.global_position)
	_travel = fmod(_travel + speed * delta, BOX_LEN)
	_mat.set_shader_parameter("travel", _travel)
	_mat.set_shader_parameter("speed", speed)
	if absf(lines - _lines) > 0.01 or absf(mist - _mist) > 0.01:
		_lines = lines
		_mist = mist
		_mat.set_shader_parameter("lines", lines)
		_mat.set_shader_parameter("mist", mist)

# A ribbon: x across (-0.5..0.5), z along (0 head .. 1 tail); the shader scales and turns it.
func _ribbon_mesh() -> ArrayMesh:
	var v := PackedVector3Array([Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 0, 1), Vector3(-0.5, 0, 1)])
	var uv := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
