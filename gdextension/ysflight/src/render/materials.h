#ifndef YSGD_MATERIALS_H
#define YSGD_MATERIALS_H

#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>

namespace ysgd {

// Shared materials for everything converted from YS models and fields. Created once per session.
struct Materials {
    godot::Ref<godot::StandardMaterial3D> lit;    // shaded, opaque
    godot::Ref<godot::StandardMaterial3D> bright; // unshaded (YS "no shading" polygons: lights, markings)
    godot::Ref<godot::StandardMaterial3D> trans;  // shaded, alpha < 0.99 (canopies)
    // Cockpit (F1) variants with back-face culling, used on the player's own aircraft only. Kept for the
    // whole session: changing cull_mode on a material recompiles its shader (55-90 ms hitch).
    godot::Ref<godot::StandardMaterial3D> lit_cockpit;
    godot::Ref<godot::StandardMaterial3D> trans_cockpit;
    godot::Ref<godot::ShaderMaterial> terrain;
    godot::Ref<godot::StandardMaterial3D> point;
    // Coplanar field maps (PC2) and signboards (PLT): depth-biased per layer (UV.x = layer index, UV.y = 1 on
    // water polygons). Shaders in res://shaders/ (map_*.gdshader, terrain.gdshader).
    godot::Ref<godot::ShaderMaterial> map_poly;
    godot::Ref<godot::ShaderMaterial> map_line;
    godot::Ref<godot::ShaderMaterial> map_point;

    bool ready() const { return lit.is_valid(); }
    void init();
};

} // namespace ysgd

#endif // YSGD_MATERIALS_H
