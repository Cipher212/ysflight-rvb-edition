#include "bridge/aircraft_fx_query.h"

#include <cmath>

#include <godot_cpp/variant/packed_float32_array.hpp>

#include "core/ys_convert.h"
#include "core/ys_headers.h"
#include "sim/airplane_state.h"
#include "sim/motion_interp.h"

using namespace godot;

namespace ysgd {

template <size_t N>
static void append_row(PackedFloat32Array &out, const float (&row)[N]) {
    for (float f : row) {
        out.push_back(f);
    }
}

Dictionary AircraftFxTracker::collect(FsSimulation *sim, const MotionInterp &interp) {
    Dictionary out;
    PackedFloat32Array aircraft, crashes;
    if (sim == nullptr) {
        out["aircraft"] = aircraft;
        out["crashes"] = crashes;
        return out;
    }
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        const unsigned int key = air->SearchKey();
        const bool alive = (air->IsAlive() == YSTRUE);
        if (!alive) {
            const YsVec3 ys_pos = air->GetPosition();
            const double ground_y = sim->GetFieldElevation(ys_pos.x(), ys_pos.z());
            const bool on_ground = (ys_pos.y() - ground_y) < 5.0;
            if (on_ground && crashed_keys.insert(key).second) { // first frame on the ground after dying
                const Vector3 p = ys_to_godot_pos(ys_pos);
                append_row(crashes, {p.x, p.y, p.z, fabs(ground_y) < 1.0 ? 1.0f : 0.0f, (float)air->Prop().GetOutsideRadius()});
            }
            continue; // FSDEAD in the air: destroyed outright (the explosion effect covers it)
        }
        const bool dying = is_dying(air);
        if (!dying) {
            crashed_keys.erase(key); // flying again (respawned object): allow a new crash event
        }
        const Transform3D t = interp.air(air);
        YsVec3 vel = YsOrigin();
        air->Prop().GetVelocity(vel);
        const Vector3 v = ys_to_godot_pos(vel);
        const float damage = damage_fraction(air);
        YsVec3 vap_ys = YsOrigin();
        air->Prop().GetVaporPosition(vap_ys);
        const Vector3 vap = ys_to_godot_pos(vap_ys);
        const Vector3 fwd = -t.basis.get_column(2).normalized();
        append_row(aircraft, {(float)key, t.origin.x, t.origin.y, t.origin.z, v.x, v.y, v.z, damage,
                              dying ? 1.0f : 0.0f, (!dying && air->Prop().IsTrailingVapor() == YSTRUE) ? 1.0f : 0.0f,
                              vap.x, vap.y, vap.z, (float)air->Prop().GetOutsideRadius(), fwd.x, fwd.y, fwd.z, 0.0f});
    }
    out["aircraft"] = aircraft;
    out["crashes"] = crashes;
    return out;
}

} // namespace ysgd
