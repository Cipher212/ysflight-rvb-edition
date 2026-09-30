#ifndef YSGD_MOTION_INTERP_H
#define YSGD_MOTION_INTERP_H

// Motion interpolation between physics ticks.
// The sim runs at a fixed 60 Hz; frames are rendered at any rate. Showing the latest tick directly makes
// motion stutter whenever the frame rate is not a multiple of 60. After every physics tick capture() stores
// each moving object's transform (prev <- cur, cur <- new); each rendered frame blends prev -> cur by the
// physics interpolation fraction. EVERYTHING the player sees reads these blended values (models, camera,
// HUD, radar, effects), so nothing can drift apart. Cost: the picture is up to one tick (16.7 ms) behind the
// sim, standard for fixed-step games. Audio and game logic keep raw sim positions.
// Snaps instead of blending: new objects, a reused weapon slot, jumps > 500 m in one tick (respawn).

#include <cstdint>
#include <unordered_map>
#include <vector>

#include <godot_cpp/variant/transform3d.hpp>

class FsSimulation;
class FsAirplane;
class FsGround;
class FsWeapon;

namespace ysgd {

class MotionInterp {
public:
    struct State {
        godot::Transform3D prev;
        godot::Transform3D cur;
        bool valid = false;
    };

    // After every physics tick.
    void capture(FsSimulation *sim);
    // Forget everything (new mission / respawn), then capture the current state.
    void reset(FsSimulation *sim);
    // Once per rendered frame, before anything reads transforms. alpha 0 = previous tick, 1 = latest.
    void begin_frame(double physics_fraction);
    void set_enabled(bool enabled) { enabled_ = enabled; }
    void forget_air(unsigned int key) { air_.erase(key); }  // Aircraft deleted from the sim
    double alpha() const { return alpha_; }

    godot::Transform3D air(const FsAirplane *air) const;
    godot::Transform3D gnd(const FsGround *gnd) const;
    godot::Transform3D wpn(const FsWeapon *wpn) const;

private:
    std::unordered_map<unsigned int, State> air_;   // by FsAirplane search key
    std::unordered_map<unsigned int, State> gnd_;   // by FsGround search key (non-static objects only)
    std::vector<State> wpn_;                        // by FsWeapon slot
    std::vector<int16_t> wpn_code_;                 // weapon type + 1 at the last capture
    std::vector<uint32_t> wpn_stamp_;               // capture tick in which the slot was active
    const FsWeapon *wpn_base_ = nullptr;            // start of the sim's weapon array (slot = wpn - base)
    uint32_t tick_ = 0;
    double alpha_ = 1.0;
    bool enabled_ = true;
};

} // namespace ysgd

#endif // YSGD_MOTION_INTERP_H
