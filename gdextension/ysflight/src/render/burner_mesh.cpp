#include "render/burner_mesh.h"

#include <algorithm>
#include <vector>

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include "core/crashlog.h"
#include "core/ys_convert.h"
#include "core/ys_headers.h"

using namespace godot;

namespace ysgd {

namespace {

const char *FLAME_SHADER = "res://shaders/burner_flame.gdshader";
const char *HAZE_SHADER = "res://shaders/burner_haze.gdshader";
const float HAZE_START = 0.5;         // of the flame's length
const float HAZE_LENGTH = 4.0;        // x the model's cone length, from the nozzle
const float HAZE_WIDTH_START = 1.0;   // x the flame planes' width
const float HAZE_WIDTH_END = 2.2;
// Flame vs the model's cone (user, 2026-09-30: 1.1x as wide, 1.5x as long). The planes are wider than the
// flame itself: the shader's soft edge ends at ~0.7 of the plane width.
const float PLANE_WIDTH = 1.6f;
const float FLAME_LENGTH = 1.5f;
// Flat (2D) nozzles like the F-22's: the flame leaves the nozzle flat (so it stays inside the nozzle) and
// rounds out to a full plume over the first ROUND_OUT of its length, instead of staying a thin sheet.
const float MIN_ASPECT = 1.0f;
const float ROUND_OUT = 0.4f;
const int SEGMENTS = 5;
const float DISC_SIZE = 1.1f;     // nozzle disc vs nozzle size
const float DISC_OFFSET = 0.05f;  // disc sits this far (m) aft of the cone's base, clear of the nozzle walls
const float MIN_RADIUS = 0.05f;   // smaller pieces, or pieces shorter than wide, are not flames
const float MAX_STRETCH = 0.1f;   // the shader lengthens the flame by up to this fraction (culling box grows)

struct Box {
    Vector3 lo = Vector3(1e9f, 1e9f, 1e9f);
    Vector3 hi = Vector3(-1e9f, -1e9f, -1e9f);
    void add(const Vector3 &p) {
        lo = Vector3(std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z));
        hi = Vector3(std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z));
    }
    void add(const Box &b) { add(b.lo); add(b.hi); }
    bool overlaps_seen_from_behind(const Box &b) const {
        return lo.x <= b.hi.x && b.lo.x <= hi.x && lo.y <= b.hi.y && b.lo.y <= hi.y;
    }
};

int root_of(std::vector<int> &parent, int i) {
    while (parent[i] != i) {
        parent[i] = parent[parent[i]];
        i = parent[i];
    }
    return i;
}

// Boxes (Godot coordinates) of the shell's separate pieces: joined by shared vertices, then pieces whose
// outlines overlap seen from behind are one flame (some models don't share vertices between faces).
std::vector<Box> flame_pieces(const YsShellExt &shl) {
    std::unordered_map<YSHASHKEY, int> index;
    std::vector<Vector3> pos;
    for (auto vtHd : shl.AllVertex()) {
        YsVec3 p;
        shl.GetVertexPosition(p, vtHd);
        index[shl.GetSearchKey(vtHd)] = (int)pos.size();
        pos.push_back(ys_to_godot_pos(p));
    }
    std::vector<int> parent(pos.size());
    std::vector<char> used(pos.size(), 0);
    for (int i = 0; i < (int)parent.size(); ++i) {
        parent[i] = i;
    }
    for (auto plHd : shl.AllPolygon()) {
        int nVt = 0;
        const YsShellVertexHandle *vtHd = nullptr;
        shl.GetVertexListOfPolygon(nVt, vtHd, plHd);
        if (nVt < 3) {
            continue;
        }
        const int first = index[shl.GetSearchKey(vtHd[0])];
        used[first] = 1;
        for (int i = 1; i < nVt; ++i) {
            const int v = index[shl.GetSearchKey(vtHd[i])];
            used[v] = 1;
            parent[root_of(parent, v)] = root_of(parent, first);
        }
    }
    std::unordered_map<int, Box> by_root;
    for (int i = 0; i < (int)pos.size(); ++i) {
        if (used[i]) {
            by_root[root_of(parent, i)].add(pos[i]);
        }
    }
    std::vector<Box> boxes;
    for (const auto &kv : by_root) {
        boxes.push_back(kv.second);
    }
    for (bool merged = true; merged;) {
        merged = false;
        for (size_t i = 0; i < boxes.size() && !merged; ++i) {
            for (size_t j = i + 1; j < boxes.size(); ++j) {
                if (boxes[i].overlaps_seen_from_behind(boxes[j])) {
                    boxes[i].add(boxes[j]);
                    boxes.erase(boxes.begin() + j);
                    merged = true;
                    break;
                }
            }
        }
    }
    return boxes;
}

