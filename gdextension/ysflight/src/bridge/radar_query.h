#ifndef YSGD_RADAR_QUERY_H
#define YSGD_RADAR_QUERY_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

class FsSimulation;

namespace ysgd {

class MotionInterp;

// Radar picture for radar_scope.gd. All contacts are in the player's HEADING-UP horizontal frame (metres):
// right = +x right of the nose, fwd = ahead, alt = height above (+) / below (-) the player; positions are
// the interpolated render positions, so blips move smoothly.
// VISIBILITY RULES LIVE HERE so they can change without touching the UI (user: show everything for now):
//   mode 0 = every alive aircraft within range (current RvB rule)
//   mode 1 = only contacts inside +/-RADAR_CONE_DEG of the nose (azimuth and elevation)
//   future: terrain masking, notching, jammers -> add modes here.
// Returns: { contacts: PackedFloat32Array stride 8 [key, right, fwd, alt, rel_heading_rad, iff, locked, speed_ms],
//            ground:   PackedFloat32Array stride 6 [key, right, fwd, alt, iff, locked],
//            missiles: PackedFloat32Array stride 5 [right, fwd, alt, flags (1 = chasing the player,
//                      2 = fired by the player), weapon_type] }
godot::Dictionary radar_contacts(FsSimulation *sim, const MotionInterp &interp, double range_m, int mode);

} // namespace ysgd

#endif // YSGD_RADAR_QUERY_H
