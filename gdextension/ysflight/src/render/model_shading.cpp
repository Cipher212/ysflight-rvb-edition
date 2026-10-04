#include "render/model_shading.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <vector>

#include <godot_cpp/variant/string.hpp>

#include "core/crashlog.h"
#include "core/ys_headers.h"

using namespace godot;

namespace ysgd {

namespace {

constexpr int GRID_CELLS = 64;              // voxels along the model's longest side
constexpr int RAY_COUNT = 12;               // per hemisphere
constexpr double RAY_MIN_ELEVATION = 0.3;   // no grazing rays (they would hit the vertex's own surface)
constexpr double START_OFFSET_CELLS = 1.5;  // rays start this far off the surface
constexpr double AO_RADIUS_FRACTION = 0.12; // occlusion search radius vs the model's longest side...
constexpr double AO_RADIUS_MIN = 1.0;       // ...clamped (m)
constexpr double AO_RADIUS_MAX = 5.0;
constexpr float AO_STRENGTH = 0.55f;        // brightness lost where fully enclosed
constexpr float MIN_SHADE = 0.5f;
constexpr float BASE_DARK = 0.62f;          // ground: brightness where it meets the ground...
constexpr double BASE_HEIGHT_FRACTION = 0.3;// ...back to full over this fraction of its height, clamped (m)
constexpr double BASE_HEIGHT_MIN = 0.4;
constexpr double BASE_HEIGHT_MAX = 3.0;
constexpr int DNM_CLASS_AFTERBURNER = 2;    // replaced by flames (burner_mesh.h): neither shaded nor occluding

struct Vtx {
    const void *part;
    YSHASHKEY key;
    YsVec3 pos, nom; // model space
};

struct Geometry {
    std::vector<Vtx> verts;
    std::vector<YsVec3> tris; // occluding triangles, model space, 3 per triangle
    YsVec3 lo = YsVec3(1e30, 1e30, 1e30), hi = YsVec3(-1e30, -1e30, -1e30);
};

double dot(const YsVec3 &a, const YsVec3 &b) { return a.x() * b.x() + a.y() * b.y() + a.z() * b.z(); }

YsVec3 cross(const YsVec3 &a, const YsVec3 &b) {
    return YsVec3(a.y() * b.z() - a.z() * b.y(), a.z() * b.x() - a.x() * b.z(), a.x() * b.y() - a.y() * b.x());
}

YsVec3 unit_or_zero(const YsVec3 &v) {
    const double l = std::sqrt(dot(v, v));
    return l > 1e-9 ? v * (1.0 / l) : YsOrigin();
}

float smooth01(double x) {
    const double t = std::min(std::max(x, 0.0), 1.0);
    return (float)(t * t * (3.0 - 2.0 * t));
}

// Adds a shell's vertices (with averaged normals) and, if it occludes, its triangles, in model space.
void add_shell(Geometry &g, const YsShellExt &shl, const YsMatrix4x4 &tfm, const void *part, bool occludes) {
    std::unordered_map<YSHASHKEY, YsVec3> nsum;
    for (auto plHd : shl.AllPolygon()) {
        int nVt = 0;
        const YsShellVertexHandle *vtHd = nullptr;
        shl.GetVertexListOfPolygon(nVt, vtHd, plHd);
        if (nVt < 3) {
            continue;
        }
        YsArray<YsVec3, 16> pts(nVt, nullptr);
        for (int i = 0; i < nVt; ++i) {
            shl.GetVertexPosition(pts[i], vtHd[i]);
        }
        YsVec3 n;
        shl.GetNormal(n, plHd);
        if (n == YsOrigin()) {
            YsGetAverageNormalVector(n, nVt, pts);
        }
        for (int i = 0; i < nVt; ++i) {
            // YS models often have flipped polygon normals: accumulate them facing the same way.
            YsVec3 &s = nsum[shl.GetSearchKey(vtHd[i])];
            s = dot(s, n) < 0.0 ? s - n : s + n;
        }
        if (occludes) {
            YsVec3 p0, pi, pj;
            tfm.Mul(p0, pts[0], 1.0);
            for (int i = 1; i + 1 < nVt; ++i) { // fan; slightly wrong for concave polygons, fine for voxels
                tfm.Mul(pi, pts[i], 1.0);
                tfm.Mul(pj, pts[i + 1], 1.0);
                g.tris.push_back(p0);
                g.tris.push_back(pi);
                g.tris.push_back(pj);
            }
        }
    }
    for (auto vtHd : shl.AllVertex()) {
        YsVec3 local, p, n;
        shl.GetVertexPosition(local, vtHd);
        tfm.Mul(p, local, 1.0);
        const YSHASHKEY key = shl.GetSearchKey(vtHd);
        auto it = nsum.find(key);
        if (it != nsum.end()) {
            tfm.Mul(n, it->second, 0.0);
        } else {
            n = YsYVec();
        }
        g.verts.push_back({part, key, p, unit_or_zero(n)});
        if (occludes) {
            g.lo.Set(std::min(g.lo.x(), p.x()), std::min(g.lo.y(), p.y()), std::min(g.lo.z(), p.z()));
            g.hi.Set(std::max(g.hi.x(), p.x()), std::max(g.hi.y(), p.y()), std::max(g.hi.z(), p.z()));
        }
    }
}

struct Grid {
    YsVec3 org;
    double cell = 1.0;
    int nx = 0, ny = 0, nz = 0;
    std::vector<uint8_t> occ;

