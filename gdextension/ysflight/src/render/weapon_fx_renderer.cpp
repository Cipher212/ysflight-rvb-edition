#include "render/weapon_fx_renderer.h"

#include <algorithm>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include "core/ys_convert.h"
#include "core/ys_headers.h"
#include "sim/motion_interp.h"

using namespace godot;

namespace ysgd {

namespace {

constexpr int MAX_TRACERS = 512;
constexpr int MAX_GLOWS = 128;
constexpr int FLOATS_PER_INSTANCE = 16; // transform 12 + colour 4

const Color GUN_TRACER(1.0f, 0.78f, 0.22f, 0.96f);  // warm 20 mm tracer
const Color DEBRIS_TRACER(1.0f, 0.48f, 0.14f, 0.90f);
const Color MISSILE_GLOW(1.0f, 0.72f, 0.28f, 0.95f);
const Color FLARE_GLOW(1.0f, 0.92f, 0.60f, 1.0f);
constexpr float MISSILE_GLOW_TAIL_M = 1.6f;

// Two perpendicular quads along Z (-0.5 .. 0.5); UV.y = 0 at the front tip (-Z), 1 at the tail.
Ref<ArrayMesh> crossed_fin_mesh(float half_width) {
    PackedVector3Array v;
    PackedVector2Array uv;
    auto quad = [&](const Vector3 &a, const Vector3 &b) { // a = +side offset, b = -side offset
        const Vector3 f(0, 0, -0.5f), k(0, 0, 0.5f);
        v.push_back(a + f); uv.push_back(Vector2(0, 0));
        v.push_back(b + f); uv.push_back(Vector2(1, 0));
        v.push_back(b + k); uv.push_back(Vector2(1, 1));
        v.push_back(a + f); uv.push_back(Vector2(0, 0));
        v.push_back(b + k); uv.push_back(Vector2(1, 1));
        v.push_back(a + k); uv.push_back(Vector2(0, 1));
    };
    quad(Vector3(0, half_width, 0), Vector3(0, -half_width, 0));
    quad(Vector3(half_width, 0, 0), Vector3(-half_width, 0, 0));
    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = v;
    arrays[Mesh::ARRAY_TEX_UV] = uv;
    Ref<ArrayMesh> mesh;
    mesh.instantiate();
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    return mesh;
}

Ref<ShaderMaterial> load_material(const char *path) {
    Ref<ShaderMaterial> m;
    m.instantiate();
    m->set_shader(ResourceLoader::get_singleton()->load(path));
    return m;
}

Ref<MultiMesh> make_multimesh(Node3D *parent, const char *name, const Ref<Mesh> &mesh, int count) {
    Ref<MultiMesh> mm;
    mm.instantiate();
    mm->set_transform_format(MultiMesh::TRANSFORM_3D);
    mm->set_use_colors(true);
    mm->set_mesh(mesh);
    mm->set_instance_count(count);
    mm->set_visible_instance_count(0);
    MultiMeshInstance3D *node = memnew(MultiMeshInstance3D);
    node->set_name(name);
    node->set_multimesh(mm);
    node->set_custom_aabb(AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7)));
    node->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
    parent->add_child(node);
    return mm;
}

// Right-handed basis whose -Z points along dir, scaled per axis.
Basis basis_from_forward(const Vector3 &dir, const Vector3 &scale) {
    const Vector3 z = -dir.normalized();
    const Vector3 up = std::abs(z.dot(Vector3(0, 1, 0))) < 0.95f ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
    const Vector3 x = up.cross(z).normalized();
    const Vector3 y = z.cross(x).normalized();
    Basis b;
    b.set_column(0, x * scale.x);
    b.set_column(1, y * scale.y);
    b.set_column(2, z * scale.z);
    return b;
}

void write_instance(float *b, const Transform3D &t, const Color &c) {
    for (int r = 0; r < 3; ++r) {
        b[r * 4 + 0] = t.basis.rows[r].x;
        b[r * 4 + 1] = t.basis.rows[r].y;
        b[r * 4 + 2] = t.basis.rows[r].z;
        b[r * 4 + 3] = t.origin[r];
    }
    b[12] = c.r; b[13] = c.g; b[14] = c.b; b[15] = c.a;
}

// Cheap per-weapon flicker, stable within a frame: 0..1
float flicker(unsigned int slot, uint64_t frame) {
    uint32_t h = (uint32_t)slot * 747796405u + (uint32_t)frame * 2891336453u;
    h ^= h >> 16;
    h *= 2246822519u;
    h ^= h >> 13;
    return (float)(h & 0xFFFF) / 65535.0f;
}

} // namespace

