#include "bridge/radar_query.h"

#include <cmath>

#include <godot_cpp/variant/packed_float32_array.hpp>

#include "core/ys_headers.h"
#include "sim/motion_interp.h"

using namespace godot;

namespace ysgd {

static const double RADAR_CONE_DEG = 60.0;

template <size_t N>
static void append_row(PackedFloat32Array &out, const float (&row)[N]) {
    for (float f : row) {
        out.push_back(f);
    }
}

static bool is_guided_missile(FSWEAPONTYPE t) {
    return t == FSWEAPON_AIM9 || t == FSWEAPON_AIM9X || t == FSWEAPON_AIM120 || t == FSWEAPON_AGM65;
}

Dictionary radar_contacts(FsSimulation *sim, const MotionInterp &interp, double range_m, int mode) {
    Dictionary out;
    PackedFloat32Array contacts, ground, missiles;
    FsAirplane *player = sim != nullptr ? sim->GetPlayerAirplane() : nullptr;
    if (player == nullptr || player->IsAlive() != YSTRUE) {
        out["contacts"] = contacts;
        out["ground"] = ground;
        out["missiles"] = missiles;
        return out;
    }
    const Transform3D pt = interp.air(player);
    Vector3 fwd = -pt.basis.get_column(2);
    fwd.y = 0.0f;
    if (fwd.length_squared() < 1e-6f) {
        fwd = -pt.basis.get_column(1); // pointing straight up/down: the aircraft's up vector gives the heading
        fwd.y = 0.0f;
    }
    fwd = fwd.normalized();
    const Vector3 right = fwd.cross(Vector3(0, 1, 0));
    const Vector3 nose = -pt.basis.get_column(2);
    const double range2 = range_m * range_m;
    const double cone_cos = cos(RADAR_CONE_DEG * YsPi / 180.0);
    const unsigned int air_tgt = player->Prop().GetAirTargetKey();
    const unsigned int gnd_tgt = player->Prop().GetGroundTargetKey();

    auto visible = [&](const Vector3 &d) -> bool {
        if ((double)d.length_squared() > range2) {
            return false;
        }
        if (mode == 1) {
            const float len = d.length();
            return len < 1.0f || (double)(nose.dot(d / len)) >= cone_cos;
        }
        return true;
    };

    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        if (air == player || air->IsAlive() != YSTRUE) {
            continue;
        }
        const Transform3D t = interp.air(air);
        const Vector3 d = t.origin - pt.origin;
        if (!visible(d)) {
            continue;
        }
        const Vector3 cf = -t.basis.get_column(2);
        YsVec3 vel = YsOrigin();
        air->Prop().GetVelocity(vel);
        append_row(contacts, {(float)air->SearchKey(), d.dot(right), d.dot(fwd), d.y, atan2f(cf.dot(right), cf.dot(fwd)),
                              (float)air->GetIff(), air->SearchKey() == air_tgt ? 1.0f : 0.0f, (float)vel.GetLength()});
    }

    FsGround *gnd = nullptr;
    while ((gnd = sim->FindNextGround(gnd)) != nullptr) {
        if (gnd->IsAlive() != YSTRUE || gnd->Prop().IsNonGameObject() == YSTRUE) {
            continue;
        }
        const Vector3 d = interp.gnd(gnd).origin - pt.origin;
        if (!visible(d)) {
            continue;
        }
        append_row(ground, {(float)gnd->SearchKey(), d.dot(right), d.dot(fwd), d.y, (float)gnd->GetIff(),
                            gnd->SearchKey() == gnd_tgt ? 1.0f : 0.0f});
    }

    const FsWeapon *wpn = nullptr;
    while ((wpn = sim->FindNextActiveWeapon(wpn)) != nullptr) {
        if (wpn->lifeRemain <= 0.0 || !is_guided_missile(wpn->type)) {
            continue;
        }
        const Vector3 d = interp.wpn(wpn).origin - pt.origin;
        if ((double)d.length_squared() > range2) {
            continue; // shown regardless of mode (the missile warning is a separate sensor)
        }
        const float flags = (wpn->target == player ? 1.0f : 0.0f) + (wpn->firedBy == player ? 2.0f : 0.0f);
        append_row(missiles, {d.dot(right), d.dot(fwd), d.y, flags, (float)wpn->type});
    }

    out["contacts"] = contacts;
    out["ground"] = ground;
    out["missiles"] = missiles;
    return out;
}

} // namespace ysgd
