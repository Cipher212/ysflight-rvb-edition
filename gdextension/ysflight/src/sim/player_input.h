#ifndef YSGD_PLAYER_INPUT_H
#define YSGD_PLAYER_INPUT_H

// Controls bridge. controls.gd owns the continuous values (stick, rudder, throttle, afterburner, trim) and
// sends them every physics tick. Discrete YS button functions (gear, flaps, brakes, radar, ...) go through
// YS's own FsFlightControl::ProcessButtonFunction so they behave exactly like YSFlight.

#include <cstdint>

#include <godot_cpp/variant/string.hpp>

class FsSimulation;

namespace ysgd {

void set_flight_inputs(FsSimulation *sim, double elevator, double aileron, double rudder, double throttle,
                       bool afterburner, double trim);
// name = YS FSBTF_* function without the prefix ("LANDINGGEAR", "FLAPUP", ...). False if unknown.
bool press_button(FsSimulation *sim, const godot::String &name);
// Direct value 0..1 for hold-style or analog controls: "brake", "spoiler", "flap", "gear".
void set_control(FsSimulation *sim, const godot::String &name, double value);
// Selects a weapon type (FSWEAPONTYPE) if the player carries it.
bool select_weapon(FsSimulation *sim, int64_t weapon_type);
void set_weapon_inputs(FsSimulation *sim, bool fire_selected_held, bool fire_selected_just_pressed, bool fire_gun_held,
                       bool cycle_weapon_just_pressed, bool dispense_flare_just_pressed);

} // namespace ysgd

#endif // YSGD_PLAYER_INPUT_H
