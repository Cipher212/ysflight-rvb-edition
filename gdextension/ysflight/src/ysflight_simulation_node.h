#ifndef YSFLIGHT_SIMULATION_NODE_H
#define YSFLIGHT_SIMULATION_NODE_H

// The one Godot-facing class: owns the YS world and the bridge modules, and exposes them to GDScript.
// It holds no logic of its own beyond the frame loop; each feature lives in its module (src/*/).

#include <cstdint>

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "bridge/aircraft_fx_query.h"
#include "bridge/audio_bridge.h"
#include "render/aircraft_shadows.h"
#include "render/materials.h"
#include "render/shell_mesh.h"
#include "render/trail_renderer.h"
#include "render/visual_sync.h"
#include "render/weapon_fx_renderer.h"
#include "sim/ai_respawn.h"
#include "sim/event_match.h"
#include "sim/motion_interp.h"

class FsWorld;
class FsSimulation;

namespace godot {

class YSFlightSimulation : public Node3D {
    GDCLASS(YSFlightSimulation, Node3D)

public:
    YSFlightSimulation();
    ~YSFlightSimulation();

    void initialize_simulation();
    void load_yfs(String file_path);
    void log_to_crashlog(String msg);

    // Sim state (interpolated render transforms). Telemetry and airplane states are built once per rendered
    // frame and shared by every caller in that frame: treat the returned Dictionaries as read-only.
    Dictionary get_airplane_transforms();
    Dictionary get_ground_transforms() const;
    Dictionary get_ground_transform(int64_t key) const; // one object (cheap; for the locked ground target)
    Array get_active_weapons() const;
    Array get_active_explosions() const;
    Transform3D get_player_transform() const;
    Dictionary get_player_telemetry();
    PackedVector3Array get_tower_positions() const;
    Color get_sky_color() const;
    Color get_map_base_color() const;  // the map's dominant colour by area (island maps: the sea)

    // Benchmark / diagnostics
    PackedFloat64Array get_frame_stats();
    Dictionary get_audio_state();
    void reset_interpolation();
    void set_interpolation_enabled(bool enabled);
    void set_random_seed(int64_t seed);
    bool enable_player_autopilot();
    void debug_kill_player(); // test hook: the player aircraft is shot down

    // RvB tactical AI (ysce/src/autopilot/fsrvb*.cpp, sim/ai_setup, sim/ai_respawn)
    void set_rvb_ai_enabled(bool enabled);      // before load_yfs; false = stock YS AI (--stock-ai)
    void set_ai_respawn_enabled(bool enabled);
    void set_ai_ground_ops(bool enabled);       // archived RTB / landing / taxi (--ai-ground-ops)

    // Offline RvB event (sim/event_match.h; data formats: logs/UI_scheme.md "Event data")
    Array get_aircraft_catalog();               // [{identifier, team, role}]; loads templates if no mission yet
    bool event_begin(Dictionary config);        // after load_yfs of the generated mission
    bool apply_player_loadout(String preset);   // sim/flight_setup.h presets
    Dictionary get_event_state() const;         // per frame: time_left, ended, team kills, player status
    Dictionary get_event_results() const;       // debrief
    void event_leave_jet();                     // Esc x2: the player's aircraft is removed (not a death)
    void event_end();                           // ends the event now (pause menu "End event")
    Dictionary get_ai_state();
    void set_sim_speed(int64_t steps_per_tick);  // AI soak runs only: >1 runs the sim faster than real time

    // Flight setup / respawn
    PackedStringArray get_airplane_template_names() const;
    PackedStringArray get_start_position_names() const;
    bool is_helicopter_template(String airplane_name) const;
    bool respawn_player(String airplane_name, String start_position, int64_t iff);

    // Radar and effects
    Dictionary get_radar_contacts(double range_m);
    void set_radar_mode(int64_t mode);
    Dictionary get_aircraft_fx_state();
    void set_effects_quality(int64_t quality); // 0 low, 1 medium, 2 high (trails)
    void set_aircraft_shadows_enabled(bool enabled); // Graphics setting (render/aircraft_shadows.h)
    PackedInt32Array get_effects_stats() const; // [trail segments, trails, tracers, glows]

    // Controls
    void set_cockpit_cull_mode(bool enabled);
    void set_player_flight_inputs(double elevator, double aileron, double rudder, double throttle, bool afterburner, double trim);
    bool press_button(String function_name);
    void set_player_control(String name, double value);
    bool select_weapon(int64_t weapon_type);
    void set_player_weapon_inputs(bool fire_selected_held, bool fire_selected_just_pressed, bool fire_gun_held,
                                  bool cycle_weapon_just_pressed, bool dispense_flare_just_pressed);

    void _physics_process(double delta) override;
    void _process(double delta) override;

protected:
    static void _bind_methods();

private:
    // Per-frame cache key: a new physics tick or a new rendered frame invalidates cached queries.
    struct FrameStamp {
        uint64_t tick = ~0ull;
        uint64_t frame = ~0ull;
        bool operator==(const FrameStamp &o) const { return tick == o.tick && frame == o.frame; }
    };
    FrameStamp current_stamp() const;
    void reset_scene_roots();
    void write_heartbeat();
    void forget_airplane(unsigned int key);

    FsWorld *world = nullptr;
    FsSimulation *sim = nullptr;

    Node3D *scenery_root = nullptr;
    Node3D *airplanes_root = nullptr;
    Node3D *grounds_root = nullptr;
    Node3D *weapons_root = nullptr;
    Node3D *effects_root = nullptr;

    ysgd::Materials materials;
    ysgd::ShellMeshCache mesh_cache{materials};
    ysgd::VisualSync visual_sync{materials, mesh_cache};
    ysgd::AircraftShadows shadows;
    ysgd::MotionInterp interp;
    ysgd::AudioBridge audio;
    ysgd::AircraftFxTracker aircraft_fx;
    ysgd::TrailRenderer trails;
    ysgd::WeaponFxRenderer weapon_fx;
    ysgd::AiRespawn ai_respawn;
    ysgd::EventMatch event_match;
    int sim_speed = 1;
    int radar_mode = 0; // 0 = every aircraft within range; 1 = nose cone only (see radar_query.h)
    Color map_base_color = Color(0.3f, 0.45f, 0.5f);

    Dictionary cached_telemetry;
    FrameStamp telemetry_stamp;
    Dictionary cached_airplanes;
    FrameStamp airplanes_stamp;

    // PERF: summarised in the heartbeat line every 300 ticks; per-frame values read by get_frame_stats()
    double perf_sim_sum = 0.0, perf_sim_max = 0.0, perf_sync_sum = 0.0, perf_sync_max = 0.0;
    int perf_sync_frames = 0;
    double frame_sim_ms = 0.0, frame_sync_ms = 0.0, frame_fx_ms = 0.0;
    int frame_ticks = 0;
};

} // namespace godot

#endif // YSFLIGHT_SIMULATION_NODE_H
