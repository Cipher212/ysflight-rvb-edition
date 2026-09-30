#include "sim/sim_queries.h"

#include <cmath>

#include "core/ys_convert.h"
#include "core/ys_headers.h"
#include "sim/motion_interp.h"

using namespace godot;

namespace ysgd {

namespace {

constexpr double MS_TO_KT = 1.94384449;
constexpr double M_TO_FT = 3.2808399;
constexpr double NM_TO_M = 1852.0;

void fill_ground_state(Dictionary &state, FsGround *gnd, const MotionInterp &interp) {
    const Transform3D t = interp.gnd(gnd);
    state["pos"] = t.origin;
    state["transform"] = t;
    state["is_alive"] = (gnd->IsAlive() == YSTRUE);
    state["iff"] = (int64_t)gnd->GetIff();
    state["identifier"] = String(gnd->GetIdentifier());
    state["name"] = String(gnd->GetName());
}

void fill_weapon_telemetry(Dictionary &dict, FsAirplane *player) {
    auto &prop = player->Prop();
    const FSWEAPONTYPE woc = prop.GetWeaponOfChoice();
    const char *woc_str = FsGetWeaponString(woc);
    dict["weapon_type"] = (int64_t)woc;
    dict["weapon_name"] = String(woc_str != nullptr ? woc_str : "NONE");
    dict["ammo_count"] = (int64_t)prop.GetNumWeapon(woc);
    dict["gun_ammo"] = (int64_t)prop.GetNumWeapon(FSWEAPON_GUN);
    dict["flare_count"] = (int64_t)prop.GetNumWeapon(FSWEAPON_FLARE);
    dict["aim9_count"] = (int64_t)prop.GetNumWeapon(FSWEAPON_AIM9);
    dict["aim9x_count"] = (int64_t)prop.GetNumWeapon(FSWEAPON_AIM9X);
    dict["aim120_count"] = (int64_t)prop.GetNumWeapon(FSWEAPON_AIM120);
    dict["agm65_count"] = (int64_t)prop.GetNumWeapon(FSWEAPON_AGM65);
    dict["bomb_count"] = (int64_t)(prop.GetNumWeapon(FSWEAPON_BOMB) + prop.GetNumWeapon(FSWEAPON_BOMB250) +
                                   prop.GetNumWeapon(FSWEAPON_BOMB500HD));
    dict["rocket_count"] = (int64_t)prop.GetNumWeapon(FSWEAPON_ROCKET);
    const unsigned int air_tgt = prop.GetAirTargetKey();
    const unsigned int gnd_tgt = prop.GetGroundTargetKey();
    dict["locked_air_target_key"] = (air_tgt != YSNULLHASHKEY) ? (int64_t)air_tgt : (int64_t)-1;
    dict["locked_ground_target_key"] = (gnd_tgt != YSNULLHASHKEY) ? (int64_t)gnd_tgt : (int64_t)-1;
    dict["aam_range"] = (double)prop.GetAAMRange(woc);
    dict["agm_range"] = (double)prop.GetAGMRange();
    // YS radar range is in nautical miles (0 = off / inoperative)
    dict["radar_range_nm"] = (double)prop.GetCurrentRadarRange();
    dict["radar_range"] = (double)prop.GetCurrentRadarRange() * NM_TO_M; // metres
}

} // namespace

Dictionary airplane_states(FsSimulation *sim, const MotionInterp &interp) {
    Dictionary out;
    if (sim == nullptr) {
        return out;
    }
    const FsAirplane *player = sim->GetPlayerAirplane();
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        YsVec3 vel = YsOrigin();
        air->Prop().GetVelocity(vel);
        const Transform3D t = interp.air(air);
        Dictionary state;
        state["pos"] = t.origin;
        state["rot"] = t.basis.get_euler();
        state["transform"] = t;
        state["velocity"] = ys_to_godot_pos(vel);
        state["cockpit_local"] = ys_to_godot_pos(air->GetCockpitPosition());
        state["outside_radius"] = (double)air->Prop().GetOutsideRadius();
        state["is_player"] = (air == player);
        state["is_alive"] = (air->IsAlive() == YSTRUE);
        state["iff"] = (int64_t)air->GetIff();
        state["identifier"] = String(air->GetIdentifier());
        state["name"] = String(air->GetName());
        out[(int64_t)air->SearchKey()] = state;
    }
    return out;
}