struct Buffers {
    PackedVector3Array verts, norms;
    PackedVector2Array uv, uv2;
};

void add_quad(Buffers &b, const Vector3 (&c)[4], const Vector2 (&uv)[4], const Vector3 &normal, const Vector2 &uv2) {
    static const int ORDER[6] = {0, 1, 2, 0, 2, 3};
    for (int k : ORDER) {
        b.verts.push_back(c[k]);
        b.norms.push_back(normal);
        b.uv.push_back(uv[k]);
        b.uv2.push_back(uv2);
    }
}

// One flame plane along the axis through c, `side` = the plane's across direction. Its half-width grows
// from the nozzle's (w_nozzle) to the plume's (w_plume) over the first ROUND_OUT of the length; built in
// SEGMENTS pieces so the texture coordinates don't kink where the width changes.
void add_plane(Buffers &b, const Vector3 &c, const Vector3 &side, float w_nozzle, float w_plume, float z0, float z1,
               const Vector3 &normal) {
    const Vector2 flame(0.0f, z1 - z0);
    auto half_width = [&](float v) { return w_nozzle + (w_plume - w_nozzle) * std::min(v / ROUND_OUT, 1.0f); };
    for (int s = 0; s < SEGMENTS; ++s) {
        const float v0 = (float)s / SEGMENTS;
        const float v1 = (float)(s + 1) / SEGMENTS;
        const Vector3 a(c.x, c.y, z0 + (z1 - z0) * v0);
        const Vector3 e(c.x, c.y, z0 + (z1 - z0) * v1);
        const Vector3 q[4] = {a - side * half_width(v0), a + side * half_width(v0), e + side * half_width(v1),
                              e - side * half_width(v1)};
        const Vector2 uv[4] = {Vector2(0, v0), Vector2(1, v0), Vector2(1, v1), Vector2(0, v1)};
        add_quad(b, q, uv, normal, flame);
    }
}

// The cone's base (nozzle) is its forward end (Godot -Z); the flame runs aft to +Z.
void add_flame(Buffers &b, const Box &box) {
    const Vector3 c = (box.lo + box.hi) * 0.5f;
    const float rx = (box.hi.x - box.lo.x) * 0.5f; // nozzle
    const float ry = (box.hi.y - box.lo.y) * 0.5f;
    const float px = std::max(rx, ry * MIN_ASPECT); // plume
    const float py = std::max(ry, rx * MIN_ASPECT);
    const float z0 = box.lo.z;
    const float z1 = z0 + (box.hi.z - box.lo.z) * FLAME_LENGTH;
    add_plane(b, c, Vector3(1, 0, 0), rx * PLANE_WIDTH, px * PLANE_WIDTH, z0, z1, Vector3(0, 1, 0));
    add_plane(b, c, Vector3(0, 1, 0), ry * PLANE_WIDTH, py * PLANE_WIDTH, z0, z1, Vector3(1, 0, 0));
    const float dz = z0 + DISC_OFFSET;
    const float dx = rx * DISC_SIZE;
    const float dy = ry * DISC_SIZE;
    const Vector3 disc[4] = {Vector3(c.x - dx, c.y - dy, dz), Vector3(c.x + dx, c.y - dy, dz),
                             Vector3(c.x + dx, c.y + dy, dz), Vector3(c.x - dx, c.y + dy, dz)};
    static const Vector2 DISC_UV[4] = {Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)};
    add_quad(b, disc, DISC_UV, Vector3(0, 0, 1), Vector2(1.0f, z1 - z0));
}

