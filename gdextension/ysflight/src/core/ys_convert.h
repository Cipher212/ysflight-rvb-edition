#ifndef YSGD_YS_CONVERT_H
#define YSGD_YS_CONVERT_H

// YSFlight (left-handed, +Z forward) <-> Godot (right-handed, -Z forward) conversions.
// Reflection S = diag(1, 1, -1): positions/normals flip Z, matrices become S * M * S.

#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "ysclass.h"

namespace ysgd {

inline godot::Vector3 ys_to_godot_pos(const YsVec3 &v) {
    return godot::Vector3((real_t)v.x(), (real_t)v.y(), (real_t)-v.z());
}

inline YsVec3 godot_to_ys_pos(const godot::Vector3 &v) {
    return YsVec3(v.x, v.y, -v.z);
}

inline godot::Vector3 ys_to_godot_normal(const YsVec3 &n) {
    godot::Vector3 gn((real_t)n.x(), (real_t)n.y(), (real_t)-n.z());
    if (gn.length_squared() > 1e-12f) {
        return gn.normalized();
    }
    return godot::Vector3(0.0f, 1.0f, 0.0f);
}

inline godot::Color ys_to_godot_color(const YsColor &c) {
    return godot::Color((float)c.Rd(), (float)c.Gd(), (float)c.Bd(), (float)c.Ad());
}

inline godot::Transform3D ys_matrix_to_godot_transform(const YsMatrix4x4 &m) {
    const godot::Basis basis(
        (real_t) m.v(1, 1), (real_t) m.v(1, 2), (real_t)-m.v(1, 3),
        (real_t) m.v(2, 1), (real_t) m.v(2, 2), (real_t)-m.v(2, 3),
        (real_t)-m.v(3, 1), (real_t)-m.v(3, 2), (real_t) m.v(3, 3));
    const godot::Vector3 origin((real_t)m.v(1, 4), (real_t)m.v(2, 4), (real_t)-m.v(3, 4));
    return godot::Transform3D(basis, origin);
}

// YS applies heading, then pitch, then bank (RotateXZ, RotateZY, RotateXY).
inline void ys_apply_attitude(YsMatrix4x4 &m, const YsAtt3 &att) {
    m.RotateXZ(att.h());
    m.RotateZY(att.p());
    m.RotateXY(att.b());
}

inline godot::Transform3D ys_to_godot_transform(const YsVec3 &pos, const YsAtt3 &att) {
    YsMatrix4x4 m;
    m.Initialize();
    m.Translate(pos);
    ys_apply_attitude(m, att);
    return ys_matrix_to_godot_transform(m);
}

} // namespace ysgd

#endif // YSGD_YS_CONVERT_H
