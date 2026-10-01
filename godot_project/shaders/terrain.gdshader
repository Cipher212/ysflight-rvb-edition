// Field terrain (elevation grids, render/scenery_builder.cpp): matte sRGB vertex colour with drifting cloud
// shadows and ground detail (shaders/ground_fx.gdshaderinc), like the map polygons.
shader_type spatial;
render_mode cull_disabled, specular_disabled;

#include "res://shaders/ground_fx.gdshaderinc"

void vertex() {
	if (!OUTPUT_IS_SRGB) {
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)),
				COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
}

void fragment() {
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 col = COLOR.rgb;
	float px = length(fwidth(world.xz)); // metres per pixel (ground detail)
	if (ground_detail_on > 0.5) {
		ground_detail(col, world, CAMERA_POSITION_WORLD, px);
	}
	ALBEDO = col * (cloud_shadows_on > 0.5 ? cloud_shade(world, TIME) : 1.0);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