Dictionary ground_states(FsSimulation *sim, const MotionInterp &interp) {
    Dictionary out;
    if (sim == nullptr) {
        return out;
    }
    FsGround *gnd = nullptr;
    while ((gnd = sim->FindNextGround(gnd)) != nullptr) {
        if (gnd->Prop().IsNonGameObject() == YSTRUE) {
            continue; // static scenery props (trees, clouds, city blocks)
        }
        Dictionary state;
        fill_ground_state(state, gnd, interp);
        state["is_non_game_object"] = false;
        out[(int64_t)gnd->SearchKey()] = state;
    }
    return out;
}

Dictionary ground_state(FsSimulation *sim, const MotionInterp &interp, int64_t key) {
    Dictionary state;
    if (sim == nullptr || key < 0) {
        return state;
    }
    FsGround *gnd = sim->FindGround((YSHASHKEY)key);
    if (gnd != nullptr) {
        fill_ground_state(state, gnd, interp);
    }
    return state;
}

Array active_weapons(FsSimulation *sim, const MotionInterp &interp) {
    Array list;
    if (sim == nullptr) {
        return list;
    }
    const FsWeapon *base = sim->GetWeaponStore().buf;
    const FsWeapon *wpn = nullptr;
    while ((wpn = sim->FindNextActiveWeapon(wpn)) != nullptr) {
        Dictionary d;
        const Transform3D t = interp.wpn(wpn);
        d["slot_id"] = (int64_t)(wpn - base);
        d["type"] = (int64_t)wpn->type;
        d["pos"] = t.origin;
        d["prev_pos"] = t.origin - (ys_to_godot_pos(wpn->pos) - ys_to_godot_pos(wpn->prv)); // keeps the sim segment length
        d["vel"] = ys_to_godot_pos(wpn->vec);
        d["transform"] = t;
        d["life_remain"] = (double)wpn->lifeRemain;
        d["time_remain"] = (double)wpn->timeRemain;
        d["has_trail"] = (wpn->trail != nullptr && wpn->trail->used == YSTRUE);
        list.push_back(d);
    }
    return list;
}

Array active_explosions(FsSimulation *sim) {
    Array list;
    if (sim == nullptr) {
        return list;
    }
    const FsExplosionHolder &holder = sim->GetExplosionStore();
    for (const FsExplosion *exp = holder.activeList; exp != nullptr; exp = exp->next) {
        const int64_t slot_id = (int64_t)(exp - holder.buf);
        Dictionary d;
        d["slot_id"] = slot_id;
        d["uid"] = (slot_id << 32) | (int64_t)((uint32_t)exp->random);
        d["exp_type"] = (int64_t)exp->expType;
        d["pos"] = ys_to_godot_pos(exp->pos);
        d["time_passed"] = (double)exp->timePassed;
        d["time_remain"] = (double)exp->timeRemain;
        d["ini_radius"] = (double)exp->iniRadius;
        d["radius"] = (double)exp->radius;
        d["flash"] = (exp->flash == YSTRUE);
        list.push_back(d);
    }
    return list;
}

