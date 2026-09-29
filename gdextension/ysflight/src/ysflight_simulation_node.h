#ifndef YSFLIGHT_SIMULATION_NODE_H
#define YSFLIGHT_SIMULATION_NODE_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <unordered_map>
#include <unordered_set>
#include <vector>

class FsWorld;
class FsAirplane;
class FsGround;
class FsWeapon;
class FsVisualDnm;
class FsSimulation;
class YsShellExt;
class YsScenery;
class YsMatrix4x4;

namespace godot {

class YSFlightSimulation : public Node3D {
    GDCLASS(YSFlightSimulation, Node3D)

public:
    // Previous/current transform of one moving object, for motion interpolation
    struct InterpState {
        Transform3D prev;
        Transform3D cur;
        bool valid = false;
    };


private:
    struct EntityVisual {
        Node3D *root_node = nullptr;
        const void *dnm_ptr = nullptr;
        bool static_settled = false;
        bool cockpit_applied = false;
        std::vector<Node3D *> dnm_nodes;
        std::vector<Node3D *> hardpoint_nodes;
        // Last values pushed to Godot. Node3D::set_transform/set_visible always notify the
        // scene tree and RenderingServer, so unchanged values are skipped.
        int8_t root_visible = -1; // -1 = unknown
        bool has_root_tfm = false;
        Transform3D root_tfm;
        std::vector<int8_t> node_visible;
        std::vector<Transform3D> node_tfm;
        std::vector<uint8_t> node_has_tfm;
    };

    FsWorld *world;
    FsSimulation *sim;

    Node3D *scenery_root;
    Node3D *airplanes_root;
    Node3D *grounds_root;
    Node3D *weapons_root;

    Ref<StandardMaterial3D> mat_lit;
    Ref<StandardMaterial3D> mat_bright;
    Ref<StandardMaterial3D> mat_trans;
    // Cockpit (F1) variants with back-face culling, applied only to the player's aircraft.
    // Kept alive for the whole session: toggling cull_mode on one material recompiles its shader.
    Ref<StandardMaterial3D> mat_lit_cockpit;
    Ref<StandardMaterial3D> mat_trans_cockpit;
    bool cockpit_mode = false;
    unsigned int cockpit_key = 0;
    bool cockpit_key_valid = false;
    MeshInstance3D *prewarm_node = nullptr; // draws the cockpit materials for a few frames at load
    int prewarm_frames_left = 0;
    Ref<StandardMaterial3D> mat_terrain;
    Ref<StandardMaterial3D> mat_point;

    Ref<ShaderMaterial> mat_map_poly;
    Ref<ShaderMaterial> mat_map_line;
    Ref<ShaderMaterial> mat_map_point;

    std::unordered_map<const void *, Ref<ArrayMesh>> shell_mesh_cache;
    std::unordered_map<unsigned int, EntityVisual> airplane_visuals;
    std::unordered_map<unsigned int, EntityVisual> ground_visuals;
    std::unordered_map<unsigned int, EntityVisual> weapon_visuals; // keyed by FsWeapon slot index
    std::unordered_map<unsigned int, EntityVisual> cockpit_visuals; // player cockpit shell (F1), by airplane key
    ::FsVisualDnm *generic_cockpit = nullptr;  // aircraft/cockpit1.srf, YS fallback for aircraft without a cockpit model
    std::unordered_map<const void *, std::vector<EntityVisual>> weapon_pool; // hidden, reusable, by DNM

    // Motion interpolation between physics ticks (see "Motion interpolation" in the .cpp).
    std::unordered_map<unsigned int, InterpState> interp_air;  // by FsAirplane search key
    std::unordered_map<unsigned int, InterpState> interp_gnd;  // by FsGround search key (non-static objects only)
    std::vector<InterpState> interp_wpn;                        // by FsWeapon slot
    std::vector<int16_t> interp_wpn_code;                       // weapon type + 1 at the last capture
    std::vector<uint32_t> interp_wpn_stamp;                     // capture tick in which the slot was active
    uint32_t interp_tick = 0;
    double interp_alpha = 1.0;                                  // 0 = previous tick, 1 = latest tick
    bool interp_enabled = true;
    int radar_mode = 0; // 0 = every aircraft within range; 1 = only inside the nose cone (RADAR_CONE_DEG)                                 // false = show the latest tick (old behaviour)
    void capture_interp_snapshot();
    Transform3D air_render_transform(::FsAirplane *air) const;
    Transform3D gnd_render_transform(::FsGround *gnd) const;
    Transform3D wpn_render_transform(const ::FsWeapon *wpn) const;

