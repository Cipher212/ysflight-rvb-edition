#ifndef YSGD_AI_SETUP_H
#define YSGD_AI_SETUP_H

// RvB tactical AI plumbing (the AI itself is YSCE code: ysce/src/autopilot/fsrvb*.cpp).
// - Roles: rvb_roles.txt lines go to FsRvbRoleTable before a mission loads (the aircraft name tags work
//   without it; the file only adds or overrides).
// - --stock-ai: set_rvb_ai_enabled(false) before load_yfs keeps the stock YS AI everywhere.
// - ai_state(): counts for tests and the debug overlay.

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

class FsWorld;
class FsSimulation;

namespace ysgd {

// Reads the roles file if it exists; returns the number of entries in the table.
int load_rvb_roles(const godot::String &path);
void set_rvb_ai_enabled(bool enabled);
// Archived ground operations (RTB / landing / taxi / refuel); off by default. See FsRvbTacticalAutopilot::groundOps.
void set_rvb_ground_ops(bool enabled);
bool is_rvb_ground_ops();
bool is_rvb_ai_enabled();
// A fresh mission: forget the shared team picture of the previous one.
void reset_rvb_ai();
// After load: the field's runway start spots ("[IFF1]COLE_AFB_RUNWAY", "[IFF4]DIRT_STRIP") become the AI's
// airfields (position = runway start, heading = runway direction). Returns how many were given.
int feed_start_runways(FsWorld *world, FsSimulation *sim);
// {"enabled", "sim_time", "alive_by_iff": {iff: n}, "rvb_ai", "roles": {ROLE: n}, "tasks": {TASK: n}, "stages": {STAGE: n}, "landings",
//  "refuels", "takeoffs" (totals since start), "picture_refreshes", "known_contacts", "calls_heard"}
godot::Dictionary ai_state(FsSimulation *sim);
// One Dictionary per live RvB AI: id, role, task, stage, stage_s, alt, agl, speed, ground (tuning / soak).
godot::Array ai_aircraft_list(FsSimulation *sim);

} // namespace ysgd

#endif // YSGD_AI_SETUP_H
