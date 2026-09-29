#include "render/materials.h"

#include <godot_cpp/classes/shader.hpp>

using namespace godot;

namespace ysgd {

static Ref<StandardMaterial3D> vertex_color_material(BaseMaterial3D::CullMode cull, BaseMaterial3D::ShadingMode shading) {
    Ref<StandardMaterial3D> m;
    m.instantiate();
    m->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    m->set_flag(BaseMaterial3D::FLAG_SRGB_VERTEX_COLOR, true);
    m->set_cull_mode(cull);
    m->set_shading_mode(shading);
    return m;
}

// Map layers stay at their true height (aircraft wheels never sink); UV.x carries the signed layer index,
// which pulls the vertex towards the camera in view space so later layers win without z-fighting.
static const char *MAP_VERTEX_CODE =
    "void vertex() {\n"
    "    if (!OUTPUT_IS_SRGB) {\n"
    "        COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)),\n"
    "                        COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));\n"
    "    }\n"
    "    %POINT%"
    "    vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);\n"
    "    view_pos.xyz *= (1.0 - UV.x * 0.000015);\n"
    "    POSITION = PROJECTION_MATRIX * view_pos;\n"
    "}\n";

static Ref<ShaderMaterial> map_material(const String &render_mode, bool points, const String &fragment) {
    Ref<Shader> shader;
    shader.instantiate();
    const String vertex = String(MAP_VERTEX_CODE).replace("%POINT%", points ? "POINT_SIZE = 4.0;\n" : "");
    shader->set_code("shader_type spatial;\nrender_mode " + render_mode + ";\n" + vertex + fragment);
    Ref<ShaderMaterial> m;
    m.instantiate();
    m->set_shader(shader);
    return m;
}

void Materials::init() {
    if (ready()) {
        return;
    }
    lit = vertex_color_material(BaseMaterial3D::CULL_DISABLED, BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    lit->set_roughness(0.55f);
    lit->set_specular(0.35f);

    bright = vertex_color_material(BaseMaterial3D::CULL_DISABLED, BaseMaterial3D::SHADING_MODE_UNSHADED);

    trans = vertex_color_material(BaseMaterial3D::CULL_DISABLED, BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    trans->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
    trans->set_roughness(0.2f);
    trans->set_specular(0.6f);

    lit_cockpit = vertex_color_material(BaseMaterial3D::CULL_BACK, BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    lit_cockpit->set_roughness(0.55f);
    lit_cockpit->set_specular(0.35f);

    trans_cockpit = vertex_color_material(BaseMaterial3D::CULL_BACK, BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    trans_cockpit->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
    trans_cockpit->set_roughness(0.2f);
    trans_cockpit->set_specular(0.6f);

    terrain = vertex_color_material(BaseMaterial3D::CULL_DISABLED, BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    terrain->set_roughness(1.0f);
    terrain->set_specular_mode(BaseMaterial3D::SPECULAR_DISABLED);

    point = vertex_color_material(BaseMaterial3D::CULL_DISABLED, BaseMaterial3D::SHADING_MODE_UNSHADED);
    point->set_flag(BaseMaterial3D::FLAG_USE_POINT_SIZE, true);
    point->set_point_size(4.0f);

    map_poly = map_material("cull_disabled, specular_disabled", false,
                            "void fragment() {\n    ALBEDO = COLOR.rgb;\n    ROUGHNESS = 1.0;\n    SPECULAR = 0.0;\n}\n");
    map_line = map_material("unshaded, cull_disabled", false, "void fragment() {\n    ALBEDO = COLOR.rgb;\n}\n");
    map_point = map_material("unshaded, cull_disabled", true, "void fragment() {\n    ALBEDO = COLOR.rgb;\n}\n");
}

} // namespace ysgd
