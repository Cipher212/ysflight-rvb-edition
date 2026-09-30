#ifndef YSGD_FLIGHT_SETUP_H
#define YSGD_FLIGHT_SETUP_H

// Flight setup / respawn. Uses the same YS calls as the YS multiplayer server when a player joins:
// FsWorld::AddAirplane + SettleAirplane at a named start position (.stp), zero speed on carriers, then
// SetPlayerAirplane (which also records the player change for flight records). The dead aircraft stays in
// the sim as a wreck (hidden by the visual sync once it is not the player).

#include <cstdint>

#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

class FsWorld;
class FsSimulation;

namespace ysgd {

godot::PackedStringArray airplane_template_names(FsWorld *world);
// Start positions (.stp names) of the current field.
godot::PackedStringArray start_position_names(FsWorld *world, FsSimulation *sim);
bool is_helicopter_template(FsWorld *world, const godot::String &airplane_name);
bool respawn_player(FsWorld *world, FsSimulation *sim, const godot::String &airplane_name,
                    const godot::String &start_position, int64_t iff);
// Test hook: same as a real shoot-down (spins down until impact).
void kill_player(FsSimulation *sim);
// Hands the player's aircraft to the AI (benchmark and --ai-player): the RvB AI if the aircraft has an
// RvB role, else the YS dogfight AI.
bool enable_player_autopilot(FsSimulation *sim);

} // namespace ysgd

#endif // YSGD_FLIGHT_SETUP_H
