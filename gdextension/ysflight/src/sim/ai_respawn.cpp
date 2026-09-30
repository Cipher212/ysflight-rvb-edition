#include "sim/ai_respawn.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>

#include "core/crashlog.h"
#include "core/ys_headers.h"
#include "sim/ai_setup.h"
#include "sim/flight_setup.h"

using namespace godot;

namespace ysgd {

static bool is_loadout_command(const char *cmd) {
    // Weapons only: fuel comes from the aircraft's .dat (a mission's INITFUEL is for the first sortie).
    return strncmp(cmd, "UNLOADWP", 8) == 0 || strncmp(cmd, "LOADWEPN", 8) == 0 || strncmp(cmd, "INITIGUN", 8) == 0;
}

static const char *died_of_name(FSDIEDOF d) {
    switch (d) {
    case FSDIEDOF_STEEPLANDING: return "STEEPLANDING";
    case FSDIEDOF_LANDINGGEARNOTEXTENDED: return "GEARUP";
    case FSDIEDOF_BADBANKANGLE: return "BADBANK";
    case FSDIEDOF_BADPITCHANGLE: return "BADPITCH";
    case FSDIEDOF_LANDEDOUTOFRUNWAY: return "OFFRUNWAY";
    case FSDIEDOF_OVERRUN: return "OVERRUN";
    case FSDIEDOF_TERRAIN: return "TERRAIN";
    case FSDIEDOF_COLLISION: return "COLLISION";
    case FSDIEDOF_TAILSTRIKE: return "TAILSTRIKE";
    case FSDIEDOF_MISSILE: return "MISSILE";
    case FSDIEDOF_GUN: return "GUN";
    case FSDIEDOF_BOMB: return "BOMB";
    default: return "OTHER";
    }
}

void AiRespawn::reset() {
    deaths_by_cause_.clear();
    deaths_by_task_.clear();
    dead_.clear();
    removed_.clear();
    clock_ = 0.0;
}

void AiRespawn::update(FsWorld *world, FsSimulation *sim, double dt) {
    removed_.clear();
    if (world == nullptr || sim == nullptr) {
        return;
    }
    clock_ += dt;
    const FsAirplane *player = sim->GetPlayerAirplane();

    for (FsAirplane *air = nullptr; (air = sim->FindNextAirplane(air)) != nullptr;) {
        if (air->IsAlive() == YSTRUE || dead_.count(air->SearchKey()) != 0) {
            continue;
        }
        Dead d;
        d.time = clock_;
        const auto *ap = dynamic_cast<const FsRvbTacticalAutopilot *>(air->GetAutopilot());
        d.rvb = (ap != nullptr && air != player);
        d.role = (ap != nullptr ? (int)ap->GetRole() : 0);
        d.iff = (int)air->iff;
        d.identifier = air->GetIdentifier();
        if (ap != nullptr) {
            ++deaths_by_cause_[died_of_name(air->Prop().GetDiedOf())];
            std::string task = FsRvbTacticalAutopilot::TaskToStr(ap->GetTask());
            if (ap->GetTask() == FsRvbTacticalAutopilot::TASK_LAUNCH || ap->GetTask() == FsRvbTacticalAutopilot::TASK_RTB) {
                task += std::string("/") + FsRvbRecovery::StageToStr(ap->GetRecovery().GetStage());
            }
            ++deaths_by_task_[task];
        }
        for (auto &cmd : air->cmdLog) {
            if (is_loadout_command(cmd)) {
                d.loadout.push_back(cmd.Txt());
            }
        }
        dead_[air->SearchKey()] = d;
    }

    for (auto it = dead_.begin(); it != dead_.end();) {
        Dead &d = it->second;
        if (clock_ - d.time < RESPAWN_DELAY) {
            ++it;
            continue;
        }
        if (d.rvb && enabled_) {
            if (!respawn(world, sim, d)) {
                d.time = clock_ - RESPAWN_DELAY + RETRY_DELAY;  // Everything occupied: try again shortly
                ++it;
                continue;
            }
            d.rvb = false;
            ++n_respawned_;
        }
        FsAirplane *wreck = sim->FindAirplane(it->first);
        if (wreck != nullptr && wreck == sim->GetPlayerAirplane()) {
            ++it;  // The player's own wreck stays until the player respawns
            continue;
        }
        if (wreck != nullptr) {
            sim->DeleteAirplane(wreck);
            removed_.push_back(it->first);
            ++n_removed_;
        }
        it = dead_.erase(it);
    }
}

bool AiRespawn::respawn(FsWorld *world, FsSimulation *sim, const Dead &d) {
    std::vector<std::string> candidates;
    const PackedStringArray stps = start_position_names(world, sim);
    if (!is_rvb_ground_ops()) {
        // Air starts: the map's AI spots ("AI_BLUE_NORTH", "AI_RED_EAST").
        const String team = (d.iff == 0 ? "AI_BLUE" : (d.iff == 3 ? "AI_RED" : "AI_IFF"));
        for (int i = 0; i < stps.size(); ++i) {
            if (stps[i].to_upper().begins_with(team)) {
                candidates.push_back(stps[i].utf8().get_data());
            }
        }
    } else {
        const String tag = String("[IFF") + String::num_int64(d.iff + 1) + "]";
        const bool heli = (world->IsHelicopterTemplate(d.identifier.c_str()) == YSTRUE);
        for (int i = 0; i < stps.size(); ++i) {
            // Carrier decks only on a catapult (the AI launches straight from there).
            const bool deck = stps[i].find("CARRIER") >= 0 && stps[i].find("CATAPULT") < 0;
            // Not on a runway (jets rolling for take-off run into it) or in a hangar (jets hit the wall).
            const String up = stps[i].to_upper();
            const bool avoid = up.find("RUNWAY") >= 0 || up.find("RUWNAY") >= 0 || up.find("_STRIP") >= 0 ||
                               up.find("HANGAR") >= 0;
            if (stps[i].find(tag) >= 0 && (heli || stps[i].find("(HELI ONLY)") < 0) && !deck && !avoid) {
                candidates.push_back(stps[i].utf8().get_data());
            }
        }
    }
    if (candidates.empty()) {
        return false;
    }
    for (size_t i = candidates.size() - 1; i > 0; --i) {  // rand(): follows the benchmark / test seed
        std::swap(candidates[i], candidates[(size_t)rand() % (i + 1)]);
    }

    FsAirplane *air = world->AddAirplane(d.identifier.c_str(), YSFALSE);
    if (air == nullptr) {
        log_line(String("AI respawn: unknown aircraft ") + d.identifier.c_str());
        return false;
    }
    const std::string *spot = nullptr;
    for (const auto &stp : candidates) {
        if (world->SettleAirplane(*air, stp.c_str()) != YSOK) {
            continue;
        }
        bool free = true;
        for (FsAirplane *other = nullptr; (other = sim->FindNextAirplane(other)) != nullptr;) {
            if (other != air && other->IsAlive() == YSTRUE &&
                (other->GetPosition() - air->GetPosition()).GetSquareLength() < FREE_RADIUS * FREE_RADIUS) {
                free = false;
                break;
            }
        }
        if (free) {
            spot = &stp;
            break;
        }
    }
    if (spot == nullptr) {
        sim->DeleteAirplane(air);
        return false;
    }

    air->SetIff((FSIFF)d.iff);
    if (!is_rvb_ground_ops()) {
        air->SendCommand("INITSPED 200m/s"); // Luavi's AI_BLUE_EAST says 1502 m/s
        air->SendCommand("CTLLDGEA FALSE");
    } else if (spot->find("CARRIER") != std::string::npos) {
        air->SendCommand("INITSPED 0kt");
    }
    for (const auto &cmd : d.loadout) {
        air->SendCommand(cmd.c_str());
    }
    air->SetAutopilot(FsRvbTacticalAutopilot::Create((FSRVBROLE)d.role));
    log_line(String("AI respawn: ") + d.identifier.c_str() + " at " + spot->c_str());
    return true;
}

} // namespace ysgd
