#ifndef YSGD_AUDIO_BRIDGE_H
#define YSGD_AUDIO_BRIDGE_H

#include <cstdint>
#include <unordered_set>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

class FsSimulation;

namespace ysgd {

// Everything audio_manager.gd needs for one rendered frame. collect() must be called exactly once per
// frame: the event lists contain what happened since the previous call.
//   player:     { key, engine_type (FSSND_ENGINETYPE), engine_power 0..1, gun (0/1), alarm (FSSND_ALARMTYPE) }
//               = what the YS sound logic (SimBlastSound) requested for the player aircraft.
//   onetime:    PackedInt32Array of FSSND_ONETIMETYPE values fired by YS (touchdown, gear, ...).
//   aircraft:   PackedFloat32Array, stride 11 per alive aircraft: key, pos x/y/z, vel x/y/z (Godot space),
//               engine_kind (0 jet, 1 jet+afterburner, 2 prop/rotor), power 0..1, gun_firing, is_player
//   launches:   PackedFloat32Array, stride 6: kind (0 missile, 1 rocket, 2 bomb), pos x/y/z, shooter key (-1), FSWEAPONTYPE
//   explosions: PackedFloat32Array, stride 5: pos x/y/z, radius (m), explosion type
class AudioBridge {
public:
    godot::Dictionary collect(FsSimulation *sim);
    void reset();

private:
    bool initialized = false;
    unsigned int prev_onetime[32] = {0};
    std::vector<int16_t> prev_weapon_code; // per weapon slot: 0 = inactive, else weapon type + 1
    std::unordered_set<int64_t> seen_explosions;
};

} // namespace ysgd

#endif // YSGD_AUDIO_BRIDGE_H