    // Audio bridge: previous-frame state used to turn sim state into one-shot events
    bool audio_initialized = false;
    unsigned int audio_prev_onetime[32] = {0};
    std::vector<int16_t> audio_prev_weapon_code; // per FsWeapon slot: 0 = inactive, else weapon type + 1
    std::unordered_set<int64_t> audio_seen_explosions;
    std::unordered_set<unsigned int> fx_crashed_keys; // aircraft whose crash event was already reported

    void init_materials();
    void clear_scene_nodes();

    Ref<ArrayMesh> build_mesh_from_shell(const YsShellExt &shl);
    void build_scenery_nodes();
    void build_scenery_recursive(const YsScenery *scn, const YsMatrix4x4 &parent_tfm, Node3D *parent_node);
    void sync_visual_entities();
    void apply_cockpit_materials(EntityVisual &ev, bool enabled);
    void build_prewarm_node();

protected:
    static void _bind_methods();

public:
    YSFlightSimulation();
    ~YSFlightSimulation();

    void initialize_simulation();
    void load_yfs(godot::String file_path);
    void log_to_crashlog(godot::String msg);

    godot::Dictionary get_airplane_transforms() const;
    godot::Dictionary get_ground_transforms() const;
    godot::Dictionary get_ground_transform(int64_t key) const; // one object (cheap; for the locked ground target)
    godot::Array get_active_weapons() const;
    godot::Array get_active_explosions() const;
    godot::Transform3D get_player_transform() const;
    godot::Dictionary get_player_telemetry() const;
    godot::PackedVector3Array get_tower_positions() const;
    godot::Color get_sky_color() const;
    godot::Color get_ground_color() const;

    // Benchmark / diagnostics
    godot::PackedFloat64Array get_frame_stats();
    godot::Dictionary get_audio_state();
    void reset_interpolation();
    void set_interpolation_enabled(bool enabled);

    // Flight setup / respawn (placeholder UI in respawn_manager.gd; the real menu will use the same calls)
    godot::PackedStringArray get_airplane_template_names() const;
    godot::PackedStringArray get_start_position_names() const;
    bool is_helicopter_template(godot::String airplane_name) const;
    bool respawn_player(godot::String airplane_name, godot::String start_position, int64_t iff);
    // Radar (radar_scope.gd draws it). Visibility rules live here so they can change without touching the UI.
    godot::Dictionary get_radar_contacts(double range_m);
    void set_radar_mode(int64_t mode);
    // Aircraft visual effects state (damage smoke, fire, vapour, contrails, crash plumes); see aircraft_fx.gd
    godot::Dictionary get_aircraft_fx_state();
    void debug_kill_player(); // test hook: marks the player aircraft dead (used by automated respawn tests)
    void set_random_seed(int64_t seed);
    bool enable_player_autopilot();

    void set_cockpit_cull_mode(bool enabled);
    void set_player_inputs(double elevator, double aileron, double rudder, double throttle);
    // Controls bridge (controls.gd owns stick/rudder/throttle/afterburner/trim; YS handles the rest)
    void set_player_flight_inputs(double elevator, double aileron, double rudder, double throttle, bool afterburner, double trim);
    bool press_button(godot::String function_name);
    void set_player_control(godot::String name, double value);
    bool select_weapon(int64_t weapon_type);
    void set_player_weapon_inputs(
        bool fire_selected_held,
        bool fire_selected_just_pressed,
        bool fire_gun_held,
        bool cycle_weapon_just_pressed,
        bool dispense_flare_just_pressed);

    virtual void _physics_process(double delta) override;
    virtual void _process(double delta) override;
};

} // namespace godot

#endif // YSFLIGHT_SIMULATION_NODE_H
