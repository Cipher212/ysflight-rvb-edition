// Map lines (render/scenery_builder.cpp): unshaded vertex colour, layered like the map polygons.
shader_type spatial;
render_mode unshaded, cull_disabled;

#include "res://shaders/map_layer.gdshaderinc"

void fragment() {
	ALBEDO = COLOR.rgb;
}
