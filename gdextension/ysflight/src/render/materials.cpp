#include "render/materials.h"

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/texture2d.hpp>

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

// Faint sunlit edge on models so they stand out from the terrain without looking glossy (a few ALU per
// pixel, no extra pass). Godot's rim sharpness comes from roughness: (1 - roughness) * 16 = 4.8 here; with
// specular disabled the roughness has no other visible effect.
static void add_rim(const Ref<StandardMaterial3D> &m) {
    m->set_roughness(0.7f);
    m->set_feature(BaseMaterial3D::FEATURE_RIM, true);
    m->set_rim(0.3f);
    m->set_rim_tint(0.5f);
}

static Ref<ShaderMaterial> shader_material(const char *path) {
    Ref<ShaderMaterial> m;
    m.instantiate();
    m->set_shader(ResourceLoader::get_singleton()->load(path));
    return m;
}

void Materials::init() {
    if (ready()) {
        return;
    }
    // Aircraft and objects: matte (no specular highlight). Shiny paint made the YS models look like plastic
    // toys; skipping specular is also the cheapest shading. Sky reflections are off in the Environment.
    lit = vertex_color_material(BaseMaterial3D::CULL_DISABLED, BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    lit->set_specular_mode(BaseMaterial3D::SPECULAR_DISABLED);
    add_rim(lit);

    bright = vertex_color_material(BaseMaterial3D::CULL_DISABLED, BaseMaterial3D::SHADING_MODE_UNSHADED);

    trans = vertex_color_material(BaseMaterial3D::CULL_DISABLED, BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    trans->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
    trans->set_roughness(0.2f);
    trans->set_specular(0.6f);

    lit_cockpit = vertex_color_material(BaseMaterial3D::CULL_BACK, BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    lit_cockpit->set_specular_mode(BaseMaterial3D::SPECULAR_DISABLED);
    add_rim(lit_cockpit);

    trans_cockpit = vertex_color_material(BaseMaterial3D::CULL_BACK, BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    trans_cockpit->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
    trans_cockpit->set_roughness(0.2f);
    trans_cockpit->set_specular(0.6f);

    terrain = shader_material("res://shaders/terrain.gdshader"); // matte + cloud shadows

    point = vertex_color_material(BaseMaterial3D::CULL_DISABLED, BaseMaterial3D::SHADING_MODE_UNSHADED);
    point->set_flag(BaseMaterial3D::FLAG_USE_POINT_SIZE, true);
    point->set_point_size(4.0f);

    map_poly = shader_material("res://shaders/map_poly.gdshader"); // + cloud shadows, water on sea polygons
    map_line = shader_material("res://shaders/map_line.gdshader");
    map_point = shader_material("res://shaders/map_point.gdshader");
    // Cloud shadows (shaders/ground_fx.gdshaderinc): one tiling noise texture, generated at load.
    const Ref<Texture2D> clouds = ResourceLoader::get_singleton()->load("res://shaders/cloud_noise.tres");
    map_poly->set_shader_parameter("cloud_noise", clouds);
    terrain->set_shader_parameter("cloud_noise", clouds);
}

} // namespace ysgd
