extends Node3D

const PuffSystem := preload("res://fx/puff_system.gd")
const FIRE_SHADER := preload("res://shaders/fire_puff.gdshader")

# Shot-down aircraft (spinning down, YS FSDEADSPIN/FLATSPIN) burn PS2 / Ace Combat style: a short additive
# fire puff every 0.08-0.1 s at the burning point (the aircraft's DAT SMOKEGEN), and dark smoke puffs just
# behind it that grow and grey out. Fire quads have their own ring of MAX_FIRE_QUADS (never more alive at
# once in the whole game); smoke uses the shared puff pool. Input: "aircraft" of get_aircraft_fx_state().

const STRIDE := 21              # get_aircraft_fx_state() aircraft row (see aircraft_fx_query.h)
const COL_STATE := 8            # 1 = dying
const COL_FORWARD := 14
const COL_SMOKE_POINT := 18
const MAX_FIRE_QUADS := 32
const FIRE_INTERVAL := Vector2(0.08, 0.1) # s, random in this range
const FIRE_LIFE := 0.3
const FIRE_SIZE := Vector2(2.5, 5.0)      # m, start -> end
const SMOKE_INTERVAL := 0.1               # s (doubled on low effects quality)
const SMOKE_LIFE := Vector2(6.0, 8.0)
const SMOKE_SIZE := Vector2(4.0, 25.0)
const SMOKE_COLOR := Color(0.07, 0.07, 0.07, 0.9) # charcoal; greys out as it ages
const SMOKE_GREY_OUT := 0.8
const SMOKE_BEHIND_M := 3.0

var puffs: PuffSystem = null
var quality: int = 1
var fire_spawned: int = 0
var smoke_spawned: int = 0

var _fire_mm := MultiMesh.new()
var _fire_mat := ShaderMaterial.new()
var _fire_head: int = 0
var _time: float = 0.0
var _timers: Dictionary = {} # aircraft key -> PackedFloat32Array [time to next fire, time to next smoke]
var _rng := RandomNumberGenerator.new()

func setup(p_puffs: PuffSystem) -> void:
	puffs = p_puffs

func _ready() -> void:
	name = "DeathFX"
	_rng.randomize()
	_fire_mat.shader = FIRE_SHADER
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = _fire_mat
	_fire_mm.transform_format = MultiMesh.TRANSFORM_3D
	_fire_mm.mesh = quad
	_fire_mm.instance_count = MAX_FIRE_QUADS
	var dead := Transform3D(Basis(Vector3.ZERO, Vector3(0.0, 0.0, 0.1), Vector3(-1000.0, 0.0, 0.0)), Vector3.ZERO)
	for i in MAX_FIRE_QUADS:
		_fire_mm.set_instance_transform(i, dead)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _fire_mm
	mmi.custom_aabb = AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

func update(delta: float, aircraft: PackedFloat32Array) -> void:
	_time += delta
	_fire_mat.set_shader_parameter("now", _time)
	var seen := {}
	for i in range(0, aircraft.size(), STRIDE):
		if aircraft[i + COL_STATE] < 0.5:
			continue
		var key := int(aircraft[i])
		seen[key] = true
		var root := Vector3(aircraft[i + COL_SMOKE_POINT], aircraft[i + COL_SMOKE_POINT + 1], aircraft[i + COL_SMOKE_POINT + 2])
		var fwd := Vector3(aircraft[i + COL_FORWARD], aircraft[i + COL_FORWARD + 1], aircraft[i + COL_FORWARD + 2])
		var t: PackedFloat32Array = _timers.get(key, PackedFloat32Array([0.0, 0.0]))
		t[0] -= delta
		if t[0] <= 0.0:
			_spawn_fire(root)
			t[0] = _rng.randf_range(FIRE_INTERVAL.x, FIRE_INTERVAL.y)
		t[1] -= delta
		if t[1] <= 0.0:
			puffs.spawn(root - fwd * SMOKE_BEHIND_M, Vector3(0.0, 1.0, 0.0), SMOKE_SIZE.x, SMOKE_SIZE.y,
				_rng.randf_range(SMOKE_LIFE.x, SMOKE_LIFE.y), SMOKE_COLOR, 0.0, SMOKE_GREY_OUT)
			smoke_spawned += 1
			t[1] = SMOKE_INTERVAL * (2.0 if quality <= 0 else 1.0)
		_timers[key] = t
	for key in _timers.keys():
		if not seen.has(key):
			_timers.erase(key)

# MODEL_MATRIX packing: see shaders/fire_puff.gdshader
func _spawn_fire(pos: Vector3) -> void:
	_fire_mm.set_instance_transform(_fire_head, Transform3D(Basis(Vector3.ZERO, Vector3(FIRE_SIZE.x, FIRE_SIZE.y, FIRE_LIFE), Vector3(_time, 0.0, 0.0)), pos))
	_fire_head = (_fire_head + 1) % MAX_FIRE_QUADS
	fire_spawned += 1
