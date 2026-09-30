#include "render/scenery_builder.h"

#include <cmath>
#include <unordered_map>

#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "core/ys_convert.h"
#include "core/ys_headers.h"

using namespace godot;

namespace ysgd {

namespace {

constexpr double OUTSIDE_SEA_EXTENT_M = 250000.0; // the ring around the map reaches past the longest draw distance

// Sea / lake colours (blue or teal, not grey or green): these flat map polygons get the water shading.
bool is_water_colour(const Color &c) {
    return c.b > c.r * 1.15f && c.b >= c.g * 0.85f && c.b > 0.2f;
}

// Triangles, lines and points of 2D drawings (maps and signboards). UV.x = layer index for depth biasing,
// UV.y = 1 on flat water triangles (map_poly.gdshader).
struct DrawingBuffers {
    PackedVector3Array tri_v, tri_n, line_v, pt_v;
    PackedColorArray tri_c, line_c, pt_c;
    PackedVector2Array tri_uv, line_uv, pt_uv;

    bool empty() const { return tri_v.is_empty() && line_v.is_empty() && pt_v.is_empty(); }

    void add_triangle(const Vector3 &p0, const Vector3 &p1, const Vector3 &p2, const Vector3 &n,
                      const Color &c0, const Color &c1, const Color &c2, const Vector2 &uv) {
        add_oriented_triangle(tri_v, tri_n, tri_c, p0, p1, p2, n, n, n, n, c0, c1, c2);
        const Vector2 tuv(uv.x, (std::fabs(n.y) > 0.9f && is_water_colour(c0)) ? 1.0f : 0.0f);
        tri_uv.push_back(tuv);
        tri_uv.push_back(tuv);
        tri_uv.push_back(tuv);
    }
    void add_line(const Vector3 &a, const Vector3 &b, const Color &c, const Vector2 &uv) {
        line_v.push_back(a); line_c.push_back(c); line_uv.push_back(uv);
        line_v.push_back(b); line_c.push_back(c); line_uv.push_back(uv);
    }
    void shift_layers(float shift) {
        for (int i = 0; i < tri_uv.size(); ++i) tri_uv.set(i, Vector2(tri_uv[i].x + shift, tri_uv[i].y));
        for (int i = 0; i < line_uv.size(); ++i) line_uv.set(i, Vector2(line_uv[i].x + shift, 0.0f));
        for (int i = 0; i < pt_uv.size(); ++i) pt_uv.set(i, Vector2(pt_uv[i].x + shift, 0.0f));
    }

