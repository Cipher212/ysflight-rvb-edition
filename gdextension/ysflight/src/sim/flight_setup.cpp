#include "sim/flight_setup.h"

#include "core/crashlog.h"
#include "core/ys_headers.h"

using namespace godot;

namespace ysgd {

PackedStringArray airplane_template_names(FsWorld *world) {
    PackedStringArray names;
    if (world == nullptr) {
        return names;
    }
    for (int i = 0;; ++i) {
        const char *n = world->GetAirplaneTemplateName(i);
        if (n == nullptr) {
            break;
        }
        names.push_back(String(n));
    }
    return names;
}

PackedStringArray start_position_names(FsWorld *world, FsSimulation *sim) {
    PackedStringArray names;
    if (world == nullptr || sim == nullptr || sim->GetField() == nullptr) {
        return names;
    }
    const char *field_name = sim->GetField()->GetIdName();
    YsString stp;
    for (int i = 0; world->GetFieldStartPositionName(stp, field_name, i) == YSOK; ++i) {
        names.push_back(String(stp.Txt()));
    }
    return names;
}

bool is_helicopter_template(FsWorld *world, const String &airplane_name) {
    return world != nullptr && world->IsHelicopterTemplate(airplane_name.utf8().get_data()) == YSTRUE;
}

bool respawn_player(FsWorld *world, FsSimulation *sim, const String &airplane_name, const String &start_position, int64_t iff) {
    if (world == nullptr || sim == nullptr) {
        return false;
    }
    FsAirplane *air = world->AddAirplane(airplane_name.utf8().get_data(), YSTRUE);
    if (air == nullptr) {
        log_line(String("respawn_player: unknown aircraft ") + airplane_name);
        return false;
    }
    if (world->SettleAirplane(*air, start_position.utf8().get_data()) != YSOK) {
        log_line(String("respawn_player: unknown start position ") + start_position);
    }
    air->SetIff((FSIFF)iff);
    if (start_position.find("CARRIER") >= 0) {
        air->SendCommand("INITSPED 0kt");
    } else if (start_position.to_upper().begins_with("AI_")) { // the map's air-start spots (AI respawns use them)
        air->SendCommand("INITSPED 200m/s");                  // Luavi's AI_BLUE_EAST says 1502 m/s
        air->SendCommand("CTLLDGEA FALSE");
    }
    sim->SetPlayerAirplane(air);
    log_line(String("respawn_player: ") + airplane_name + " at " + start_position + " IFF" + String::num_int64(iff + 1));
    return true;
}

bool apply_player_loadout(FsSimulation *sim, const String &preset) {
    FsAirplane *air = sim != nullptr ? sim->GetPlayerAirplane() : nullptr;
    if (air == nullptr || preset == "DEFAULT") {
        return air != nullptr;
    }
    YsArray<int, 64> loading;
    air->Prop().GetWeaponConfig(loading);
    YsArray<int, 64> keep;
    for (YSSIZE_T i = 0; i + 1 < loading.GetN(); i += 2) {
        const FSWEAPONTYPE t = (FSWEAPONTYPE)loading[i];
        const bool aam = (t == FSWEAPON_AIM9 || t == FSWEAPON_AIM9X || t == FSWEAPON_AIM120);
        const bool ground = (t == FSWEAPON_AGM65 || t == FSWEAPON_BOMB || t == FSWEAPON_BOMB250 ||
                             t == FSWEAPON_BOMB500HD || t == FSWEAPON_ROCKET);
        bool ok = true;
        if (preset == "AIR-TO-AIR") {
            ok = !ground;
        } else if (preset == "STRIKE") {
            ok = (t != FSWEAPON_AIM120);
        } else if (preset == "GUNS ONLY") {
            ok = !aam && !ground;
        }
        if (ok) {
            keep.Append(loading[i]);
            keep.Append(loading[i + 1]);
        }
    }
    air->SendCommand("UNLOADWP");
    air->AutoSendCommand(keep.GetN(), keep);
    log_line(String("Player loadout: ") + preset);
    return true;
}

void kill_player(FsSimulation *sim) {
    if (sim != nullptr && sim->GetPlayerAirplane() != nullptr) {
        // YS GetDamage picks FSDEAD / FSDEADSPIN / FSDEADFLATSPIN; the spin is the common case
        sim->GetPlayerAirplane()->Prop().SetFlightState(FSDEADSPIN, FSDIEDOF_NULL);
    }
}

void kill_airplane(FsSimulation *sim, int64_t search_key) {
    if (sim != nullptr) {
        FsAirplane *air = sim->FindAirplane((YSHASHKEY)search_key);
        if (air != nullptr) {
            air->Prop().SetFlightState(FSDEAD, FSDIEDOF_MISSILE);
        }
    }
}

bool enable_player_autopilot(FsSimulation *sim) {
    if (sim == nullptr || sim->GetPlayerAirplane() == nullptr) {
        return false;
    }
    FsAirplane *player = sim->GetPlayerAirplane();
    const FSRVBROLE role = FsRvbRoleTable::GetRole(player->GetIdentifier());
    if (FsRvbTacticalAutopilot::enabled == YSTRUE && role != FSRVBROLE_NONE) {
        player->SetAutopilot(FsRvbTacticalAutopilot::Create(role));
        log_line(String("Player aircraft handed to the RvB tactical AI (") + FsRvbRoleToStr(role) + ").");
        return true;
    }
    FsDogfight *df = FsDogfight::Create();
    df->gLimit = 9.0;
    df->minAlt = 300.0;
    player->SetAutopilot(df);
    log_line("Player aircraft handed to the FsDogfight autopilot.");
    return true;
}

} // namespace ysgd
