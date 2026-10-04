#ifndef YSGD_AI_ARRIVAL_H
#define YSGD_AI_ARRIVAL_H

// New RvB AI, ground operations (the AI itself is YSCE code: ysce/src/autopilot/fsrvbarrival.cpp and friends).
// - Plans: every godot_project/ai/<RUNWAY>.txt (tools/maps/build_arrival_plan.py) is read at load_yfs.
// - start_ai_arrival(): the arrival test (--ai-arrival <RUNWAY>) hands every aircraft to the arrival follower.
// - ai_arrival_state(): per aircraft phase, position and report for tests/ai_arrival_test.gd (a few jets,
//   sampled a few times a second: Dictionaries are fine here).

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

class FsSimulation;

namespace ysgd {

// Reads every *.txt in dir as an airfield plan named after the file; returns how many were read.
int load_airfield_plans(const godot::String &dir);
// Gives every live aircraft (the player's too) the arrival follower for this runway; returns how many.
int start_ai_arrival(FsSimulation *sim, const godot::String &runway);
// [{t (sim time), id, alive, phase, line, x, y, z, speed, ground, offpave, holding, report: {...}}] for aircraft on the follower.
godot::Array ai_arrival_state(FsSimulation *sim);

} // namespace ysgd

#endif // YSGD_AI_ARRIVAL_H
