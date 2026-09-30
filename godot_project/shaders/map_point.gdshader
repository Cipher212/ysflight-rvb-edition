// Map points (render/scenery_builder.cpp): unshaded vertex colour, 4 px, layered like the map polygons.
shader_type spatial;
render_mode unshaded, cull_disabled;

#define MAP_POINTS
#include "res://shaders/map_layer.gdshaderinc"

void fragment() {
	ALBEDO = COLOR.rgb;
}
