#include "render/aircraft_shadows.h"

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include "core/ys_convert.h"
#include "core/ys_headers.h"
#include "sim/motion_interp.h"

using namespace godot;

namespace ysgd {

namespace {

const char *SHADER_PATH = "res://shaders/aircraft_shadow.gdshader";
constexpr double RANGE_M = 4000.0;       // no shadow further from the camera (a fighter's is ~5 px there)
constexpr double FULL_DETAIL_M = 100.0;  // YS: the whole model within 100 m, the collision shell beyond
constexpr double LIFT_M = 0.01;          // YS: terrainOrg + 0.01
constexpr double MIN_NORMAL_Y = 0.2;     // no shadow on near-vertical terrain
constexpr float THICKNESS = 0.001f;      // flattened to 0.1 % of the model's height (keeps the basis invertible)
constexpr int DNM_CLASS_AFTERBURNER = 2; // the flames are drawn separately and cast no shadow

// Appends a shell's polygons as triangles (convex: fan, concave: YsSword), transformed to model space.
void append_triangles(const YsShellExt &shl, const YsMatrix4x4 &tfm, PackedVector3Array &out) {
    for (auto plHd : shl.AllPolygon()) {
        int nVt = 0;
        const YsShellVertexHandle *vtHd = nullptr;
        shl.GetVertexListOfPolygon(nVt, vtHd, plHd);
        if (nVt < 3) {
            continue;
        }
        YsArray<YsVec3, 16> plg(nVt, nullptr);
        for (int i = 0; i < nVt; ++i) {
            YsVec3 local;
            shl.GetVertexPosition(local, vtHd[i]);
            tfm.Mul(plg[i], local, 1.0);
        }
        if (nVt == 3 || YsCheckConvex3(nVt, plg) == YSTRUE) {
            for (int i = 1; i + 1 < nVt; ++i) {
                out.push_back(ys_to_godot_pos(plg[0]));
                out.push_back(ys_to_godot_pos(plg[i]));
                out.push_back(ys_to_godot_pos(plg[i + 1]));
            }
            continue;
        }
        YsSword sword;
        YsArray<int, 16> idx(nVt, nullptr);
        for (int i = 0; i < nVt; ++i) {
            idx[i] = i;
        }
        if (sword.SetInitialPolygon(nVt, plg, idx) != YSOK || sword.Triangulate() != YSOK) {
            continue;
        }
        for (int i = 0; i < sword.GetNumPolygon(); ++i) {
            const YsArray<YsVec3> *tri = sword.GetPolygon(i);
            if (tri == nullptr) {
                continue;
            }
            for (int j = 1; j + 1 < tri->GetN(); ++j) {
                out.push_back(ys_to_godot_pos((*tri)[0]));
                out.push_back(ys_to_godot_pos((*tri)[j]));
                out.push_back(ys_to_godot_pos((*tri)[j + 1]));
            }
        }
    }
}

Ref<ArrayMesh> to_mesh(const PackedVector3Array &verts, const Ref<ShaderMaterial> &mat) {
    if (verts.is_empty()) {
        return Ref<ArrayMesh>();
    }
    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = verts;
    Ref<ArrayMesh> mesh;
    mesh.instantiate();
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    mesh->surface_set_material(0, mat);
    return mesh;
}

// World transform that drops every point straight down onto the plane through o with normal n (Godot coords).
Transform3D flatten_onto(const Vector3 &o, const Vector3 &n) {
    const float a = -n.x / n.y;
    const float b = -n.z / n.y;
    const float c = o.y + (n.x * o.x + n.z * o.z) / n.y;
    const float k = 1.0f - THICKNESS;
    return Transform3D(Basis(Vector3(1.0f, k * a, 0.0f), Vector3(0.0f, THICKNESS, 0.0f), Vector3(0.0f, k * b, 1.0f)),
                       Vector3(0.0f, k * c, 0.0f));
}

} // namespace

void AircraftShadows::attach(Node3D *parent) {
    root = memnew(Node3D);
    root->set_name("AircraftShadows");
    parent->add_child(root);
    shadows.clear();
    type_meshes.clear();
    if (mat.is_null()) {
        mat.instantiate();
        mat->set_shader(ResourceLoader::get_singleton()->load(SHADER_PATH));
    }
}

const AircraftShadows::TypeMeshes &AircraftShadows::meshes_for(FsAirplane *air) {
    auto dnm = air->vis.GetDnmPtr();
    auto it = type_meshes.find(dnm.get());
    if (it != type_meshes.end()) {
        return it->second;
    }
    TypeMeshes m;
    PackedVector3Array full;
    auto &state = air->vis.GetDnmState();
    dnm->CacheTransformation(state);
    auto nodes = dnm->GetNodePointerAll();
    for (int i = 0; i < (int)nodes.GetN(); ++i) {
        auto *node = nodes[i];
        if (node != nullptr && node->dnmClassType != DNM_CLASS_AFTERBURNER && state.GetShow(node) == YSTRUE) {
            append_triangles(*node, state.GetNodeToRootTransformation(node), full);
        }
    }
    PackedVector3Array coarse;
    append_triangles(air->UntransformedCollisionShell(), YsIdentity4x4(), coarse);
    m.full = to_mesh(full, mat);
    m.coarse = coarse.is_empty() ? m.full : to_mesh(coarse, mat);
    return type_meshes[dnm.get()] = m;
}

void AircraftShadows::sync(FsSimulation *sim, const MotionInterp &interp, const YsVec3 &camera_pos) {
    if (root == nullptr || sim == nullptr || !enabled) {
        return;
    }
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        const unsigned int key = air->SearchKey();
        if (air->vis.GetDnmPtr() == nullptr) {
            continue;
        }
        const TypeMeshes &meshes = meshes_for(air); // built for every type up front (load), not mid-flight
        YsVec3 org = air->terrainOrg;
        org.AddY(LIFT_M);
        const double dist2 = (camera_pos - org).GetSquareLength();
        // Alive includes shot-down jets still falling (as drawn by VisualSync).
        const bool show = air->IsAlive() == YSTRUE && air->terrainNom.y() > MIN_NORMAL_Y && dist2 < RANGE_M * RANGE_M;
        auto it = shadows.find(key);
        if (!show) {
            if (it != shadows.end() && it->second.visible) {
                it->second.node->set_visible(false);
                it->second.visible = false;
            }
            continue;
        }
        if (meshes.full.is_null()) {
            continue;
        }
        if (it == shadows.end()) {
            Shadow s;
            s.node = memnew(MeshInstance3D);
            s.node->set_name("Shadow_" + String::num_int64(key));
            s.node->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
            root->add_child(s.node);
            it = shadows.emplace(key, s).first;
        }
        Shadow &s = it->second;
        const int detail = dist2 < FULL_DETAIL_M * FULL_DETAIL_M ? 1 : 0;
        if (s.detail != detail) {
            s.node->set_mesh(detail == 1 ? meshes.full : meshes.coarse);
            s.detail = detail;
        }
        const Transform3D tfm = flatten_onto(ys_to_godot_pos(org), ys_to_godot_normal(air->terrainNom)) * interp.air(air);
        if (tfm != s.tfm) {
            s.node->set_transform(tfm);
            s.tfm = tfm;
        }
        if (!s.visible) {
            s.node->set_visible(true);
            s.visible = true;
        }
    }
}

void AircraftShadows::set_enabled(bool on) {
    enabled = on;
    if (!on) {
        for (auto &kv : shadows) {
            if (kv.second.visible) {
                kv.second.node->set_visible(false);
                kv.second.visible = false;
            }
        }
    }
}

void AircraftShadows::forget_airplane(unsigned int key) {
    auto it = shadows.find(key);
    if (it != shadows.end()) {
        if (it->second.node != nullptr) {
            it->second.node->queue_free();
        }
        shadows.erase(it);
    }
}

} // namespace ysgd