    Ref<ArrayMesh> to_mesh(const Materials &mats) const {
        Ref<ArrayMesh> mesh;
        mesh.instantiate();
        auto add = [&](Mesh::PrimitiveType prim, const PackedVector3Array &v, const PackedVector3Array *n,
                       const PackedColorArray &c, const PackedVector2Array &uv, const Ref<ShaderMaterial> &mat) {
            if (v.is_empty()) {
                return;
            }
            Array arr;
            arr.resize(Mesh::ARRAY_MAX);
            arr[Mesh::ARRAY_VERTEX] = v;
            if (n != nullptr) {
                arr[Mesh::ARRAY_NORMAL] = *n;
            }
            arr[Mesh::ARRAY_COLOR] = c;
            arr[Mesh::ARRAY_TEX_UV] = uv;
            const int s = mesh->get_surface_count();
            mesh->add_surface_from_arrays(prim, arr);
            mesh->surface_set_material(s, mat);
        };
        add(Mesh::PRIMITIVE_TRIANGLES, tri_v, &tri_n, tri_c, tri_uv, mats.map_poly);
        add(Mesh::PRIMITIVE_LINES, line_v, nullptr, line_c, line_uv, mats.map_line);
        add(Mesh::PRIMITIVE_POINTS, pt_v, nullptr, pt_c, pt_uv, mats.map_point);
        return mesh;
    }
};

YsMatrix4x4 child_transform(const YsMatrix4x4 &parent, const YsVec3 &pos, const YsAtt3 &att) {
    YsMatrix4x4 m = parent;
    m.Translate(pos);
    ys_apply_attitude(m, att);
    return m;
}

void append_2d_drawing(const Ys2DDrawing &drw, const YsMatrix4x4 &world_tfm, bool map_mode, int &elem_counter,
                       DrawingBuffers &out) {
    const YsVec3 local_nom = map_mode ? YsVec3(0.0, 1.0, 0.0) : YsVec3(0.0, 0.0, -1.0);
    YsVec3 world_nom_ys;
    world_tfm.Mul(world_nom_ys, local_nom, 0.0);
    const Vector3 n = ys_to_godot_normal(world_nom_ys);

    const YsListItem<Ys2DDrawingElement> *elemItem = nullptr;
    while ((elemItem = drw.FindNextElem(elemItem)) != nullptr) {
        const Ys2DDrawingElement &elem = elemItem->dat;
        const YsArray<YsVec2> &pts = elem.GetPointList();
        const int nPts = (int)pts.GetN();
        if (nPts == 0) {
            continue;
        }
        ++elem_counter;
        const Vector2 uv((float)elem_counter, 0.0f);
        auto P = [&](int i) -> Vector3 {
            const YsVec2 &p2 = pts[i];
            const YsVec3 local_pt = map_mode ? YsVec3(p2.x(), 0.0, p2.y()) : YsVec3(p2.x(), p2.y(), 0.0);
            YsVec3 world_pt;
            world_tfm.Mul(world_pt, local_pt, 1.0);
            return ys_to_godot_pos(world_pt);
        };
        const Color c1 = ys_to_godot_color(elem.GetColor());
        const Color c2 = ys_to_godot_color(elem.GetSecondColor());

        switch (elem.GetElemType()) {
            case Ys2DDrawingElement::POINTS:
            case Ys2DDrawingElement::APPROACHLIGHT:
                for (int i = 0; i < nPts; ++i) {
                    out.pt_v.push_back(P(i));
                    out.pt_c.push_back(c1);
                    out.pt_uv.push_back(uv);
                }
                break;
            case Ys2DDrawingElement::LINESEGMENTS:
                for (int i = 0; i < nPts - 1; ++i) out.add_line(P(i), P(i + 1), c1, uv);
                break;
            case Ys2DDrawingElement::LINES:
                for (int i = 0; i <= nPts - 2; i += 2) out.add_line(P(i), P(i + 1), c1, uv);
                break;
            case Ys2DDrawingElement::TRIANGLES:
                for (int i = 0; i <= nPts - 3; i += 3) out.add_triangle(P(i), P(i + 1), P(i + 2), n, c1, c1, c1, uv);
                break;
            case Ys2DDrawingElement::QUADS:
                for (int i = 0; i <= nPts - 4; i += 4) {
                    const Vector3 p0 = P(i), p1 = P(i + 1), p2 = P(i + 2), p3 = P(i + 3);
                    out.add_triangle(p0, p1, p2, n, c1, c1, c1, uv);
                    out.add_triangle(p0, p2, p3, n, c1, c1, c1, uv);
                }
                break;
            case Ys2DDrawingElement::QUADSTRIP:
                for (int i = 0; i <= nPts - 4; i += 2) {
                    const Vector3 p0 = P(i), p1 = P(i + 1), p2 = P(i + 2), p3 = P(i + 3);
                    out.add_triangle(p0, p1, p2, n, c1, c1, c1, uv);
                    out.add_triangle(p1, p3, p2, n, c1, c1, c1, uv);
                }
                break;
            case Ys2DDrawingElement::GRADATIONQUADSTRIP:
                for (int i = 0; i <= nPts - 4; i += 2) {
                    const Vector3 p0 = P(i), p1 = P(i + 1), p2 = P(i + 2), p3 = P(i + 3);
                    out.add_triangle(p0, p1, p2, n, c1, c1, c2, uv);
                    out.add_triangle(p1, p3, p2, n, c1, c2, c2, uv);
                }
                break;
            case Ys2DDrawingElement::POLYGON: {
                if (nPts < 3) {
                    break;
                }
                auto fan = [&]() {
                    const Vector3 p0 = P(0);
                    for (int i = 1; i < nPts - 1; ++i) out.add_triangle(p0, P(i), P(i + 1), n, c1, c1, c1, uv);
                };
                if (elem.IsConvex() == YSTRUE || nPts == 3) {
                    fan();
                    break;
                }
                YsShell2dTessellator tess;
                YsArray<YsShell2dVertexHandle> v2HdArray;
                if (tess.SetDomain(v2HdArray, nPts, pts) != YSOK) {
                    fan(); // the tessellator rejects self-intersecting outlines
                    break;
                }
                YsHashTable<YSSIZE_T> v2KeyToPntIdx;
                for (YSSIZE_T idx = 0; idx < v2HdArray.GetN(); ++idx) {
                    v2KeyToPntIdx.AddElement(tess.GetSearchKey(v2HdArray[idx]), idx);
                }
                for (;;) {
                    YSBOOL repeat = YSFALSE;
                    YsShell2dEdgeHandle edHd;
                    tess.GetShell2d().RewindEdgePtr();
                    while (nullptr != (edHd = tess.GetShell2d().StepEdgePtr())) {
                        if (tess.RemoveEdge(edHd, 100, YSFALSE) == YSOK) {
                            repeat = YSTRUE;
                        }
                    }
                    if (repeat != YSTRUE) {
                        break;
                    }
                }
                YsListItem<YsShell2dTessTriangle> *ptr;
                tess.triList.RewindPointer();
                while (nullptr != (ptr = tess.triList.StepPointer())) {
                    YSSIZE_T pi[3] = {0, 0, 0};
                    if (v2KeyToPntIdx.FindElement(pi[0], tess.GetSearchKey(ptr->dat.trVtHd[0])) == YSOK &&
                        v2KeyToPntIdx.FindElement(pi[1], tess.GetSearchKey(ptr->dat.trVtHd[1])) == YSOK &&
                        v2KeyToPntIdx.FindElement(pi[2], tess.GetSearchKey(ptr->dat.trVtHd[2])) == YSOK) {
                        out.add_triangle(P((int)pi[0]), P((int)pi[1]), P((int)pi[2]), n, c1, c1, c1, uv);
                    }
                }
                break;
            }
            default:
                break;
        }
    }
}

void add_mesh_node(Node3D *parent, const Ref<ArrayMesh> &mesh, const Transform3D &tfm) {
    MeshInstance3D *mi = memnew(MeshInstance3D);
    mi->set_mesh(mesh);
    mi->set_transform(tfm);
    parent->add_child(mi);
}

Ref<ArrayMesh> build_elevation_grid_mesh(const YsElevationGrid &evg, const Materials &mats) {
    PackedVector3Array verts, norms;
    PackedColorArray cols;
    for (int z = 0; z < evg.nz; ++z) {
        for (int x = 0; x < evg.nx; ++x) {
            for (int f = 0; f < 2; ++f) {
                const YsElevationGridNode &nd = evg.node[(evg.nx + 1) * z + x];
                if (nd.visible[f] != YSTRUE) {
                    continue;
                }
                YsVec3 tri[3], nom;
                evg.GetTriangle(tri, x, z, f);
                evg.GetTriangleNormal(nom, x, z, f);
                const Vector3 gn = ys_to_godot_normal(nom);
                Color c0, c1, c2;
                if (evg.colorByElevation == YSTRUE) {
                    c0 = ys_to_godot_color(evg.ColorByElevation(tri[0].y()));
                    c1 = ys_to_godot_color(evg.ColorByElevation(tri[1].y()));
                    c2 = ys_to_godot_color(evg.ColorByElevation(tri[2].y()));
                } else {
                    c0 = c1 = c2 = ys_to_godot_color(nd.c[f]);
                }
                add_oriented_triangle(verts, norms, cols, ys_to_godot_pos(tri[0]), ys_to_godot_pos(tri[1]),
                                      ys_to_godot_pos(tri[2]), gn, gn, gn, gn, c0, c1, c2);
            }
        }
    }

    // Side walls from the grid edge down to y = 0 (0: z = 0, 1: x = nx, 2: z = nz, 3: x = 0)
    auto add_wall_quad = [&](const YsVec3 &top0, const YsVec3 &top1, const YsVec3 &wall_nom, const Color &wcol) {
        if (top0.y() <= 1e-3 && top1.y() <= 1e-3) {
            return;
        }
        const Vector3 p0 = ys_to_godot_pos(YsVec3(top0.x(), 0.0, top0.z()));
        const Vector3 p1 = ys_to_godot_pos(YsVec3(top1.x(), 0.0, top1.z()));
        const Vector3 p2 = ys_to_godot_pos(top1);
        const Vector3 p3 = ys_to_godot_pos(top0);
        const Vector3 gn = ys_to_godot_normal(wall_nom);
        add_oriented_triangle(verts, norms, cols, p0, p1, p2, gn, gn, gn, gn, wcol, wcol, wcol);
        add_oriented_triangle(verts, norms, cols, p0, p2, p3, gn, gn, gn, gn, wcol, wcol, wcol);
    };
    auto wall = [&](int side, int count, auto corner_a, auto corner_b, const YsVec3 &nom) {
        if (evg.sideWall[side] != YSTRUE) {
            return;
        }
        const Color wc = ys_to_godot_color(evg.sideWallColor[side]);
        for (int i = 0; i < count; ++i) {
            YsVec3 a, b;
            corner_a(a, i);
            corner_b(b, i);
            add_wall_quad(a, b, nom, wc);
        }
    };
    wall(0, evg.nx, [&](YsVec3 &p, int i) { evg.GetGridPosition(p, i, 0); },
         [&](YsVec3 &p, int i) { evg.GetGridPosition(p, i + 1, 0); }, YsVec3(0.0, 0.0, -1.0));
    wall(1, evg.nz, [&](YsVec3 &p, int i) { evg.GetGridPosition(p, evg.nx, i); },
         [&](YsVec3 &p, int i) { evg.GetGridPosition(p, evg.nx, i + 1); }, YsVec3(1.0, 0.0, 0.0));
    wall(2, evg.nx, [&](YsVec3 &p, int i) { evg.GetGridPosition(p, i + 1, evg.nz); },
         [&](YsVec3 &p, int i) { evg.GetGridPosition(p, i, evg.nz); }, YsVec3(0.0, 0.0, 1.0));
    wall(3, evg.nz, [&](YsVec3 &p, int i) { evg.GetGridPosition(p, 0, i + 1); },
         [&](YsVec3 &p, int i) { evg.GetGridPosition(p, 0, i); }, YsVec3(-1.0, 0.0, 0.0));

    if (verts.is_empty()) {
        return Ref<ArrayMesh>();
    }
    Ref<ArrayMesh> mesh;
    mesh.instantiate();
    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = verts;
    arrays[Mesh::ARRAY_NORMAL] = norms;
    arrays[Mesh::ARRAY_COLOR] = cols;
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    mesh->surface_set_material(0, mats.terrain);
    return mesh;
}

void build_recursive(const YsScenery *scn, const YsMatrix4x4 &parent_tfm, Node3D *parent_node,
                     const Materials &mats, ShellMeshCache &meshes) {
    if (scn == nullptr) {
        return;
    }
    const YsMatrix4x4 scn_tfm = child_transform(parent_tfm, scn->GetPosition(), scn->GetAttitude());

    const YsListItem<YsSceneryElevationGrid> *evgItem = nullptr;
    while ((evgItem = scn->FindNextElevationGrid(evgItem)) != nullptr) {
        const YsSceneryElevationGrid &evgScn = evgItem->dat;
        const Ref<ArrayMesh> mesh = build_elevation_grid_mesh(evgScn.GetElevationGridData(), mats);
        if (mesh.is_valid()) {
            const YsMatrix4x4 tfm = child_transform(scn_tfm, evgScn.GetPosition(), evgScn.GetAttitude());
            add_mesh_node(parent_node, mesh, ys_matrix_to_godot_transform(tfm));
        }
    }

    const YsListItem<YsSceneryShell> *shlItem = nullptr;
    while ((shlItem = scn->FindNextShell(shlItem)) != nullptr) {
        const YsSceneryShell &shlScn = shlItem->dat;
        const auto &shl = shlScn.GetVisualShell();
        VertexShade shade; // baked darker base + occlusion (model_shading.h), once per shell
        if (!meshes.has(shl)) {
            shade = bake_shell_shade(shl);
        }
        const Ref<ArrayMesh> mesh = meshes.get(shl, &shade);
        if (mesh.is_valid() && mesh->get_surface_count() > 0) {
            const YsMatrix4x4 tfm = child_transform(scn_tfm, shlScn.GetPosition(), shlScn.GetAttitude());
            add_mesh_node(parent_node, mesh, ys_matrix_to_godot_transform(tfm));
        }
    }

    const YsListItem<YsScenery2DDrawing> *sbItem = nullptr;
    while ((sbItem = scn->FindNextSignBoard(sbItem)) != nullptr) {
        const YsScenery2DDrawing &sbScn = sbItem->dat;
        const YsMatrix4x4 tfm = child_transform(scn_tfm, sbScn.GetPosition(), sbScn.GetAttitude());
        DrawingBuffers buf;
        int elem_counter = 0;
        append_2d_drawing(sbScn.GetDrawing(), tfm, false, elem_counter, buf);
        if (!buf.empty()) {
            add_mesh_node(parent_node, buf.to_mesh(mats), Transform3D());
        }
    }

    const YsListItem<YsScenery> *childScn = nullptr;
    while ((childScn = scn->FindNextChildScenery(childScn)) != nullptr) {
        build_recursive(&childScn->dat, scn_tfm, parent_node, mats, meshes);
    }
}

} // namespace

// The world beyond the map: a flat ring at y = 0 from the edge of the map's box out past the draw distance,
// in the map's dominant colour (island maps: the sea) with the map's own shader (lighting, water, cloud
// shadows), so the edge doesn't show. No infinite plane: one at y = 0 would z-fight with the maps; the ring
// never overlaps them. The depth fog fades it into the horizon haze (world/sky_environment.gd).
static void add_outside_sea(Node3D *root, const AABB &map, const Color &colour, const Materials &mats) {
    const float r = (float)OUTSIDE_SEA_EXTENT_M;
    const float x0 = map.position.x, x1 = map.get_end().x, z0 = map.position.z, z1 = map.get_end().z;
    const Vector3 quads[4][4] = { // around the hole: north / south full width, east / west between them
        {Vector3(-r, 0, -r), Vector3(r, 0, -r), Vector3(r, 0, z0), Vector3(-r, 0, z0)},
        {Vector3(-r, 0, z1), Vector3(r, 0, z1), Vector3(r, 0, r), Vector3(-r, 0, r)},
        {Vector3(-r, 0, z0), Vector3(x0, 0, z0), Vector3(x0, 0, z1), Vector3(-r, 0, z1)},
        {Vector3(x1, 0, z0), Vector3(r, 0, z0), Vector3(r, 0, z1), Vector3(x1, 0, z1)},
    };
    DrawingBuffers buf;
    const Vector3 up(0.0f, 1.0f, 0.0f);
    for (const auto &q : quads) {
        buf.add_triangle(q[0], q[1], q[2], up, colour, colour, colour, Vector2());
        buf.add_triangle(q[0], q[2], q[3], up, colour, colour, colour, Vector2());
    }
    MeshInstance3D *mi = memnew(MeshInstance3D);
    mi->set_name("OutsideSea");
    mi->set_mesh(buf.to_mesh(mats));
    mi->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
    root->add_child(mi);
}

// Adds each map triangle's area to its (quantised) colour.
static void accumulate_colour_areas(const DrawingBuffers &buf, std::unordered_map<uint32_t, double> &area_by_colour) {
    for (int i = 0; i + 2 < buf.tri_v.size(); i += 3) {
        const double area = 0.5 * (double)(buf.tri_v[i + 1] - buf.tri_v[i]).cross(buf.tri_v[i + 2] - buf.tri_v[i]).length();
        const Color c = buf.tri_c[i];
        const uint32_t key = ((uint32_t)(c.r * 63.0f) << 12) | ((uint32_t)(c.g * 63.0f) << 6) | (uint32_t)(c.b * 63.0f);
        area_by_colour[key] += area;
    }
}

Color build_scenery(const FsSimulation *sim, Node3D *root, const Materials &mats, ShellMeshCache &meshes) {
    Color dominant(0.3f, 0.45f, 0.5f);
    if (sim == nullptr || root == nullptr) {
        return dominant;
    }
    const FsField *fsField = sim->GetField();
    if (fsField == nullptr || fsField->GetFieldPtr() == nullptr) {
        return dominant;
    }
    std::unordered_map<uint32_t, double> area_by_colour;
    AABB map_box;
    bool have_map = false;
    const YsScenery *rootScn = fsField->GetFieldPtr();

    YsMatrix4x4 identity;
    identity.Initialize();
    const YsMatrix4x4 field_tfm = child_transform(identity, fsField->GetPosition(), fsField->GetAttitude());
    const YsMatrix4x4 root_scn_tfm = child_transform(field_tfm, rootScn->GetPosition(), rootScn->GetAttitude());

    // Map layers (PC2): one mesh per same-plane group, layer index increasing in YS painter's order.
    const YsScenery::MapDrawingOrder mdo = rootScn->MakeMapDrawingOrder(root_scn_tfm, 0.05);
    for (int grpIdx = 0; grpIdx < mdo.samePlaneMapGroup.GetN(); ++grpIdx) {
        const YsScenery::SamePlaneMapGroup &grp = mdo.samePlaneMapGroup[grpIdx];
        DrawingBuffers buf;
        int elem_counter = 0;
        for (int infoIdx = 0; infoIdx < grp.mapDrawingInfo.GetN(); ++infoIdx) {
            const YsScenery::MapDrawingInfo &mapInfo = grp.mapDrawingInfo[infoIdx];
            if (mapInfo.mapPtr == nullptr) {
                continue;
            }
            const YsMatrix4x4 map_tfm = child_transform(mapInfo.mapOwnerToWorldTfm, mapInfo.mapPtr->GetPosition(),
                                                        mapInfo.mapPtr->GetAttitude());
            append_2d_drawing(mapInfo.mapPtr->GetDrawing(), map_tfm, true, elem_counter, buf);
        }
        // Shift to -N .. -1: later map layers (runways) win over earlier ones (grass), and 3D objects at
        // y = 0 (bias 0: wheels, TER bases, buildings) win over every map layer.
        buf.shift_layers(-(float)(elem_counter + 1));
        accumulate_colour_areas(buf, area_by_colour);
        for (int i = 0; i < buf.tri_v.size(); ++i) {
            map_box = have_map ? map_box.expand(buf.tri_v[i]) : AABB(buf.tri_v[i], Vector3());
            have_map = true;
        }
        if (!buf.empty()) {
            MeshInstance3D *mi = memnew(MeshInstance3D);
            mi->set_name("MapGroup_" + String::num_int64(grpIdx));
            mi->set_mesh(buf.to_mesh(mats));
            root->add_child(mi);
        }
    }

    build_recursive(rootScn, field_tfm, root, mats, meshes);

    double best_area = 0.0;
    for (const auto &kv : area_by_colour) {
        if (kv.second > best_area) {
            best_area = kv.second;
            dominant = Color(((kv.first >> 12) & 63) / 63.0f, ((kv.first >> 6) & 63) / 63.0f, (kv.first & 63) / 63.0f);
        }
    }
    if (have_map) {
        add_outside_sea(root, map_box, dominant, mats);
    }
    UtilityFunctions::print("YSFlight: Built scenery nodes for field successfully.");
    return dominant;
}

} // namespace ysgd
