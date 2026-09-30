#include "bridge/aircraft_fx_query.h"

#include <cmath>

#include <godot_cpp/variant/packed_float32_array.hpp>

#include "core/ys_convert.h"
#include "core/ys_headers.h"
#include "sim/airplane_state.h"
#include "sim/motion_interp.h"

using namespace godot;

namespace ysgd {

static const double IMPACT_MAX_HEIGHT_M = 30.0; // dead this close to the terrain = it hit the ground

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
            // First frame dead: an impact if it happened at the ground (YS FSDEAD is set on terrain collision;
            // a jet destroyed outright in the air also becomes FSDEAD, but high up - its explosion covers it).
            if (crashed_keys.insert(key).second) {
                const YsVec3 ys_pos = air->GetPosition();
                const double ground_y = sim->GetFieldElevation(ys_pos.x(), ys_pos.z());
                if (ys_pos.y() - ground_y < IMPACT_MAX_HEIGHT_M) {
                    // Water from the field's area polygons (on RvB maps flat land is at sea level too)
                    const bool water = sim->GetAreaType(ys_pos) == YSSCNAREA_WATER;
                    const Vector3 p = ys_to_godot_pos(YsVec3(ys_pos.x(), YsGreater(ys_pos.y(), ground_y), ys_pos.z()));
                    append_row(crashes, {p.x, p.y, p.z, water ? 1.0f : 0.0f, (float)air->Prop().GetOutsideRadius()});
                }
            }
            continue;
        }
        crashed_keys.erase(key); // alive (flying or spinning down): its next death is a new event
        const bool dying = is_dying(air);
        const Transform3D t = interp.air(air);
        YsVec3 vel = YsOrigin();
        air->Prop().GetVelocity(vel);
        const Vector3 v = ys_to_godot_pos(vel);
        const float damage = damage_fraction(air);
        YsVec3 vap_ys = YsOrigin();
        air->Prop().GetVaporPosition(vap_ys);
        const Vector3 vap = ys_to_godot_pos(vap_ys);
        const Vector3 fwd = -t.basis.get_column(2).normalized();
        // Burning / smoking point: the DAT smoke generator (exhaust on RvB jets), else the centre
        Vector3 smoke_local;
        if (air->Prop().GetNumSmokeGenerator() > 0) {
            YsVec3 smk;
            air->Prop().GetSmokeGeneratorPosition(smk, 0);
            smoke_local = ys_to_godot_pos(smk);
        }
        const Vector3 smoke = t.xform(smoke_local);
        append_row(aircraft, {(float)key, t.origin.x, t.origin.y, t.origin.z, v.x, v.y, v.z, damage,
                              dying ? 1.0f : 0.0f, (!dying && air->Prop().IsTrailingVapor() == YSTRUE) ? 1.0f : 0.0f,
                              vap.x, vap.y, vap.z, (float)air->Prop().GetOutsideRadius(), fwd.x, fwd.y, fwd.z, 0.0f,
                              smoke.x, smoke.y, smoke.z});
    }
    out["aircraft"] = aircraft;
    out["crashes"] = crashes;
    return out;
}

} // namespace ysgd
