extends WorldEnvironment

# Sky, lighting environment and distance haze.
# - Sky: shaders/sky.gdshader - the field's YS sky colour fading to a pale haze at the horizon, the sun disc
#   (follows the DirectionalLight3D).
# - Below the horizon the sky is the haze. A sea ring around the map (render/scenery_builder.cpp) continues the
#   map's dominant colour (island maps: the sea) past the draw distance and the depth fog fades it into that
#   same haze, so the map edge and the far clip melt into the horizon.
# - Ambient light: explicit AMBIENT_SOURCE_COLOR with tuned daylight ambient fill, keeping reflections disabled.
# - Sun-side haze: the fog takes the sunlight's warm colour when looking towards the sun.
# - Tone mapping and colour grade: world/color_grade.gd.

const HAZE_WHITENESS := 0.35       # horizon haze = sky colour blended this far towards white
const FOG_BEGIN_FRACTION := 0.15   # of the draw distance
const FOG_END_FRACTION := 0.95
const FOG_CURVE := 1.5             # > 1 keeps the middle distance clear
const FOG_SUN_SCATTER := 0.55      # haze towards the sun takes the (warm) sunlight colour (sky.gdshader matches)
const AMBIENT_COLOR_DAY := Color(0.52, 0.54, 0.56)
const AMBIENT_ENERGY_DAY := 0.65
const CLOUD_FOG_BEGIN := 2.0        # metres in front of camera inside cloud
const CLOUD_FOG_END := 35.0         # metres visibility ceiling inside cloud

const ColorGrade = preload("res://world/color_grade.gd")

var _env := Environment.new()
var _sky_mat: ShaderMaterial = null
var _base_haze := Color.WHITE
var _base_fog_begin := 0.0
var _base_fog_end := 80000.0
var _cloud_immersion := 0.0

func setup(sim: YSFlightSimulation, draw_distance_m: float) -> void:
	name = "SkyEnvironment"
	var sky_top: Color = sim.get_sky_color()
	var haze: Color = sky_top.lerp(Color.WHITE, HAZE_WHITENESS)
	_base_haze = haze
	var haze_linear := haze.srgb_to_linear()
	RenderingServer.global_shader_parameter_set("sky_haze", Vector3(haze_linear.r, haze_linear.g, haze_linear.b)) # water sheen

	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = preload("res://shaders/sky.gdshader")
	_sky_mat.set_shader_parameter("sky_top", sky_top)
	_sky_mat.set_shader_parameter("haze", haze)
	_sky_mat.set_shader_parameter("ground", sim.get_map_base_color())
	_sky_mat.set_shader_parameter("sun_scatter", FOG_SUN_SCATTER)
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32

	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = AMBIENT_COLOR_DAY
	_env.ambient_light_energy = AMBIENT_ENERGY_DAY
	_env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED # no sky mirrored on the models (and cheaper)
	ColorGrade.apply(_env)
	_env.fog_enabled = true
	_env.fog_mode = Environment.FOG_MODE_DEPTH
	_env.fog_density = 1.0 # depth mode: full haze at fog_depth_end
	_env.fog_sky_affect = 0.0
	_env.fog_sun_scatter = FOG_SUN_SCATTER
	_env.fog_aerial_perspective = 0.0
	environment = _env
	set_draw_distance(draw_distance_m)

# Composes base distance haze and temporary cloud immersion fog.
func _compose_fog() -> void:
	if _cloud_immersion <= 0.0:
		_env.fog_depth_begin = _base_fog_begin
		_env.fog_depth_end = _base_fog_end
		_env.fog_light_color = _base_haze
		_env.fog_depth_curve = FOG_CURVE
	else:
		var w: float = _cloud_immersion
		_env.fog_depth_begin = lerpf(_base_fog_begin, CLOUD_FOG_BEGIN, w)
		_env.fog_depth_end = lerpf(_base_fog_end, CLOUD_FOG_END, w)
		# Dim and tint cloud fog according to current scene atmosphere brightness
		var daylight: float = clampf((_base_haze.r + _base_haze.g + _base_haze.b) / 1.8, 0.1, 1.0)
		var cloud_color: Color = _base_haze.lerp(Color(0.90, 0.92, 0.95) * daylight, 0.6)
		_env.fog_light_color = _base_haze.lerp(cloud_color, w)
		_env.fog_depth_curve = lerpf(FOG_CURVE, 1.0, w)

# Called by DayCycle to coherently update atmosphere and ambient fill.
func apply_atmosphere(sky_top: Color, haze: Color, ambient_color: Color, ambient_energy: float) -> void:
	_base_haze = haze
	if _sky_mat != null:
		_sky_mat.set_shader_parameter("sky_top", sky_top)
		_sky_mat.set_shader_parameter("haze", haze)
	_compose_fog()
	_env.ambient_light_color = ambient_color
	_env.ambient_light_energy = ambient_energy

# Called when the draw distance (camera far plane) changes.
func set_draw_distance(draw_distance_m: float) -> void:
	_base_fog_begin = draw_distance_m * FOG_BEGIN_FRACTION
	_base_fog_end = draw_distance_m * FOG_END_FRACTION
	_compose_fog()

# Temporary cloud immersion weighting (0.0 = clear air, 1.0 = deep inside cloud).
func set_cloud_immersion(weight: float) -> void:
	var clamped: float = clampf(weight, 0.0, 1.0)
	if absf(_cloud_immersion - clamped) < 0.0005:
		return
	_cloud_immersion = clamped
	_compose_fog()

func get_cloud_immersion() -> float:
	return _cloud_immersion

