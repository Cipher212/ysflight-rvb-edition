#include "sim/player_input.h"

#include "core/ys_headers.h"

using namespace godot;

namespace ysgd {

namespace {

// The player's aircraft if it exists (and, when required, is alive).
FsAirplane *player_of(FsSimulation *sim, bool require_alive) {
    FsAirplane *p = sim != nullptr ? sim->GetPlayerAirplane() : nullptr;
    if (p == nullptr || (require_alive && p->IsAlive() != YSTRUE)) {
        return nullptr;
    }
    return p;
}

bool button_function_from_name(const String &name, FSBUTTONFUNCTION &fnc) {
    struct Entry { const char *name; FSBUTTONFUNCTION fnc; };
    static const Entry table[] = {
        {"LANDINGGEAR", FSBTF_LANDINGGEAR},
        {"FLAPUP", FSBTF_FLAPUP},
        {"FLAPDOWN", FSBTF_FLAPDOWN},
        {"FLAPFULLUP", FSBTF_FLAPFULLUP},
        {"FLAPFULLDOWN", FSBTF_FLAPFULLDOWN},
        {"BRAKEONOFF", FSBTF_BRAKEONOFF},
        {"SPOILER", FSBTF_SPOILER},
        {"SPOILERBRAKE", FSBTF_SPOILERBRAKE},
        {"RADAR", FSBTF_RADAR},
        {"RADARRANGEUP", FSBTF_RADARRANGEUP},
        {"RADARRANGEDOWN", FSBTF_RADARRANGEDOWN},
        {"VELOCITYINDICATOR", FSBTF_VELOCITYINDICATOR},
        {"BOMBBAYDOOR", FSBTF_BOMBBAYDOOR},
        {"TOGGLELIGHT", FSBTF_TOGGLELIGHT},
        {"TOGGLEALLDOOR", FSBTF_TOGGLEALLDOOR},
        {"NOZZLEUP", FSBTF_NOZZLEUP},
        {"NOZZLEDOWN", FSBTF_NOZZLEDOWN},
    };
    for (const Entry &e : table) {
        if (name == e.name) {
            fnc = e.fnc;
            return true;
        }
    }
    return false;
}

} // namespace

void set_flight_inputs(FsSimulation *sim, double elevator, double aileron, double rudder, double throttle,
                       bool afterburner, double trim) {
    FsAirplane *player = player_of(sim, false);
    if (player == nullptr) {
        return;
    }
    FsFlightControl ctrl;
    player->Prop().ReadBackControl(ctrl);
    ctrl.ctlElevator = elevator;
    ctrl.ctlAileron = aileron;
    ctrl.ctlRudder = rudder;
    ctrl.ctlElvTrim = trim;
    ctrl.ctlThrottle = throttle;
    ctrl.ctlAb = afterburner ? YSTRUE : YSFALSE;
    // Stick and throttle only: trigger states set by set_weapon_inputs are preserved
    player->Prop().ApplyControl(ctrl, FSAPPLYCONTROL_STICK | FSAPPLYCONTROL_THROTTLE);
}

bool press_button(FsSimulation *sim, const String &name) {
    FsAirplane *player = player_of(sim, true);
    FSBUTTONFUNCTION fnc;
    if (player == nullptr || !button_function_from_name(name, fnc)) {
        return false;
    }
    FsFlightControl ctrl;
    player->Prop().ReadBackControl(ctrl);
    ctrl.ProcessButtonFunction(sim->CurrentTime(), player, fnc);
    // Everything except stick/throttle (owned by controls.gd) and triggers (set_weapon_inputs)
    player->Prop().ApplyControl(ctrl, FSAPPLYCONTROL_ALL & ~(FSAPPLYCONTROL_STICK | FSAPPLYCONTROL_THROTTLE | FSAPPLYCONTROL_TRIGGER));
    return true;
}

void set_control(FsSimulation *sim, const String &name, double value) {
    FsAirplane *player = player_of(sim, true);
    if (player == nullptr) {
        return;
    }
    FsFlightControl ctrl;
    player->Prop().ReadBackControl(ctrl);
    const double v = YsBound(value, 0.0, 1.0);
    unsigned int what = 0;
    if (name == "brake") {
        ctrl.ctlBrake = v;
        what = FSAPPLYCONTROL_BRAKE;
    } else if (name == "spoiler") {
        ctrl.ctlSpoiler = v;
        what = FSAPPLYCONTROL_SPOILER;
    } else if (name == "flap") {
        ctrl.ctlFlap = v;
        what = FSAPPLYCONTROL_FLAP;
    } else if (name == "gear") {
        ctrl.ctlGear = v;
        what = FSAPPLYCONTROL_GEAR;
    }
    if (what != 0) {
        player->Prop().ApplyControl(ctrl, what);
    }
}

bool select_weapon(FsSimulation *sim, int64_t weapon_type) {
    FsAirplane *player = player_of(sim, true);
    if (player == nullptr) {
        return false;
    }
    const FSWEAPONTYPE wanted = (FSWEAPONTYPE)weapon_type;
    return player->Prop().SetWeaponOfChoice(wanted) == YSOK && player->Prop().GetWeaponOfChoice() == wanted;
}

void set_weapon_inputs(FsSimulation *sim, bool fire_selected_held, bool fire_selected_just_pressed, bool fire_gun_held,
                       bool cycle_weapon_just_pressed, bool dispense_flare_just_pressed) {
    FsAirplane *player = player_of(sim, true);
    if (player == nullptr) {
        return;
    }
    auto &prop = player->Prop();
    if (cycle_weapon_just_pressed) {
        prop.CycleWeaponOfChoice();
    }
    // Dedicated gun trigger (fires the gun even when another weapon is selected)
    prop.SetFireGunButton(fire_gun_held ? YSTRUE : YSFALSE);
    // Selected-weapon trigger: gun/smoke fire continuously while held. Setting the button twice syncs
    // YS's previous-state copy, so discrete weapons fire only through the explicit VBT_FIREWEAPON below.
    const YSBOOL fw_state = fire_selected_held ? YSTRUE : YSFALSE;
    prop.SetFireWeaponButton(fw_state);
    prop.SetFireWeaponButton(fw_state);
    const FSWEAPONTYPE woc = prop.GetWeaponOfChoice();
    if (fire_selected_just_pressed && woc != FSWEAPON_GUN && woc != FSWEAPON_SMOKE) {
        prop.PressVirtualButton(FsAirplaneProperty::VBT_FIREWEAPON);
    }
    if (dispense_flare_just_pressed) {
        prop.PressVirtualButton(FsAirplaneProperty::VBT_DISPENSEFLARE);
    }
}

} // namespace ysgd
