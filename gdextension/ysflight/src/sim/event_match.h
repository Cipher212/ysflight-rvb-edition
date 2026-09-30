#ifndef YSGD_EVENT_MATCH_H
#define YSGD_EVENT_MATCH_H
// Offline RvB event (match builder, godot_project/ui/): the pilot roster, spawning and respawning its AI
// pilots, the event clock and rules, and statistics per pilot.
// - A pilot is a persistent entity (name, team, aircraft): every (re)spawn is a new YS aircraft bound to the same
//   pilot, so scores follow the name. The player is one more pilot, bound to whatever aircraft the player flies.
// - Stats come from FsWeaponHolder's event hook (ysce/src/core/fsweapon.h: shots fired, damage, kills with the
//   shooter, victim and weapon) plus alive -> dead transitions (deaths without a weapon: terrain, collision...).
// - Rules: mid-air collisions (FsSimulation::SetMidAirCollision), friendly fire (FsWeaponHolder::friendlyFire).
// Config / state / results formats: logs/UI_scheme.md ("Event data").

#include <string>
#include <unordered_map>
#include <vector>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "fsweapon.h"

class FsWorld;
class FsSimulation;

namespace ysgd {

class EventMatch : public FsWeaponEventObserver {
public:
    static constexpr double RESPAWN_DELAY = 5.0; // s (same as free play)
    static constexpr int SPAWNS_PER_TICK = 2;    // spreads the initial 36 air starts over a few ticks
    static constexpr int MAX_PER_SIDE = 18;      // user: hard cap 18 v 18
    static constexpr int MIN_MINUTES = 5;
    static constexpr int MAX_MINUTES = 120;
    static constexpr double PARKED_SPEED = 1.0; // m/s: on the ground and slower than this = may leave the jet

    // Starts the event on the loaded mission (the generated one has no aircraft). False if the config is bad.
    bool begin(FsWorld *world, FsSimulation *sim, const godot::Dictionary &config);
    void update(FsWorld *world, FsSimulation *sim, double dt); // after every physics tick
    void end_now() { ended_ = true; }
    void reset();                                              // new mission loaded
    bool active() const { return active_; }
    // Removes the player's aircraft without counting a death (Esc x2 -> spawn menu). Returns its key or 0.
    unsigned int leave_player_jet(FsSimulation *sim);

    godot::Dictionary state() const;   // per frame (overlay): time_left, ended, team kills, player status
    godot::Dictionary results() const; // debrief: pilots with stats, kill log, totals

    // RvB aircraft the builder offers: [{identifier, team "blue"/"red", role}] (role from rvb_roles.txt / tag).
    static godot::Array aircraft_catalog(FsWorld *world);

    void OnWeaponFired(const FsWeapon &wpn) override;
    void OnWeaponDamage(const FsWeapon &wpn, const FsExistence &victim, int power, YSBOOL killed) override;

private:
    enum WeaponClass { GUN, AAM, AGM, BOMB, ROCKET, CLASS_COUNT };
    struct Pilot {
        std::string name, identifier;
        int iff = 0, role = 0;
        bool player = false;
        unsigned int key = 0;      // current aircraft (0 = none)
        bool alive = false;
        bool weapon_kill = false;  // this life ended by a weapon (else a death is a crash)
        double dead_since = -1e9;
        int air_kills = 0, ground_kills = 0, team_kills = 0, deaths = 0, crashes = 0;
        int leaves = 0;            // left the jet while flying or rolling (RvB: scored as a death)
        int fired[CLASS_COUNT] = {}, hits[CLASS_COUNT] = {};
    };
    struct Shot {
        int pilot = -1;
        WeaponClass cls = GUN;
        bool hit = false;
    };
    struct Kill {
        double time = 0.0;
        int killer = -1;             // pilot index, -1 = no pilot (crash, or a ground unit: killer_name)
        std::string killer_name;     // ground unit (SAM, AAA, ship) that fired, if not a pilot
        int killer_iff = -1;
        int victim = -1;             // pilot index, -1 = ground object
        std::string victim_name;     // ground object type or pilot name
        std::string how;             // weapon class or cause of death
        bool ground = false, team_kill = false;
    };

    static WeaponClass class_of(int weapon_type);
    int pilot_of(unsigned int key) const;
    void bind(int pilot, unsigned int key);
    void track_player(FsSimulation *sim);
    void spawn_ai(FsWorld *world, FsSimulation *sim);
    void check_deaths(FsSimulation *sim);

    std::vector<Pilot> pilots_;
    std::unordered_map<unsigned int, int> key_to_pilot_;
    std::unordered_map<const void *, Shot> shots_; // by weapon object (YS reuses a fixed buffer)
    std::vector<Kill> kills_;
    godot::Dictionary config_;
    double clock_ = 0.0, duration_ = 0.0;
    bool player_parked_ = false;   // player's jet landed and stopped (state(): Esc x2 costs no death)
    int player_pilot_ = -1;
    bool active_ = false, ended_ = false;
};

} // namespace ysgd

#endif // YSGD_EVENT_MATCH_H
