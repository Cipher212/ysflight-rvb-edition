extends WorldEnvironment

# Sky, lighting environment and distance haze.
# - Sky: shaders/sky.gdshader - the field's YS sky colour fading to a pale haze at the horizon, the sun disc
#   (follows the DirectionalLight3D), distant low-poly hills on the horizon.
# - Below the horizon the sky is the haze. A sea ring around the map (render/scenery_builder.cpp) continues the
#   map's dominant colour (island maps: the sea) past the draw distance and the depth fog fades it into that
#   same haze, so the map edge and the far clip melt into the horizon.
# - Ambient light: part flat grey, part from the sky (blue from above, a dim bounce of the ground colour from
#   below), so undersides and sides of models get their own tone instead of one flat grey (the "plastic toy"
#   look). The sky is static, so Godot renders its radiance once.
# - Sun-side haze: the fog takes the sunlight's warm colour when looking towards the sun.
# - Tone mapping and colour grade: world/color_grade.gd.

const HAZE_WHITENESS := 0.45       # horizon haze = sky colour blended this far towards white
const FOG_BEGIN_FRACTION := 0.15   # of the draw distance
const FOG_END_FRACTION := 0.95
const FOG_CURVE := 1.5             # > 1 keeps the middle distance clear
const FOG_SUN_SCATTER := 0.8       # haze towards the sun takes the (warm) sunlight colour (sky.gdshader matches)
const HILL_COLOR := Color(0.33, 0.45, 0.34) # distant land before the haze
const AMBIENT_GREY := Color(0.62, 0.62, 0.62)
const AMBIENT_SKY_SHARE := 0.6     # 0 = flat grey (old look), 1 = all from the sky
const AMBIENT_ENERGY := 1.0

const ColorGrade = preload("res://world/color_grade.gd")

var _env := Environment.new()

func setup(sim: YSFlightSimulation, draw_distance_m: float) -> void:
	name = "SkyEnvironment"
	var sky_top: Color = sim.get_sky_color()
	var haze: Color = sky_top.lerp(Color.WHITE, HAZE_WHITENESS)
	var haze_linear := haze.srgb_to_linear()
	RenderingServer.global_shader_parameter_set("sky_haze", Vector3(haze_linear.r, haze_linear.g, haze_linear.b)) # water sheen

	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/sky.gdshader")
	sky_mat.set_shader_parameter("sky_top", sky_top)
	sky_mat.set_shader_parameter("haze", haze)
	sky_mat.set_shader_parameter("ground", sim.get_map_base_color())
	sky_mat.set_shader_parameter("hills", HILL_COLOR)
	sky_mat.set_shader_parameter("sun_scatter", FOG_SUN_SCATTER)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32 # only feeds the ambient light

	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.ambient_light_color = AMBIENT_GREY
	_env.ambient_light_sky_contribution = AMBIENT_SKY_SHARE
	_env.ambient_light_energy = AMBIENT_ENERGY
	_env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED # no sky mirrored on the models (and cheaper)
	ColorGrade.apply(_env)
	_env.fog_enabled = true
	_env.fog_mode = Environment.FOG_MODE_DEPTH
	_env.fog_light_color = haze
	_env.fog_density = 1.0 # depth mode: full haze at fog_depth_end
	_env.fog_depth_curve = FOG_CURVE
	_env.fog_sky_affect = 0.0
	_env.fog_sun_scatter = FOG_SUN_SCATTER
	_env.fog_aerial_perspective = 0.0
	environment = _env
	set_draw_distance(draw_distance_m)

# Called when the draw distance (camera far plane) changes.
func set_draw_distance(draw_distance_m: float) -> void:
	_env.fog_depth_begin = draw_distance_m * FOG_BEGIN_FRACTION
	_env.fog_depth_end = draw_distance_m * FOG_END_FRACTION