void WeaponFxRenderer::attach(Node3D *parent) {
    Ref<ArrayMesh> fin = crossed_fin_mesh(0.14f);
    fin->surface_set_material(0, load_material("res://shaders/tracer.gdshader"));
    tracer_mm = make_multimesh(parent, "Tracers", fin, MAX_TRACERS);

    Ref<QuadMesh> quad;
    quad.instantiate();
    quad->set_size(Vector2(1.0f, 1.0f));
    quad->set_material(load_material("res://shaders/exhaust_glow.gdshader"));
    glow_mm = make_multimesh(parent, "ExhaustGlows", quad, MAX_GLOWS);

    tracer_buf.resize(MAX_TRACERS * FLOATS_PER_INSTANCE);
    glow_buf.resize(MAX_GLOWS * FLOATS_PER_INSTANCE);
    tracers = glows = 0;
}

void WeaponFxRenderer::draw(FsSimulation *sim, const MotionInterp &interp, uint64_t frame_number) {
    if (sim == nullptr || tracer_mm.is_null()) {
        return;
    }
    float *tb = tracer_buf.ptrw();
    float *gb = glow_buf.ptrw();
    int nt = 0, ng = 0;
    const FsWeapon *base = sim->GetWeaponStore().buf;
    const FsWeapon *w = nullptr;
    while ((w = sim->FindNextActiveWeapon(w)) != nullptr) {
        if (w->lifeRemain <= 0.0) {
            continue;
        }
        const FSWEAPONTYPE type = w->type;
        if (type == FSWEAPON_GUN || type == FSWEAPON_DEBRIS) {
            if (nt >= MAX_TRACERS) {
                continue;
            }
            const Vector3 pos = interp.wpn(w).origin;
            const Vector3 seg = ys_to_godot_pos(w->pos) - ys_to_godot_pos(w->prv); // one sim step of travel
            const float seg_len = seg.length();
            Vector3 dir(0, 0, -1);
            if (seg_len > 0.01f) {
                dir = seg / seg_len;
            } else if (ys_to_godot_pos(w->vec).length_squared() > 0.01f) {
                dir = ys_to_godot_pos(w->vec).normalized();
            }
            const bool debris = (type == FSWEAPON_DEBRIS);
            const float len = debris ? std::clamp(std::max(seg_len * 0.85f, 4.5f), 3.0f, 10.0f)
                                     : std::clamp(std::max(seg_len * 0.95f, 11.0f), 7.0f, 22.0f);
            const float width = debris ? 1.25f : 1.0f;
            const Transform3D t(basis_from_forward(dir, Vector3(width, width, len)), pos - dir * (len * 0.45f));
            write_instance(tb + nt * FLOATS_PER_INSTANCE, t, debris ? DEBRIS_TRACER : GUN_TRACER);
            ++nt;
            continue;
        }
        const bool missile = type == FSWEAPON_AIM9 || type == FSWEAPON_AIM9X || type == FSWEAPON_AIM120 ||
                             type == FSWEAPON_AGM65 || type == FSWEAPON_ROCKET;
        const bool flare = type == FSWEAPON_FLARE;
        if ((!missile && !flare) || ng >= MAX_GLOWS || w->shouldJettison == YSTRUE) {
            continue;
        }
        const Transform3D wt = interp.wpn(w);
        const float r = flicker((unsigned int)(w - base), frame_number);
        const float size = missile ? 2.2f + 0.9f * r : 3.2f + 1.2f * r;
        const Vector3 pos = wt.origin + wt.basis.get_column(2) * (missile ? MISSILE_GLOW_TAIL_M : 0.0f); // Godot +Z = tail
        write_instance(gb + ng * FLOATS_PER_INSTANCE, Transform3D(Basis().scaled(Vector3(size, size, size)), pos),
                       missile ? MISSILE_GLOW : FLARE_GLOW);
        ++ng;
    }
    if (nt > 0) {
        tracer_mm->set_buffer(tracer_buf);
    }
    if (ng > 0) {
        glow_mm->set_buffer(glow_buf);
    }
    tracer_mm->set_visible_instance_count(nt);
    glow_mm->set_visible_instance_count(ng);
    tracers = nt;
    glows = ng;
}

} // namespace ysgd
