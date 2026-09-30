#ifndef YSGD_BURNER_MESH_H
#define YSGD_BURNER_MESH_H
// Afterburner flames: replaces the orange cones of DNM afterburner parts (class 2) with two crossed flame
// planes plus a disc on the nozzle facing aft, drawn by res://shaders/burner_flame.gdshader, and adds heat
// haze behind them (res://shaders/burner_haze.gdshader).
// The meshes go on the DNM part's own node, so YS still shows/hides them with the afterburner and they
// follow thrust vectoring; nothing extra runs per frame. Size and place come from the model's cone
// (each separate piece of it: twin burners are sometimes one mesh), so the author's flame length is kept.
// Vertex data for the shaders: UV = flame (across 0..1, nozzle 0 .. tip 1) or disc (0..1 square);
// UV2 = (part: 0 flame / 1 disc, flame length in metres). Flame axis = local +Z (aft).

#include <unordered_map>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/shader_material.hpp>

class YsShellExt;

namespace ysgd {

// Heat haze reads the screen, which makes Godot copy the frame whenever any haze is drawn: so it is only
// drawn near the camera, and not at Low effects (main.gd removes this layer from the camera's cull mask).
const int HEAT_HAZE_LAYER = 11;
const float HEAT_HAZE_RANGE_M = 300.0f;

class BurnerMeshCache {
public:
    struct Meshes {
        godot::Ref<godot::ArrayMesh> flame, haze; // null if the part isn't cone-shaped (keep YS's mesh)
    };
    // Cached by shell address, like ShellMeshCache.
    const Meshes &get(const YsShellExt &shell);
    const godot::Ref<godot::ShaderMaterial> &material(); // flame
    const godot::Ref<godot::ShaderMaterial> &haze_material();
    void clear() { cache.clear(); }

private:
    godot::Ref<godot::ShaderMaterial> flame_mat, haze_mat;
    std::unordered_map<const void *, Meshes> cache;
};

} // namespace ysgd

#endif // YSGD_BURNER_MESH_H
