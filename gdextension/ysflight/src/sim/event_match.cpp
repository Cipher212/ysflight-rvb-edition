#include "sim/event_match.h"

#include <algorithm>

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include "core/crashlog.h"
#include "core/ys_headers.h"
#include "sim/ai_respawn.h"

using namespace godot;

namespace ysgd {

namespace {

const char *CLASS_NAMES[] = {"gun", "aam", "agm", "bomb", "rocket"};

int team_iff(const String &team) { return team.to_lower() == "red" ? 3 : 0; }
const char *team_name(int iff) { return iff == 3 ? "red" : "blue"; }

// RvB rule: leaving the jet is legal only when landed and stopped; otherwise it is scored as a death
bool parked(const FsAirplane *air) {
    return air->Prop().IsOnGround() == YSTRUE && air->Prop().GetVelocity() < EventMatch::PARKED_SPEED;
}

} // namespace

EventMatch::WeaponClass EventMatch::class_of(int weapon_type) {
    switch ((FSWEAPONTYPE)weapon_type) {
    case FSWEAPON_GUN: return GUN;
    case FSWEAPON_AIM9:
    case FSWEAPON_AIM9X:
    case FSWEAPON_AIM120: return AAM;
    case FSWEAPON_AGM65: return AGM;
    case FSWEAPON_ROCKET: return ROCKET;
    default: return BOMB; // BOMB, BOMB250, BOMB500HD
    }
}

Array EventMatch::aircraft_catalog(FsWorld *world) {
    Array out;
    if (world == nullptr) {
        return out;
    }
    for (int i = 0;; ++i) {
        const char *n = world->GetAirplaneTemplateName(i);
        if (n == nullptr) {
            break;
        }
        const String id(n);
        const String up = id.to_upper();
        const bool blue = up.contains("BLUE"), red = up.contains("RED");
        const FSRVBROLE role = FsRvbRoleTable::GetRole(n);
        if (blue == red || role == FSRVBROLE_NONE) {
            continue; // not an RvB team aircraft, or no tactical AI for it (helicopters)
        }
        Dictionary d;
        d["identifier"] = id;
        d["team"] = blue ? "blue" : "red";
        d["role"] = String(FsRvbRoleToStr(role));
        out.push_back(d);
    }
    return out;
}

void EventMatch::reset() {
    if (FsWeaponHolder::eventObserver == this) {
        FsWeaponHolder::eventObserver = nullptr;
    }
    FsWeaponHolder::friendlyFire = YSTRUE;
    pilots_.clear();
    key_to_pilot_.clear();
    shots_.clear();
    kills_.clear();
    config_ = Dictionary();
    clock_ = duration_ = 0.0;
    player_pilot_ = -1;
    player_parked_ = false;
    active_ = ended_ = false;
}

bool EventMatch::begin(FsWorld *world, FsSimulation *sim, const Dictionary &config) {
    reset();
    if (world == nullptr || sim == nullptr) {
        return false;
    }
    config_ = config.duplicate(true);
    const int minutes = std::clamp((int)config.get("duration_min", 20), MIN_MINUTES, MAX_MINUTES);
    duration_ = minutes * 60.0;

    Pilot you;
    you.name = String(config.get("player_name", "PLAYER")).utf8().get_data();
    you.iff = team_iff(config.get("player_team", "blue"));
    you.player = true;
    pilots_.push_back(you);
    player_pilot_ = 0;

    int per_side[2] = {0, 0};
    const Array roster = config.get("pilots", Array());
    for (int i = 0; i < roster.size(); ++i) {
        const Dictionary p = roster[i];
        Pilot ai;
        ai.name = String(p.get("name", "AI")).utf8().get_data();
        ai.identifier = String(p.get("aircraft", "")).utf8().get_data();
        ai.iff = team_iff(p.get("team", "blue"));
        ai.role = (int)FsRvbRoleTable::GetRole(ai.identifier.c_str());
        int &n = per_side[ai.iff == 3 ? 1 : 0];
        if (ai.identifier.empty() || ai.role == FSRVBROLE_NONE || n >= MAX_PER_SIDE) {
            log_line(String("Event: skipped pilot ") + ai.name.c_str() + " (" + ai.identifier.c_str() + ")");
            continue;
        }
        ++n;
        pilots_.push_back(ai);
    }

    const Dictionary rules = config.get("rules", Dictionary());
    sim->SetMidAirCollision(bool(rules.get("collisions", true)) ? YSTRUE : YSFALSE);
    FsWeaponHolder::friendlyFire = bool(rules.get("friendly_fire", false)) ? YSTRUE : YSFALSE;
    FsWeaponHolder::eventObserver = this;
    active_ = true;
    log_line(String("Event: ") + String::num_int64(per_side[0]) + " blue AI, " + String::num_int64(per_side[1]) +
             " red AI, " + String::num_int64(minutes) + " min");
    return true;
}

int EventMatch::pilot_of(unsigned int key) const {
    auto it = key_to_pilot_.find(key);
    return it != key_to_pilot_.end() ? it->second : -1;
}

void EventMatch::bind(int pilot, unsigned int key) {
    Pilot &p = pilots_[pilot];
    if (p.key != 0) {
        key_to_pilot_.erase(p.key);
    }
    p.key = key;
    p.alive = true;
    p.weapon_kill = false;
    key_to_pilot_[key] = pilot;
}

void EventMatch::track_player(FsSimulation *sim) {
    const FsAirplane *air = sim->GetPlayerAirplane();
    if (air != nullptr && air->IsAlive() == YSTRUE && pilot_of(air->SearchKey()) < 0) {
        bind(player_pilot_, air->SearchKey());
        pilots_[player_pilot_].identifier = air->GetIdentifier();
        pilots_[player_pilot_].iff = (int)air->iff;
        pilots_[player_pilot_].role = (int)FsRvbRoleTable::GetRole(air->GetIdentifier());
    }
}

void EventMatch::spawn_ai(FsWorld *world, FsSimulation *sim) {
    int spawned = 0;
    for (size_t i = 0; i < pilots_.size() && spawned < SPAWNS_PER_TICK; ++i) {
        Pilot &p = pilots_[i];
        if (p.player || p.alive || clock_ - p.dead_since < RESPAWN_DELAY) {
            continue;
        }
        FsAirplane *air = spawn_ai_in_air(world, sim, p.identifier, p.iff, p.role, {});
        if (air == nullptr) {
            continue; // every team spot occupied this tick: try again next tick
        }
        bind((int)i, air->SearchKey());
        ++spawned;
    }
}

void EventMatch::check_deaths(FsSimulation *sim) {
    for (size_t i = 0; i < pilots_.size(); ++i) {
        Pilot &p = pilots_[i];
        if (!p.alive) {
            continue;
        }
        const FsAirplane *air = sim->FindAirplane(p.key);
        // IsActive, not IsAlive: a shot-down jet spinning to the ground is already a death
        if (air != nullptr && air->IsActive() == YSTRUE) {
            continue;
        }
        p.alive = false;
        p.dead_since = clock_;
        ++p.deaths;
        if (!p.weapon_kill) {
            ++p.crashes;
            Kill k;
            k.time = clock_;
            k.victim = (int)i;
            k.victim_name = p.name;
            k.how = (air != nullptr && air->Prop().GetDiedOf() == FSDIEDOF_COLLISION) ? "COLLISION" : "CRASH";
            kills_.push_back(k);
        }
    }
}

void EventMatch::update(FsWorld *world, FsSimulation *sim, double dt) {
    if (!active_ || world == nullptr || sim == nullptr) {
        return;
    }
    if (!ended_) {
        clock_ += dt;
        if (clock_ >= duration_) {
            ended_ = true;
            log_line("Event: time is up");
        }
    }
    track_player(sim);
    check_deaths(sim);
    const FsAirplane *you = sim->GetPlayerAirplane();
    player_parked_ = you != nullptr && parked(you);
    if (!ended_) {
        spawn_ai(world, sim);
    }
}

unsigned int EventMatch::leave_player_jet(FsSimulation *sim) {
    if (sim == nullptr || sim->GetPlayerAirplane() == nullptr) {
        return 0;
    }
    FsAirplane *air = sim->GetPlayerAirplane();
    const unsigned int key = air->SearchKey();
    const int pilot = pilot_of(key);
    if (pilot >= 0) {
        Pilot &p = pilots_[pilot];
        if (p.alive && !ended_ && !parked(air)) {
            ++p.deaths;
            ++p.leaves;
            Kill k;
            k.time = clock_;
            k.victim = pilot;
            k.victim_name = p.name;
            k.how = "LEFT JET";
            kills_.push_back(k);
        }
        key_to_pilot_.erase(key);
        p.key = 0;
        p.alive = false;
        p.dead_since = clock_;
    }
    sim->SetPlayerAirplane(nullptr);
    sim->DeleteAirplane(air);
    return key;
}

void EventMatch::OnWeaponFired(const FsWeapon &wpn) {
    Shot s;
    s.pilot = wpn.firedBy != nullptr ? pilot_of(wpn.firedBy->SearchKey()) : -1;
    s.cls = class_of((int)wpn.type);
    shots_[&wpn] = s;
    if (s.pilot >= 0 && !ended_) {
        ++pilots_[s.pilot].fired[s.cls];
    }
}

void EventMatch::OnWeaponDamage(const FsWeapon &wpn, const FsExistence &victim, int /*power*/, YSBOOL killed) {
    if (ended_) {
        return;
    }
    auto sit = shots_.find(&wpn);
    int killer = -1;
    WeaponClass cls = class_of((int)wpn.type);
    if (sit != shots_.end()) {
        killer = sit->second.pilot;
        if (!sit->second.hit && killer >= 0) {
            sit->second.hit = true; // a bomb hitting three targets is one hit
            ++pilots_[killer].hits[cls];
        }
    } else if (wpn.firedBy != nullptr) {
        killer = pilot_of(wpn.firedBy->SearchKey());
    }
    if (killed != YSTRUE) {
        return;
    }
    Kill k;
    k.time = clock_;
    k.killer = killer;
    k.how = CLASS_NAMES[cls];
    const int killer_iff = wpn.firedBy != nullptr ? (int)wpn.firedBy->iff : -1;
    k.killer_iff = killer_iff;
    if (killer < 0 && wpn.firedBy != nullptr) {
        k.killer_name = wpn.firedBy->GetIdentifier(); // SAM / AAA site or ship
    }
    k.team_kill = (killer_iff == (int)victim.iff);
    if (victim.GetType() == FSEX_AIRPLANE) {
        k.victim = pilot_of(victim.SearchKey());
        k.victim_name = k.victim >= 0 ? pilots_[k.victim].name : victim.GetIdentifier();
        if (k.victim >= 0) {
            pilots_[k.victim].weapon_kill = true;
        }
        if (killer >= 0) {
            ++(k.team_kill ? pilots_[killer].team_kills : pilots_[killer].air_kills);
        }
    } else {
        k.ground = true;
        k.victim_name = victim.GetIdentifier();
        if (killer >= 0 && !k.team_kill) {
            ++pilots_[killer].ground_kills;
        }
    }
    kills_.push_back(k);
}

Dictionary EventMatch::state() const {
    Dictionary d;
    d["active"] = active_;
    if (!active_) {
        return d;
    }
    d["time_left"] = std::max(duration_ - clock_, 0.0);
    d["elapsed"] = clock_;
    d["ended"] = ended_;
    int kills[2] = {0, 0};
    for (const Pilot &p : pilots_) {
        kills[p.iff == 3 ? 1 : 0] += p.air_kills + p.ground_kills;
    }
    d["blue_kills"] = kills[0];
    d["red_kills"] = kills[1];
    if (player_pilot_ >= 0) {
        const Pilot &you = pilots_[player_pilot_];
        d["player_team"] = team_name(you.iff);
        d["player_in_jet"] = you.alive;
        d["player_kills"] = you.air_kills + you.ground_kills;
        d["player_deaths"] = you.deaths;
        d["player_parked"] = you.alive && player_parked_;
    }
    return d;
}

Dictionary EventMatch::results() const {
    Dictionary d;
    d["config"] = config_;
    d["elapsed"] = clock_;
    Array pilots;
    for (const Pilot &p : pilots_) {
        Dictionary e;
        e["name"] = String(p.name.c_str());
        e["team"] = team_name(p.iff);
        e["aircraft"] = String(p.identifier.c_str());
        e["role"] = String(FsRvbRoleToStr((FSRVBROLE)p.role));
        e["player"] = p.player;
        e["air_kills"] = p.air_kills;
        e["ground_kills"] = p.ground_kills;
        e["team_kills"] = p.team_kills;
        e["deaths"] = p.deaths;
        e["crashes"] = p.crashes;
        e["leaves"] = p.leaves;
        Dictionary fired, hits;
        for (int c = 0; c < CLASS_COUNT; ++c) {
            fired[CLASS_NAMES[c]] = p.fired[c];
            hits[CLASS_NAMES[c]] = p.hits[c];
        }
        e["fired"] = fired;
        e["hits"] = hits;
        pilots.push_back(e);
    }
    d["pilots"] = pilots;
    Array log;
    for (const Kill &k : kills_) {
        Dictionary e;
        e["time"] = k.time;
        e["killer"] = k.killer >= 0 ? String(pilots_[k.killer].name.c_str()) : String(k.killer_name.c_str());
        e["killer_team"] = k.killer_iff >= 0 ? String(team_name(k.killer_iff)) : String();
        e["killer_is_pilot"] = k.killer >= 0;
        e["victim"] = String(k.victim_name.c_str());
        e["victim_team"] = k.victim >= 0 ? String(team_name(pilots_[k.victim].iff)) : String();
        e["how"] = String(k.how.c_str());
        e["ground"] = k.ground;
        e["team_kill"] = k.team_kill;
        log.push_back(e);
    }
    d["kills"] = log;
    return d;
}

} // namespace ysgd
