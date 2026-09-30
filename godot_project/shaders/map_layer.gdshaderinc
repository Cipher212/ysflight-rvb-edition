// Vertex stage shared by the map layer shaders (map_poly / map_line / map_point, render/materials.cpp).
// Map layers stay at their true height (aircraft wheels never sink); UV.x carries the signed layer index
// (-N .. -1), which pushes the vertex away from the camera in view space, earlier layers further, so later
// layers (runways over grass) win without z-fighting, and 3D objects at y = 0 win over every layer.
// Vertex colours are sRGB. Define MAP_POINTS before including for point primitives.
void vertex() {
	if (!OUTPUT_IS_SRGB) {
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)),
				COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
#ifdef MAP_POINTS
	POINT_SIZE = 4.0;
#endif
	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view_pos.xyz *= (1.0 - UV.x * 0.000015);
	POSITION = PROJECTION_MATRIX * view_pos;
}
