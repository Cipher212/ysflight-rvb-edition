#include "render/shell_mesh.h"

#include <godot_cpp/variant/array.hpp>

#include "core/ys_convert.h"
#include "core/ys_headers.h"

using namespace godot;

namespace ysgd {

void add_oriented_triangle(PackedVector3Array &verts, PackedVector3Array &norms, PackedColorArray &cols,
                           const Vector3 &p0, const Vector3 &p1, const Vector3 &p2,
                           const Vector3 &n0, const Vector3 &n1, const Vector3 &n2,
                           const Vector3 &face_n,
                           const Color &c0, const Color &c1, const Color &c2) {
    if ((p1 - p0).cross(p2 - p0).dot(face_n) > 0.0f) {
        verts.push_back(p0); verts.push_back(p2); verts.push_back(p1);
        norms.push_back(n0); norms.push_back(n2); norms.push_back(n1);
        cols.push_back(c0);  cols.push_back(c2);  cols.push_back(c1);
    } else {
        verts.push_back(p0); verts.push_back(p1); verts.push_back(p2);
        norms.push_back(n0); norms.push_back(n1); norms.push_back(n2);
        cols.push_back(c0);  cols.push_back(c1);  cols.push_back(c2);
    }
}

namespace {

struct SurfaceBuffers {
    PackedVector3Array verts, norms;
    PackedColorArray cols;
};

// Smooth normals for vertices marked round ('R') = sum of the normals of the polygons using them.
// Accumulating over AllPolygon() avoids needing a search table attached to the shell.
void accumulate_round_vertex_normals(const YsShellExt &shl, YsHashTable<YsVec3> &out) {
    for (auto plHd : shl.AllPolygon()) {
        int nVt = 0;
        const YsShellVertexHandle *vtIdx = nullptr;
        shl.GetVertexListOfPolygon(nVt, vtIdx, plHd);
        if (nVt < 3) {
            continue;
        }
        YsVec3 plNom;
        shl.GetNormal(plNom, plHd);
        if (plNom == YsOrigin()) {
            YsArray<YsVec3, 16> pts(nVt, nullptr);
            for (int i = 0; i < nVt; ++i) {
                shl.GetVertexPosition(pts[i], vtIdx[i]);
            }
            YsGetAverageNormalVector(plNom, nVt, pts);
        }
        if (plNom == YsOrigin()) {
            continue;
        }
        for (int i = 0; i < nVt; ++i) {
            const YsShellExt::VertexAttrib *vtAttr = shl.GetVertexAttrib(vtIdx[i]);
            if (vtAttr != nullptr && vtAttr->IsRound() == YSTRUE) {
                const auto vkey = shl.GetSearchKey(vtIdx[i]);
                YsVec3 cur = YsOrigin();
                out.FindElement(cur, vkey);
                out.UpdateElement(vkey, cur + plNom);
            }
        }
    }
}

// Triangulates one polygon (fan if convex, YsSword otherwise) into the given buffers.
void append_polygon(SurfaceBuffers &buf, int nPlVt, const YsArray<YsVec3, 16> &plg, const YsArray<YsVec3, 16> &vtxNoms,
                    const Vector3 &gface_n, const Color &gcol) {
    if (nPlVt == 3 || YsCheckConvex3(nPlVt, plg) == YSTRUE) {
        const Vector3 p0 = ys_to_godot_pos(plg[0]);
        const Vector3 n0 = ys_to_godot_normal(vtxNoms[0]);
        for (int i = 1; i < nPlVt - 1; ++i) {
            add_oriented_triangle(buf.verts, buf.norms, buf.cols,
                                  p0, ys_to_godot_pos(plg[i]), ys_to_godot_pos(plg[i + 1]),
                                  n0, ys_to_godot_normal(vtxNoms[i]), ys_to_godot_normal(vtxNoms[i + 1]),
                                  gface_n, gcol, gcol, gcol);
        }
        return;
    }
    YsSword sword;
    YsArray<int, 16> idx(nPlVt, nullptr);
    for (int i = 0; i < nPlVt; ++i) {
        idx[i] = i;
    }
    if (sword.SetInitialPolygon(nPlVt, plg, idx) != YSOK || sword.Triangulate() != YSOK) {
        return;
    }
    auto normal_of = [&](int vi) -> Vector3 {
        return (0 <= vi && vi < nPlVt) ? ys_to_godot_normal(vtxNoms[vi]) : gface_n;
    };
    for (int i = 0; i < sword.GetNumPolygon(); ++i) {
        const YsArray<YsVec3> *tri = sword.GetPolygon(i);
        const YsArray<int> *triIdx = sword.GetVertexIdList(i);
        if (tri == nullptr || triIdx == nullptr || tri->GetN() < 3) {
            continue;
        }
        const Vector3 p0 = ys_to_godot_pos((*tri)[0]);
        const Vector3 n0 = normal_of((*triIdx)[0]);
        for (int j = 1; j < tri->GetN() - 1; ++j) {
            add_oriented_triangle(buf.verts, buf.norms, buf.cols,
                                  p0, ys_to_godot_pos((*tri)[j]), ys_to_godot_pos((*tri)[j + 1]),
                                  n0, normal_of((*triIdx)[j]), normal_of((*triIdx)[j + 1]),
                                  gface_n, gcol, gcol, gcol);
        }
    }
}

} // namespace

Ref<ArrayMesh> ShellMeshCache::get(const YsShellExt &shl) {
    const void *cache_key = static_cast<const void *>(&shl);
    auto it = cache.find(cache_key);
    if (it != cache.end()) {
        return it->second;
    }

    YsHashTable<YsVec3> round_normals;
    accumulate_round_vertex_normals(shl, round_normals);

    SurfaceBuffers lit, bright, trans;
    for (auto plHd : shl.AllPolygon()) {
        int nPlVt = 0;
        const YsShellVertexHandle *plVtHd = nullptr;
        shl.GetVertexListOfPolygon(nPlVt, plVtHd, plHd);
        if (nPlVt < 3) {
            continue;
        }
        YsArray<YsVec3, 16> plg(nPlVt, nullptr);
        YsArray<YsVec3, 16> vtxNoms(nPlVt, nullptr);
        for (int i = 0; i < nPlVt; ++i) {
            shl.GetVertexPosition(plg[i], plVtHd[i]);
        }
        YsVec3 faceNom;
        shl.GetNormal(faceNom, plHd);
        if (faceNom == YsOrigin()) {
            YsGetAverageNormalVector(faceNom, nPlVt, plg);
        }
        for (int i = 0; i < nPlVt; ++i) {
            YsVec3 smoothNom;
            const bool round = round_normals.FindElement(smoothNom, shl.GetSearchKey(plVtHd[i])) == YSOK && smoothNom != YsOrigin();
            vtxNoms[i] = round ? smoothNom : faceNom;
        }

        YsColor plCol;
        shl.GetColor(plCol, plHd);
        const Color gcol = ys_to_godot_color(plCol);
        const YsShellExt::PolygonAttrib *plAttr = shl.GetPolygonAttrib(plHd);
        const bool is_bright = (plAttr != nullptr && plAttr->GetNoShading() == YSTRUE);
        SurfaceBuffers &target = gcol.a < 0.99f ? trans : (is_bright ? bright : lit);
        append_polygon(target, nPlVt, plg, vtxNoms, ys_to_godot_normal(faceNom), gcol);
    }

    Ref<ArrayMesh> mesh;
    mesh.instantiate();
    auto append_surface = [&](const SurfaceBuffers &b, const Ref<StandardMaterial3D> &mat) {
        if (b.verts.is_empty()) {
            return;
        }
        Array arrays;
        arrays.resize(Mesh::ARRAY_MAX);
        arrays[Mesh::ARRAY_VERTEX] = b.verts;
        arrays[Mesh::ARRAY_NORMAL] = b.norms;
        arrays[Mesh::ARRAY_COLOR] = b.cols;
        const int surf_idx = mesh->get_surface_count();
        mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
        mesh->surface_set_material(surf_idx, mat);
    };
    append_surface(lit, mats.lit);
    append_surface(bright, mats.bright);
    append_surface(trans, mats.trans);

    cache[cache_key] = mesh;
    return mesh;
}

} // namespace ysgd