// Heat haze: crossed planes like the flame, from partway along it to HAZE_LENGTH x the cone's length,
// widening as the exhaust spreads. Starting inside the flame's faint tail hides where the haze begins.
void add_haze(Buffers &b, const Box &box) {
    const Vector3 c = (box.lo + box.hi) * 0.5f;
    const float rx = (box.hi.x - box.lo.x) * 0.5f;
    const float ry = (box.hi.y - box.lo.y) * 0.5f;
    const float r = std::max(rx, ry) * PLANE_WIDTH;
    const float len = box.hi.z - box.lo.z;
    const float z0 = box.lo.z + len * FLAME_LENGTH * HAZE_START;
    const float z1 = box.lo.z + len * HAZE_LENGTH;
    add_plane(b, c, Vector3(1, 0, 0), r * HAZE_WIDTH_START, r * HAZE_WIDTH_END, z0, z1, Vector3(0, 1, 0));
    add_plane(b, c, Vector3(0, 1, 0), r * HAZE_WIDTH_START, r * HAZE_WIDTH_END, z0, z1, Vector3(1, 0, 0));
}

Ref<ShaderMaterial> load_material(const char *path) {
    Ref<ShaderMaterial> m;
    m.instantiate();
    m->set_shader(ResourceLoader::get_singleton()->load(path));
    return m;
}

Ref<ArrayMesh> to_mesh(const Buffers &b, const Ref<ShaderMaterial> &mat, float aabb_growth) {
    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = b.verts;
    arrays[Mesh::ARRAY_NORMAL] = b.norms;
    arrays[Mesh::ARRAY_TEX_UV] = b.uv;
    arrays[Mesh::ARRAY_TEX_UV2] = b.uv2;
    Ref<ArrayMesh> mesh;
    mesh.instantiate();
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    mesh->surface_set_material(0, mat);
    const AABB box = mesh->get_aabb();
    mesh->set_custom_aabb(box.grow(box.size.z * aabb_growth));
    return mesh;
}

} // namespace

const Ref<ShaderMaterial> &BurnerMeshCache::material() {
    if (flame_mat.is_null()) {
        flame_mat = load_material(FLAME_SHADER);
    }
    return flame_mat;
}

const Ref<ShaderMaterial> &BurnerMeshCache::haze_material() {
    if (haze_mat.is_null()) {
        haze_mat = load_material(HAZE_SHADER);
        haze_mat->set_render_priority(-1); // before flames and smoke, which then stay sharp on top
    }
    return haze_mat;
}

const BurnerMeshCache::Meshes &BurnerMeshCache::get(const YsShellExt &shell) {
    const void *cache_key = static_cast<const void *>(&shell);
    auto it = cache.find(cache_key);
    if (it != cache.end()) {
        return it->second;
    }
    Meshes m;
    const std::vector<Box> pieces = flame_pieces(shell);
    bool cone_shaped = !pieces.empty();
    for (const Box &p : pieces) {
        const float r = std::max(p.hi.x - p.lo.x, p.hi.y - p.lo.y) * 0.5f;
        cone_shaped = cone_shaped && r >= MIN_RADIUS && (p.hi.z - p.lo.z) > r;
    }
    if (cone_shaped) {
        Buffers flame, haze;
        for (const Box &p : pieces) {
            add_flame(flame, p);
            add_haze(haze, p);
        }
        m.flame = to_mesh(flame, material(), MAX_STRETCH);
        m.haze = to_mesh(haze, haze_material(), 0.0f);
    } else {
        log_line("Burner: afterburner part is not cone-shaped, keeping the model's own mesh");
    }
    return cache[cache_key] = m;
}

} // namespace ysgd
