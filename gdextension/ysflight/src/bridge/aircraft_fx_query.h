#ifndef YSGD_AIRCRAFT_FX_QUERY_H
#define YSGD_AIRCRAFT_FX_QUERY_H

#include <unordered_set>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

class FsSimulation;

namespace ysgd {

class MotionInterp;

// Aircraft effect state, once per rendered frame (aircraft_fx.gd).
// aircraft: PackedFloat32Array stride 21 per aircraft flying or falling after being killed:
//   [key, pos x/y/z, vel x/y/z, damage 0..1, state (0 flying, 1 dying), vapor (0/1), vapor tip x/y/z
//    (right wingtip, Godot local; mirror x for the left tip), radius (m), forward x/y/z, 0,
//    smoke point x/y/z (world; DAT SMOKEGEN, where fire/smoke come from)]
//   Positions are the interpolated render positions (effects line up with the models).
// crashes: PackedFloat32Array stride 5 per aircraft that hit the ground or water since the previous call:
//   [x, y (terrain height), z, on_water (0/1), radius]. Water = the field's area type at that point
//   (YS DEFAREA / area polygons). YS itself adds the impact explosion or water plume to the explosions.
class AircraftFxTracker {
public:
    godot::Dictionary collect(FsSimulation *sim, const MotionInterp &interp);
    void reset() { crashed_keys.clear(); }
    void forget(unsigned int key) { crashed_keys.erase(key); }  // Aircraft deleted from the sim

private:
    std::unordered_set<unsigned int> crashed_keys; // dead aircraft whose death was already handled
};

} // namespace ysgd

#endif // YSGD_AIRCRAFT_FX_QUERY_H
