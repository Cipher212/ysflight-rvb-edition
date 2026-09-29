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
    }
    sim->SetPlayerAirplane(air);
    log_line(String("respawn_player: ") + airplane_name + " at " + start_position + " IFF" + String::num_int64(iff + 1));
    return true;
}

void kill_player(FsSimulation *sim) {
    if (sim != nullptr && sim->GetPlayerAirplane() != nullptr) {
        // YS GetDamage picks FSDEAD / FSDEADSPIN / FSDEADFLATSPIN; the spin is the common case
        sim->GetPlayerAirplane()->Prop().SetFlightState(FSDEADSPIN, FSDIEDOF_NULL);
    }
}

bool enable_player_autopilot(FsSimulation *sim) {
    if (sim == nullptr || sim->GetPlayerAirplane() == nullptr) {
        return false;
    }
    FsDogfight *df = FsDogfight::Create();
    df->gLimit = 9.0;
    df->minAlt = 300.0;
    sim->GetPlayerAirplane()->SetAutopilot(df);
    log_line("Player aircraft handed to the FsDogfight autopilot.");
    return true;
}

} // namespace ysgd