Dictionary player_telemetry(FsSimulation *sim, const MotionInterp &interp) {
    Dictionary dict;
    FsAirplane *player = sim != nullptr ? sim->GetPlayerAirplane() : nullptr;
    if (player == nullptr) {
        return dict;
    }
    auto &prop = player->Prop();
    const double vel_ms = prop.GetVelocity();
    const double alt_m = prop.GetIndicatedTrueAltitude();
    const YsAtt3 att = player->GetAttitude();
    YsVec3 vel_vec = YsOrigin();
    prop.GetVelocity(vel_vec);
    // YS: +Z north, +X east, RotateXZ(h) counter-clockwise -> compass heading = -h wrapped to [0, 360)
    double hdg_deg = std::fmod(-YsRadToDeg(att.h()), 360.0);
    if (hdg_deg < 0.0) {
        hdg_deg += 360.0;
    }
    dict["speed_ms"] = vel_ms;
    dict["speed_kt"] = vel_ms * MS_TO_KT;
    dict["altitude_m"] = alt_m;
    dict["altitude_ft"] = alt_m * M_TO_FT;
    dict["agl_m"] = player->GetPosition().y();
    dict["vsi_fpm"] = prop.GetClimbRatioWithTimeDelay() * M_TO_FT * 60.0;
    dict["throttle"] = prop.GetThrottle();
    dict["afterburner"] = (prop.GetAfterBurner() == YSTRUE);
    dict["mach"] = prop.GetMach();
    dict["g_force"] = prop.GetG();
    dict["heading_deg"] = hdg_deg;
    dict["pitch_deg"] = YsRadToDeg(att.p());
    dict["bank_deg"] = YsRadToDeg(att.b());
    dict["gear"] = prop.GetLandingGear();
    dict["flaps"] = prop.GetFlap();
    dict["brake"] = (prop.GetBrake() == YSTRUE);
    dict["spoiler"] = prop.GetSpoiler();
    const double max_fuel = prop.GetMaxFuelLoad();
    dict["fuel_pct"] = (max_fuel > 1e-6) ? (100.0 * prop.GetFuelLeft() / max_fuel) : 100.0;
    dict["cockpit_local"] = ys_to_godot_pos(player->GetCockpitPosition());
    dict["velocity"] = ys_to_godot_pos(vel_vec);
    dict["outside_radius"] = (double)prop.GetOutsideRadius();
    dict["is_alive"] = (player->IsAlive() == YSTRUE);
    dict["iff"] = (int64_t)player->GetIff();
    dict["identifier"] = String(player->GetIdentifier());
    fill_weapon_telemetry(dict, player);
    dict["is_locked_by_enemy"] = (sim->IsLockedOn(player, YSFALSE) == YSTRUE);
    dict["is_missile_chasing"] = (sim->GetWeaponStore().IsLockedOn(player) == YSTRUE);

    const FsAirplane *gun_target = nullptr;
    YsVec3 gun_aim = YsOrigin();
    if (sim->SimCalculateGunAim(gun_target, gun_aim) == YSOK && gun_target != nullptr) {
        // Shifted by the player's interpolation offset so the pipper stays locked to the drawn cockpit/HUD
        const Vector3 offset = interp.air(player).origin - ys_to_godot_pos(player->GetPosition());
        dict["has_gun_lead"] = true;
        dict["gun_lead_pos"] = ys_to_godot_pos(gun_aim) + offset;
        dict["gun_lead_target_pos"] = ys_to_godot_pos(gun_target->GetPosition()) + offset;
        dict["gun_lead_target_key"] = (int64_t)gun_target->SearchKey();
    } else {
        dict["has_gun_lead"] = false;
    }
    return dict;
}

PackedVector3Array tower_positions(FsSimulation *sim) {
    PackedVector3Array towers;
    if (sim != nullptr) {
        for (int i = 0; i < sim->GetNumTowerView(); ++i) {
            towers.push_back(ys_to_godot_pos(sim->GetTowerView(i)));
        }
    }
    return towers;
}

Color sky_color(FsSimulation *sim) {
    if (sim != nullptr && sim->GetField() != nullptr) {
        YsColor gnd, sky;
        sim->GetField()->GetGroundSkyColor(gnd, sky);
        return ys_to_godot_color(sky);
    }
    return Color(0.4f, 0.6f, 0.9f);
}

} // namespace ysgd