    void init(const YsVec3 &lo, const YsVec3 &hi) {
        const YsVec3 ext = hi - lo;
        const double longest = std::max(ext.x(), std::max(ext.y(), ext.z()));
        cell = std::max(longest / GRID_CELLS, 0.05);
        org = lo - YsVec3(cell, cell, cell);
        nx = (int)std::ceil(ext.x() / cell) + 3;
        ny = (int)std::ceil(ext.y() / cell) + 3;
        nz = (int)std::ceil(ext.z() / cell) + 3;
        occ.assign((size_t)nx * ny * nz, 0);
    }
    int index(const YsVec3 &p) const {
        const int ix = (int)std::floor((p.x() - org.x()) / cell);
        const int iy = (int)std::floor((p.y() - org.y()) / cell);
        const int iz = (int)std::floor((p.z() - org.z()) / cell);
        if (ix < 0 || iy < 0 || iz < 0 || ix >= nx || iy >= ny || iz >= nz) {
            return -1;
        }
        return (iz * ny + iy) * nx + ix;
    }
    void mark_triangle(const YsVec3 &a, const YsVec3 &b, const YsVec3 &c) {
        const YsVec3 ab = b - a, ac = c - a, bc = c - b;
        const double longest = std::sqrt(std::max(dot(ab, ab), std::max(dot(ac, ac), dot(bc, bc))));
        const int n = std::min(std::max(1, (int)std::ceil(longest / (0.5 * cell))), 256);
        for (int i = 0; i <= n; ++i) {
            for (int j = 0; i + j <= n; ++j) {
                const int idx = index(a + ab * ((double)i / n) + ac * ((double)j / n));
                if (idx >= 0) {
                    occ[idx] = 1;
                }
            }
        }
    }
    bool occupied(const YsVec3 &p) const {
        const int idx = index(p);
        return idx >= 0 && occ[idx] != 0;
    }
};

// Cosine-weighted directions around +Z (Fibonacci spiral), no grazing ones.
std::vector<YsVec3> ray_directions() {
    std::vector<YsVec3> dirs;
    const double golden = 2.39996322972865332;
    for (int i = 0; i < RAY_COUNT; ++i) {
        const double u = (i + 0.5) / RAY_COUNT;
        const double z = std::max(std::sqrt(1.0 - u), RAY_MIN_ELEVATION);
        const double r = std::sqrt(std::max(0.0, 1.0 - z * z));
        dirs.push_back(YsVec3(r * std::cos(i * golden), r * std::sin(i * golden), z));
    }
    return dirs;
}

// 0 = open, towards 1 = enclosed, looking out of the surface on the side of n.
double occlusion(const Grid &g, const YsVec3 &p, const YsVec3 &n, double radius, const std::vector<YsVec3> &dirs) {
    const YsVec3 t1 = unit_or_zero(std::fabs(n.x()) < 0.9 ? cross(n, YsXVec()) : cross(n, YsYVec()));
    const YsVec3 t2 = cross(n, t1);
    const YsVec3 start = p + n * (g.cell * START_OFFSET_CELLS);
    double sum = 0.0;
    for (const YsVec3 &l : dirs) {
        const YsVec3 d = t1 * l.x() + t2 * l.y() + n * l.z();
        for (double t = 0.0; t < radius; t += g.cell * 0.7) {
            if (g.occupied(start + d * t)) {
                sum += 1.0 - t / radius;
                break;
            }
        }
    }
    return sum / dirs.size();
}

ModelShade shade_ground_geometry(const Geometry &g) {
    ModelShade out;
    if (g.tris.empty() || g.hi.x() < g.lo.x()) {
        return out;
    }
    Grid grid;
    grid.init(g.lo, g.hi);
    for (size_t i = 0; i + 2 < g.tris.size(); i += 3) {
        grid.mark_triangle(g.tris[i], g.tris[i + 1], g.tris[i + 2]);
    }
    const YsVec3 ext = g.hi - g.lo;
    const double longest = std::max(ext.x(), std::max(ext.y(), ext.z()));
    const double radius = std::min(std::max(longest * AO_RADIUS_FRACTION, AO_RADIUS_MIN), AO_RADIUS_MAX);
    const double height = std::max(ext.y(), 1e-3);
    const double base_h = std::min(std::max(height * BASE_HEIGHT_FRACTION, BASE_HEIGHT_MIN), BASE_HEIGHT_MAX);
    const std::vector<YsVec3> dirs = ray_directions();
    for (const Vtx &v : g.verts) {
        float f = 1.0f;
        if (!(v.nom == YsOrigin())) {
            // Thin parts are single polygons and normals are unreliable: take the more open side.
            const double ao = std::min(occlusion(grid, v.pos, v.nom, radius, dirs), occlusion(grid, v.pos, -v.nom, radius, dirs));
            f = 1.0f - AO_STRENGTH * (float)ao;
        }
        const double up = v.pos.y() - g.lo.y();
        f *= BASE_DARK + (1.0f - BASE_DARK) * smooth01(up / base_h);
        out[v.part][v.key] = std::max(f, MIN_SHADE);
    }
    return out;
}

double ms_since(std::chrono::steady_clock::time_point t0) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

} // namespace

ModelShade bake_ground_dnm_shade(FsVisualDnm &vis) {
    const auto t0 = std::chrono::steady_clock::now();
    auto dnm = vis.GetDnmPtr();
    if (dnm == nullptr) {
        return {};
    }
    auto &state = vis.GetDnmState();
    dnm->CacheTransformation(state);
    Geometry g;
    auto nodes = dnm->GetNodePointerAll();
    for (int i = 0; i < (int)nodes.GetN(); ++i) {
        auto *node = nodes[i];
        if (node == nullptr || node->dnmClassType == DNM_CLASS_AFTERBURNER) {
            continue;
        }
        add_shell(g, *node, state.GetNodeToRootTransformation(node), node, state.GetShow(node) == YSTRUE);
    }
    ModelShade out = shade_ground_geometry(g);
    log_line(String("Shading: baked ") + String::num_int64((int64_t)g.verts.size()) + " vertices in " +
             String::num(ms_since(t0), 1) + " ms");
    return out;
}

VertexShade bake_shell_shade(const YsShellExt &shell) {
    Geometry g;
    YsMatrix4x4 identity;
    identity.Initialize();
    add_shell(g, shell, identity, &shell, true);
    ModelShade out = shade_ground_geometry(g);
    auto it = out.find(&shell);
    return it != out.end() ? std::move(it->second) : VertexShade();
}

} // namespace ysgd
