#ifndef YSGD_AI_RESPAWN_H
#define YSGD_AI_RESPAWN_H

// RvB AI respawn and wreck clean-up (runs after every physics tick).
// - An RvB AI (FsRvbTacticalAutopilot) that dies comes back RESPAWN_DELAY s later as the same aircraft,
//   loadout, team and role.  Default (ground ops archived): in the air at a free "AI_BLUE_*" / "AI_RED_*" spot
//   of the map, 200 m/s.  --ai-ground-ops: at a free team start position ("[IFF1]"/"[IFF4]"; no "(HELI ONLY)"
//   spots for jets; carriers only at a catapult; never a runway or hangar spot), then it taxis and takes off.
// - Dead aircraft other than the player's current one are deleted from the sim after WRECK_TIME s (the
//   crash site effect is independent of the wreck). Without this the aircraft list, and the hidden visuals,
//   would grow for the whole hour of an RvB event. removed_keys() tells the node which visuals to free.

#include <map>
#include <string>
#include <unordered_map>
#include <vector>

class FsWorld;
class FsSimulation;
class FsAirplane;

namespace ysgd {

// Places a new RvB AI aircraft in the air at a free "AI_BLUE_*" / "AI_RED_*" spot of the map (200 m/s, gear
// up) with the given loadout commands and the tactical AI for role. nullptr if the aircraft type is unknown or
// every spot is occupied (try again shortly). Used by AI respawns and by the offline event (event_match.h).
FsAirplane *spawn_ai_in_air(FsWorld *world, FsSimulation *sim, const std::string &identifier, int iff, int role,
                            const std::vector<std::string> &loadout);
// YS cause of death as text (MISSILE, GUN, TERRAIN, COLLISION, ...).
const char *died_of_name(int died_of); // FSDIEDOF

class AiRespawn {
public:
    static constexpr double RESPAWN_DELAY = 5.0;  // s after death (user spec)
    static constexpr double WRECK_TIME = 5.0;     // s: the dead airframe is removed with the respawn
    static constexpr double RETRY_DELAY = 2.0;    // s: every start position of the team was occupied
    static constexpr double FREE_RADIUS = 150.0;   // m: a start position with an aircraft this close is taken

    void set_enabled(bool enabled) { enabled_ = enabled; }
    void update(FsWorld *world, FsSimulation *sim, double dt);
    void reset();
    // Keys deleted by the last update (the caller frees their visuals and caches).
    const std::vector<unsigned int> &removed_keys() const { return removed_; }
    int respawned() const { return n_respawned_; }
    int wrecks_removed() const { return n_removed_; }
    // RvB AI deaths by YS cause (MISSILE, GUN, TERRAIN, ...) and by the task it was on (tuning).
    const std::map<std::string, int> &deaths_by_cause() const { return deaths_by_cause_; }
    const std::map<std::string, int> &deaths_by_task() const { return deaths_by_task_; }

private:
    struct Dead {
        double time = 0.0;
        bool rvb = false;
        int role = 0;
        int iff = 0;
        std::string identifier;
        std::vector<std::string> loadout;
    };

    bool respawn(FsWorld *world, FsSimulation *sim, const Dead &d);

    std::unordered_map<unsigned int, Dead> dead_;
    std::vector<unsigned int> removed_;
    std::map<std::string, int> deaths_by_cause_;
    std::map<std::string, int> deaths_by_task_;
    double clock_ = 0.0;
    bool enabled_ = true;
    int n_respawned_ = 0;
    int n_removed_ = 0;
};

} // namespace ysgd

#endif // YSGD_AI_RESPAWN_H
