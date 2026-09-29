#include "bridge/audio_bridge.h"

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include "core/ys_convert.h"
#include "core/ys_headers.h"

using namespace godot;

namespace ysgd {

namespace {

template <size_t N>
void append_row(PackedFloat32Array &out, const float (&row)[N]) {
    for (float f : row) {
        out.push_back(f);
    }
}

int launch_sound_kind(FSWEAPONTYPE type) {
    switch (type) {
        case FSWEAPON_AIM9: case FSWEAPON_AIM9X: case FSWEAPON_AIM120: case FSWEAPON_AGM65: return 0;
        case FSWEAPON_ROCKET: return 1;
        case FSWEAPON_BOMB: case FSWEAPON_BOMB250: case FSWEAPON_BOMB500HD: return 2;
        default: return -1; // guns (looped per aircraft), flares, fuel tanks, debris: no launch sound
    }
}

} // namespace

void AudioBridge::reset() {
    initialized = false;
    prev_weapon_code.clear();
    seen_explosions.clear();
}

Dictionary AudioBridge::collect(FsSimulation *sim) {
    Dictionary out;
    if (sim == nullptr) {
        return out;
    }
    const FsSoundBridgeState &bridge = FsSoundGetBridgeState();
    FsAirplane *player = sim->GetPlayerAirplane();

    Dictionary pl;
    pl["key"] = player != nullptr ? (int64_t)player->SearchKey() : (int64_t)-1;
    pl["engine_type"] = (int64_t)bridge.engineType;
    pl["engine_power"] = bridge.enginePower;
    pl["gun"] = (int64_t)(bridge.machineGun != 0 ? 1 : 0);
    pl["alarm"] = (int64_t)bridge.alarm;
    out["player"] = pl;

    PackedInt32Array onetime;
    for (int t = 0; t < FsSoundBridgeState::MAX_ONETIME_TYPES; ++t) {
        const unsigned int n = bridge.oneTimeCount[t] - prev_onetime[t];
        if (initialized) {
            for (unsigned int i = 0; i < n && i < 4; ++i) {
                onetime.push_back(t);
            }
        }
        prev_onetime[t] = bridge.oneTimeCount[t];
    }
    out["onetime"] = onetime;

    PackedFloat32Array aircraft;
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        if (air->IsAlive() != YSTRUE) {
            continue;
        }
        auto &prop = air->Prop();
        YsVec3 vel = YsOrigin();
        prop.GetVelocity(vel);
        double power = prop.GetThrottle();
        double rpm_min, rpm_max; // propellers: YS drives the sound from propeller RPM, as in SimBlastSound
        if (prop.IsJet() != YSTRUE && prop.GetRPMRangeForSoundEffect(rpm_min, rpm_max, 0) == YSOK && rpm_max - rpm_min > YsTolerance) {
            power = YsBound((prop.GetRealPropRPM(0) - rpm_min) / (rpm_max - rpm_min), 0.0, 1.0);
        }
        const int kind = prop.IsJet() == YSTRUE ? (prop.GetAfterBurner() == YSTRUE ? 1 : 0) : 2;
        const Vector3 p = ys_to_godot_pos(air->GetPosition());
        const Vector3 v = ys_to_godot_pos(vel);
        append_row(aircraft, {(float)air->SearchKey(), p.x, p.y, p.z, v.x, v.y, v.z, (float)kind, (float)power,
                              prop.IsFiringGun() == YSTRUE ? 1.0f : 0.0f, air == player ? 1.0f : 0.0f});
    }
    out["aircraft"] = aircraft;

    // Launches: a weapon slot that is active now but was empty (or held another type) last frame.
    PackedFloat32Array launches;
    std::vector<int16_t> cur_code(prev_weapon_code.size(), 0);
    const FsWeapon *base = sim->GetWeaponStore().buf;
    const FsWeapon *wpn = nullptr;
    while ((wpn = sim->FindNextActiveWeapon(wpn)) != nullptr) {
        const size_t slot = (size_t)(wpn - base);
        if (slot >= cur_code.size()) {
            cur_code.resize(slot + 1, 0);
        }
        const int16_t code = (int16_t)((int)wpn->type + 1);
        cur_code[slot] = code;
        const int16_t prev = slot < prev_weapon_code.size() ? prev_weapon_code[slot] : 0;
        if (!initialized || prev == code || wpn->lifeRemain <= 0.0) {
            continue;
        }
        const int kind = launch_sound_kind(wpn->type);
        if (kind < 0) {
            continue;
        }
        const Vector3 p = ys_to_godot_pos(wpn->pos);
        append_row(launches, {(float)kind, p.x, p.y, p.z,
                              wpn->firedBy != nullptr ? (float)wpn->firedBy->SearchKey() : -1.0f, (float)wpn->type});
    }
    prev_weapon_code.swap(cur_code);
    out["launches"] = launches;

    // Explosions that started since the last call.
    PackedFloat32Array explosions;
    std::unordered_set<int64_t> current;
    const FsExplosionHolder &holder = sim->GetExplosionStore();
    for (const FsExplosion *exp = holder.activeList; exp != nullptr; exp = exp->next) {
        const int64_t uid = ((int64_t)(exp - holder.buf) << 32) | (int64_t)((uint32_t)exp->random);
        current.insert(uid);
        if (!initialized || seen_explosions.count(uid) != 0) {
            continue;
        }
        const Vector3 p = ys_to_godot_pos(exp->pos);
        append_row(explosions, {p.x, p.y, p.z, (float)YsGreater(exp->iniRadius, exp->radius), (float)exp->expType});
    }
    seen_explosions.swap(current);
    out["explosions"] = explosions;

    initialized = true;
    return out;
}

} // namespace ysgd
