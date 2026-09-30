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

const char *died_of_name(int died_of) {
    switch ((FSDIEDOF)died_of) {
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

// Shuffles the candidate start positions (rand(): follows the benchmark / test seed) and settles air at the
// first one with no other aircraft within FREE_RADIUS. nullptr if all are occupied.
static const std::string *settle_at_free_spot(FsWorld *world, FsSimulation *sim, FsAirplane *air,
                                              std::vector<std::string> &candidates) {
    for (size_t i = candidates.size(); i > 1; --i) {
        std::swap(candidates[i - 1], candidates[(size_t)rand() % i]);
    }
    for (const auto &stp : candidates) {
        if (world->SettleAirplane(*air, stp.c_str()) != YSOK) {
            continue;
        }
        bool free = true;
        for (FsAirplane *other = nullptr; (other = sim->FindNextAirplane(other)) != nullptr;) {
            if (other != air && other->IsAlive() == YSTRUE &&
                (other->GetPosition() - air->GetPosition()).GetSquareLength() < AiRespawn::FREE_RADIUS * AiRespawn::FREE_RADIUS) {
                free = false;
                break;
            }
        }
        if (free) {
            return &stp;
        }
    }
    return nullptr;
}

FsAirplane *spawn_ai_in_air(FsWorld *world, FsSimulation *sim, const std::string &identifier, int iff, int role,
                            const std::vector<std::string> &loadout) {
    const String team = (iff == 0 ? "AI_BLUE" : (iff == 3 ? "AI_RED" : "AI_IFF"));
    std::vector<std::string> candidates;
    const PackedStringArray stps = start_position_names(world, sim);
    for (int i = 0; i < stps.size(); ++i) {
        const String up = stps[i].to_upper();
        if (up.begins_with(team) && !up.contains("CARRIER")) { // AI_BLUE_CARRIER is a deck: no air start there
            candidates.push_back(stps[i].utf8().get_data());
        }
    }
    if (candidates.empty()) {
        return nullptr;
    }
    FsAirplane *air = world->AddAirplane(identifier.c_str(), YSFALSE);
    if (air == nullptr) {
        log_line(String("AI spawn: unknown aircraft ") + identifier.c_str());
        return nullptr;
    }
    const std::string *spot = settle_at_free_spot(world, sim, air, candidates);
    if (spot == nullptr) {
        sim->DeleteAirplane(air);
        return nullptr;
    }
    air->SetIff((FSIFF)iff);
    air->SendCommand("INITSPED 200m/s"); // Luavi's AI_BLUE_EAST says 1502 m/s
    air->SendCommand("CTLLDGEA FALSE");
    for (const auto &cmd : loadout) {
        air->SendCommand(cmd.c_str());
    }
    air->SetAutopilot(FsRvbTacticalAutopilot::Create((FSRVBROLE)role));
    log_line(String("AI spawn: ") + identifier.c_str() + " at " + spot->c_str());
    return air;
}

bool AiRespawn::respawn(FsWorld *world, FsSimulation *sim, const Dead &d) {
    if (!is_rvb_ground_ops()) {
        return spawn_ai_in_air(world, sim, d.identifier, d.iff, d.role, d.loadout) != nullptr;
    }
    // Archived ground operations: a free team start position on the ground.
    std::vector<std::string> candidates;
    const PackedStringArray stps = start_position_names(world, sim);
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
    if (candidates.empty()) {
        return false;
    }
    FsAirplane *air = world->AddAirplane(d.identifier.c_str(), YSFALSE);
    if (air == nullptr) {
        log_line(String("AI respawn: unknown aircraft ") + d.identifier.c_str());
        return false;
    }
    const std::string *spot = settle_at_free_spot(world, sim, air, candidates);
    if (spot == nullptr) {
        sim->DeleteAirplane(air);
        return false;
    }
    air->SetIff((FSIFF)d.iff);
    if (spot->find("CARRIER") != std::string::npos) {
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
