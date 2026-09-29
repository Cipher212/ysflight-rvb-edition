#ifndef YSGD_SHELL_MESH_H
#define YSGD_SHELL_MESH_H

#include <unordered_map>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include "render/materials.h"

class YsShellExt;

namespace ysgd {

// Converts YS shells (.srf, and every node of a .dnm) to Godot meshes: one surface each for shaded,
// unshaded and transparent polygons. Meshes are cached by shell address (models are shared by all
// aircraft of a type), so each YS shell is converted once per session.
class ShellMeshCache {
public:
    explicit ShellMeshCache(const Materials &materials) : mats(materials) {}

    godot::Ref<godot::ArrayMesh> get(const YsShellExt &shell);
    void clear() { cache.clear(); }
    size_t size() const { return cache.size(); }

private:
    const Materials &mats;
    std::unordered_map<const void *, godot::Ref<godot::ArrayMesh>> cache;
};

// Appends one triangle wound so that Godot's front face matches face_n. Godot treats clockwise triangles
// as front-facing; matching the winding keeps NORMAL from being flipped on CULL_DISABLED materials.
void add_oriented_triangle(godot::PackedVector3Array &verts, godot::PackedVector3Array &norms, godot::PackedColorArray &cols,
                           const godot::Vector3 &p0, const godot::Vector3 &p1, const godot::Vector3 &p2,
                           const godot::Vector3 &n0, const godot::Vector3 &n1, const godot::Vector3 &n2,
                           const godot::Vector3 &face_n,
                           const godot::Color &c0, const godot::Color &c1, const godot::Color &c2);

} // namespace ysgd

#endif // YSGD_SHELL_MESH_H
