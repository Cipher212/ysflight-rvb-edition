#ifndef YSGD_SIM_QUERIES_H
#define YSGD_SIM_QUERIES_H

// Read-only views of the sim state for GDScript. Transforms are the interpolated render transforms (the
// same values the models are drawn with).

#include <cstdint>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

class FsSimulation;

namespace ysgd {

class MotionInterp;

// { key: { pos, rot, transform, velocity, cockpit_local, outside_radius, is_player, is_alive, iff, identifier, name } }
godot::Dictionary airplane_states(FsSimulation *sim, const MotionInterp &interp);
// { key: { pos, transform, is_alive, iff, identifier, name, is_non_game_object } } for game objects (no static props)
godot::Dictionary ground_states(FsSimulation *sim, const MotionInterp &interp);
// One ground object (same fields); empty if the key is unknown.
godot::Dictionary ground_state(FsSimulation *sim, const MotionInterp &interp, int64_t key);
// [{ slot_id, type, pos, prev_pos, vel, transform, life_remain, time_remain, has_trail }]
godot::Array active_weapons(FsSimulation *sim, const MotionInterp &interp);
// [{ slot_id, uid, exp_type, pos, time_passed, time_remain, ini_radius, radius, flash }]
godot::Array active_explosions(FsSimulation *sim);
// Flight data of the player aircraft (speed, altitude, attitude, weapons, lock, gun lead, ...).
godot::Dictionary player_telemetry(FsSimulation *sim, const MotionInterp &interp);

godot::PackedVector3Array tower_positions(FsSimulation *sim);
godot::Color sky_color(FsSimulation *sim);

} // namespace ysgd

#endif // YSGD_SIM_QUERIES_H
