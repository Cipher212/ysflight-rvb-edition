#include "sim/ai_setup.h"

#include <godot_cpp/classes/file_access.hpp>

#include "core/crashlog.h"
#include "core/ys_headers.h"
#include "sim/flight_setup.h"

using namespace godot;

namespace ysgd {

int load_rvb_roles(const String &path) {
    FsRvbRoleTable::Clear();
    if (!FileAccess::file_exists(path)) {
        return 0;
    }
    const PackedStringArray lines = FileAccess::get_file_as_string(path).split("\n");
    int bad = 0;
    for (int i = 0; i < lines.size(); ++i) {
        if (FsRvbRoleTable::AddLine(lines[i].strip_edges().utf8().get_data()) != YSOK) {
            log_line(String("rvb_roles.txt: unknown role on line ") + String::num_int64(i + 1) + ": " + lines[i]);
            ++bad;
        }
    }
    log_line(String("rvb_roles.txt: ") + String::num_int64(FsRvbRoleTable::GetNumEntry()) + " entries, " +
             String::num_int64(bad) + " ignored");
    return FsRvbRoleTable::GetNumEntry();
}

void set_rvb_ai_enabled(bool enabled) { FsRvbTacticalAutopilot::enabled = (enabled ? YSTRUE : YSFALSE); }

bool is_rvb_ai_enabled() { return FsRvbTacticalAutopilot::enabled == YSTRUE; }

void set_rvb_ground_ops(bool enabled) { FsRvbTacticalAutopilot::groundOps = (enabled ? YSTRUE : YSFALSE); }

bool is_rvb_ground_ops() { return FsRvbTacticalAutopilot::groundOps == YSTRUE; }

void reset_rvb_ai() {
    FsRvbTeamPicture::Reset();
    FsRvbMapInfo::ClearStartRunways();
}

int feed_start_runways(FsWorld *world, FsSimulation *sim) {
    int n = 0;
    const PackedStringArray names = start_position_names(world, sim);
    for (int i = 0; i < names.size(); ++i) {
        const String name = names[i].to_upper();
        const int tag = name.find("[IFF");
        const bool runway = name.find("RUNWAY") >= 0 || name.find("RUWNAY") >= 0 || name.find("STRIP") >= 0;
        if (tag < 0 || !runway || name.find("CARRIER") >= 0 || name.find("HELI") >= 0 || name.find("HOLD") >= 0 ||
            name.find("HANGAR") >= 0) {
            continue;
        }
        const int iff = name.substr(tag + 4, 1).to_int() - 1; // [IFF1] -> 0, [IFF4] -> 3
        FsStartPosInfo info;
        YsVec3 pos;
        YsAtt3 att;
        if (iff < 0 || world->GetStartPositionInfo(info, names[i].utf8().get_data()) != YSOK ||
            info.InterpretPosition(pos, att) != YSOK) {
            continue;
        }
        FsRvbMapInfo::AddStartRunway(names[i].utf8().get_data(), (FSIFF)iff, pos, att.GetForwardVector());
        ++n;
    }
    // Land ILS antennas (Luavi: COLE_29/11, BALUUT_33, SAKHET_26/08, MANTURUUN) add runways that have no
    // start spot, with the real touchdown point and heading. YS does not list them as ILS on this map.
    int nIls = 0;
    for (FsGround *g = nullptr; (g = sim->FindNextGround(g)) != nullptr;) {
        const FsAircraftCarrierProperty *prop = g->Prop().GetAircraftCarrierProperty();
        if (prop == nullptr || g->IsAlive() != YSTRUE || strstr(g->GetIdentifier(), "ILS") == nullptr) {
            continue;
        }
        YsVec3 td;
        YsAtt3 att;
        prop->GetILS().GetLandingPositionAndAttitude(td, att);
        YsVec3 dir = -att.GetForwardVector(); // ILS forward points back up the glide slope
        dir.SetY(0.0);
        if (dir.Normalize() != YSOK) {
            continue;
        }
        FsRvbMapInfo::AddStartRunway(g->GetName(), g->iff, td - dir * 300.0, dir);
        ++nIls;
    }
    log_line(String("RvB AI: ") + String::num_int64(n) + " runway start spots, " + String::num_int64(nIls) + " land ILS");
    return n;
}

static void count(Dictionary &d, const char *name) {
    const String k(name);
    d[k] = int64_t(d.get(k, 0)) + 1;
}

Dictionary ai_state(FsSimulation *sim) {
    Dictionary out;
    Dictionary roles, tasks, stages, alive_by_iff;
    int n = 0, known = 0, calls = 0;
    if (sim != nullptr) {
        for (FsAirplane *air = nullptr; (air = sim->FindNextAirplane(air)) != nullptr;) {
            if (air->IsAlive() == YSTRUE) {
                const int64_t iff = (int64_t)air->iff;
                alive_by_iff[iff] = int64_t(alive_by_iff.get(iff, 0)) + 1;
            }
            const auto *ap = dynamic_cast<const FsRvbTacticalAutopilot *>(air->GetAutopilot());
            if (ap == nullptr) {
                continue;
            }
            if (air->IsAlive() != YSTRUE) {
                continue;
            }
            ++n;
            count(roles, FsRvbRoleToStr(ap->GetRole()));
            count(tasks, FsRvbTacticalAutopilot::TaskToStr(ap->GetTask()));
            count(stages, FsRvbRecovery::StageToStr(ap->GetRecovery().GetStage()));
            known += (int)ap->GetAwareness().known.GetN();
            calls += (int)ap->GetAwareness().calls.GetN();
        }
    }
    out["enabled"] = is_rvb_ai_enabled();
    out["sim_time"] = (sim != nullptr ? sim->CurrentTime() : 0.0);
    out["alive_by_iff"] = alive_by_iff;
    out["rvb_ai"] = n;
    out["roles"] = roles;
    out["tasks"] = tasks;
    out["stages"] = stages;
    out["landings"] = FsRvbRecovery::nTotalLanding;  // Since the program started
    out["refuels"] = FsRvbRecovery::nTotalRefuel;
    out["takeoffs"] = FsRvbRecovery::nTotalTakeoff;
    Dictionary rtb;
    for (int r = 1; r < FsRvbSurvival::RTB_NUMREASON; ++r) {
        rtb[String(FsRvbSurvival::RtbReasonToStr((FsRvbSurvival::RTB_REASON)r))] = FsRvbSurvival::nRtb[r];
    }
    out["rtb_by_reason"] = rtb;
    out["known_contacts"] = known;
    out["calls_heard"] = calls;
    if (sim != nullptr && n > 0) {
        const FsRvbMapInfo &map = FsRvbTeamPicture::Get(sim).map;
        Array bases, runways;
        for (auto &b : map.base) {
            Dictionary d;
            d["type"] = (b.type == FsSimInfo::CARRIER ? "CARRIER" : "AIRPORT");
            d["tag"] = String(b.tag.Txt());
            d["iff"] = (int64_t)b.iff;
            d["x"] = (int64_t)b.pos.x();
            d["z"] = (int64_t)b.pos.z();
            bases.push_back(d);
        }
        for (auto &r : map.runway) {
            Dictionary d;
            d["iff"] = (int64_t)r.iff;
            d["a"] = Vector2i((int)r.end[0].x(), (int)r.end[0].z());
            d["b"] = Vector2i((int)r.end[1].x(), (int)r.end[1].z());
            d["y"] = (int64_t)r.end[0].y();
            runways.push_back(d);
        }
        Dictionary m;
        m["bases"] = bases;
        m["runways"] = runways;
        out["map"] = m;
    }
    out["picture_refreshes"] = (sim != nullptr && n > 0) ? FsRvbTeamPicture::Get(sim).nRefresh : 0;
    return out;
}

Array ai_aircraft_list(FsSimulation *sim) {
    Array list;
    if (sim == nullptr) {
        return list;
    }
    for (FsAirplane *air = nullptr; (air = sim->FindNextAirplane(air)) != nullptr;) {
        const auto *ap = dynamic_cast<const FsRvbTacticalAutopilot *>(air->GetAutopilot());
        if (ap == nullptr || air->IsAlive() != YSTRUE) {
            continue;
        }
        Dictionary a;
        a["id"] = String(air->GetIdentifier());
        a["iff"] = (int64_t)air->iff;
        a["task"] = String(FsRvbTacticalAutopilot::TaskToStr(ap->GetTask()));
        a["stage"] = String(FsRvbRecovery::StageToStr(ap->GetRecovery().GetStage()));
        a["stage_s"] = ap->GetRecovery().GetStageTime();
        a["phase"] = ap->GetRecovery().GetLandingPhase();
        a["x"] = air->GetPosition().x();
        a["z"] = air->GetPosition().z();
        a["alt"] = air->GetPosition().y();
        a["agl"] = air->GetAGL();
        a["speed"] = air->Prop().GetVelocity();
        a["ground"] = (air->Prop().IsOnGround() == YSTRUE);
        a["fuel"] = air->Prop().GetFuelLeft();
        list.push_back(a);
    }
    return list;
}

} // namespace ysgd
