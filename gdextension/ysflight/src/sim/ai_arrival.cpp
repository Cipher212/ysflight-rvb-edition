#include "sim/ai_arrival.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "core/crashlog.h"
#include "core/ys_headers.h"
#include "sim/ai_respawn.h"

using namespace godot;

namespace ysgd {

int load_airfield_plans(const String &dir) {
    FsRvbAirfieldPlan::ClearAll();
    FsRvbTraffic::Reset();
    const PackedStringArray files = DirAccess::get_files_at(dir);
    for (int f = 0; f < files.size(); ++f) {
        if (files[f].get_extension().to_lower() != "txt") {
            continue;
        }
        FsRvbAirfieldPlan *plan = FsRvbAirfieldPlan::Begin(files[f].get_basename().to_upper().utf8().get_data());
        const PackedStringArray lines = FileAccess::get_file_as_string(dir.path_join(files[f])).split("\n");
        int bad = 0;
        for (int i = 0; i < lines.size(); ++i) {
            if (plan->AddLine(lines[i].strip_edges().utf8().get_data()) != YSOK) {
                ++bad;
            }
        }
        log_line(String("AI airfield plan ") + files[f] + ": " + String::num_int64(plan->approach.GetN()) + " approach lines, " +
                 String::num_int64(plan->rearm.GetN()) + " rearm spots, " + String::num_int64(bad) + " lines not understood");
    }
    return FsRvbAirfieldPlan::GetNumPlan();
}

int start_ai_arrival(FsSimulation *sim, const String &runway) {
    const FsRvbAirfieldPlan *plan = FsRvbAirfieldPlan::Find(runway.to_upper().utf8().get_data());
    if (sim == nullptr || plan == nullptr) {
        log_line(String("Arrival test: no plan for ") + runway);
        return 0;
    }
    int n = 0;
    for (FsAirplane *air = nullptr; (air = sim->FindNextAirplane(air)) != nullptr;) {
        if (air->IsAlive() == YSTRUE) {
            air->SetAutopilot(FsRvbArrival::Create(plan));
            ++n;
        }
    }
    log_line(String("Arrival test: ") + String::num_int64(n) + " aircraft on the arrival follower for " + runway);
    return n;
}

Array ai_arrival_state(FsSimulation *sim) {
    Array list;
    if (sim == nullptr) {
        return list;
    }
    FsRvbTraffic::PurgeDead(sim);
    for (FsAirplane *air = nullptr; (air = sim->FindNextAirplane(air)) != nullptr;) {
        const auto *ap = dynamic_cast<const FsRvbArrival *>(air->GetAutopilot());
        if (ap == nullptr) {
            continue;
        }
        const FsRvbArrival::Report &r = ap->GetReport();
        Dictionary rep;
        rep["touched_down"] = (r.touchedDown == YSTRUE);
        rep["td_along"] = r.tdAlong;
        rep["td_cross"] = r.tdCross;
        rep["td_speed"] = r.tdSpeed;
        rep["td_sink"] = r.tdSink;
        rep["td_time"] = r.tdTime;
        rep["off_pavement_s"] = r.offPavementTime;
        rep["off_pavement_x"] = r.offPavementPos.x();
        rep["off_pavement_z"] = r.offPavementPos.z();
        rep["rearmed"] = (r.rearmed == YSTRUE);
        rep["rearm_spot"] = String(r.rearmSpot.Txt());
        rep["rearm_stop_error"] = r.rearmStopError;
        rep["rearm_time"] = r.rearmTime;
        rep["airborne"] = (r.airborne == YSTRUE);
        rep["liftoff_along"] = r.liftoffAlong;
        rep["liftoff_speed"] = r.liftoffSpeed;
        rep["airborne_time"] = r.airborneTime;
        rep["wait_s"] = r.waitTime;
        rep["go_arounds"] = r.goArounds;
        rep["gate_changes"] = r.gateChanges;
        rep["hold_max_dist"] = r.holdMaxDist;
        rep["hold_radial_err_max"] = r.holdRadialErrMax;
        rep["hold_established_radial_err_max"] = r.holdEstablishedRadialErrMax;
        rep["hold_orbit_duration"] = r.holdOrbitDuration;
        rep["min_terrain_clearance"] = r.minTerrainClearance;
        rep["fail"] = String(r.failReason.Txt());

        Dictionary a;
        a["t"] = sim->CurrentTime();
        a["id"] = String(air->GetIdentifier());
        a["search_key"] = (int64_t)air->SearchKey();
        a["alive"] = (air->IsAlive() == YSTRUE);
        a["died_of"] = String(air->IsAlive() == YSTRUE ? "" : died_of_name(air->Prop().GetDiedOf()));
        a["phase"] = String(FsRvbArrival::PhaseToStr(ap->GetPhase()));
        a["hold_state"] = String(FsRvbArrival::HoldStateToStr(ap->GetHoldState()));
        a["line"] = String(ap->GetLineName());
        a["assigned_alt"] = ap->GetAssignedAlt();
        a["stack_level"] = ap->GetHoldStackLevel();
        a["hold_speed"] = ap->GetHoldSpeed();
        a["orbit_duration"] = ap->GetHoldOrbitDuration();
        a["established_radial_err_max"] = ap->GetEstablishedRadialErrMax();
        a["clearance_approach"] = (ap->HasClearance("APPROACH") == YSTRUE);
        a["clearance_runway"] = (ap->HasClearance("RUNWAY") == YSTRUE);
        a["terrain_clearance_agl"] = air->GetPosition().y() - sim->GetFieldElevation(air->GetPosition().x(), air->GetPosition().z());
        a["x"] = air->GetPosition().x();
        a["y"] = air->GetPosition().y();
        a["z"] = air->GetPosition().z();
        a["speed"] = air->Prop().GetVelocity();
        a["ground_speed"] = FsRvbHands::GroundSpeed(*air);
        a["ground"] = (air->Prop().IsOnGround() == YSTRUE);
        a["offpave"] = (air->Prop().IsOnGround() == YSTRUE && air->Prop().IsOutOfRunway() == YSTRUE);
        a["holding"] = (ap->IsHeldByTraffic() == YSTRUE);
        a["radial_error"] = ap->GetHoldRadialError();
        a["hold_center_x"] = ap->GetHoldCenter().x();
        a["hold_center_z"] = ap->GetHoldCenter().z();
        a["hold_radius"] = ap->GetHoldRadius();
        a["gear"] = air->Prop().GetLandingGear();
        a["flap"] = air->Prop().GetFlap();
        a["spoiler"] = air->Prop().GetSpoiler();
        a["throttle"] = air->Prop().GetThrottle();
        a["brake"] = (air->Prop().GetBrake() == YSTRUE);
        a["report"] = rep;
        list.push_back(a);
    }
    return list;
}

} // namespace ysgd
