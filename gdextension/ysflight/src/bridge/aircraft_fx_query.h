#ifndef YSGD_AIRCRAFT_FX_QUERY_H
#define YSGD_AIRCRAFT_FX_QUERY_H

#include <unordered_set>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

class FsSimulation;

namespace ysgd {

class MotionInterp;

// Aircraft effect state, once per rendered frame (aircraft_fx.gd).
// aircraft: PackedFloat32Array stride 18 per aircraft that is flying or falling after being killed:
//   [key, pos x/y/z, vel x/y/z, damage 0..1, state (0 flying, 1 dying), vapor (0/1), vapor tip x/y/z
//    (right wingtip, Godot local; mirror x for the left tip), radius (m), forward x/y/z, 0]
//   Positions are the interpolated render positions (effects line up with the models).
// crashes: PackedFloat32Array stride 5 per aircraft that hit the ground since the previous call:
//   [x, y, z, on_water (0/1), radius]. Water = terrain within 1 m of sea level (y = 0), which fits the RvB
//   maps; revisit if a map has water at other heights.
class AircraftFxTracker {
public:
    godot::Dictionary collect(FsSimulation *sim, const MotionInterp &interp);
    void reset() { crashed_keys.clear(); }

private:
    std::unordered_set<unsigned int> crashed_keys; // aircraft whose crash event was already reported
};

} // namespace ysgd

#endif // YSGD_AIRCRAFT_FX_QUERY_H
