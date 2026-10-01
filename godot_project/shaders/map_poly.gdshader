// Map polygons (render/scenery_builder.cpp; also the sea ring around the map): matte vertex colour with
// drifting cloud shadows, water shading on sea / lake polygons (UV.y = 1) and ground detail on land.
shader_type spatial;
render_mode cull_disabled, specular_disabled;

#include "res://shaders/map_layer.gdshaderinc"
#include "res://shaders/ground_fx.gdshaderinc"

void fragment() {
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 col = COLOR.rgb;
	vec3 glint = vec3(0.0);
	float px = length(fwidth(world.xz)); // metres per pixel (ground detail)
	if (water_shine_on > 0.5 && UV.y > 0.5) {
		water(col, glint, world, CAMERA_POSITION_WORLD, TIME);
	} else if (ground_detail_on > 0.5 && UV.y <= 0.5) {
		ground_detail(col, world, CAMERA_POSITION_WORLD, px);
	}
	float shade = cloud_shadows_on > 0.5 ? cloud_shade(world, TIME) : 1.0;
	ALBEDO = col * shade;
	EMISSION = glint * shade;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
