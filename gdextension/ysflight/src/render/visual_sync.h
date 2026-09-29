#ifndef YSGD_VISUAL_SYNC_H
#define YSGD_VISUAL_SYNC_H

// Mirrors YS aircraft, ground objects and flying ordnance as Godot nodes, once per rendered frame.
// Each DNM model becomes a small node tree (one MeshInstance3D per DNM node); only changed values are
// pushed to Godot (set_transform / set_visible always notify the scene tree and renderer).
//   - Aircraft: every frame, including hardpoint stores; the player's exterior uses back-face culled
//     materials in cockpit view, plus the cockpit shell (like YS SimDrawAirplane).
//   - Ground objects: time-sliced by camera distance (every frame < 2.5 km, every 4th < 8 km, every 16th
//     beyond); settled single-node static props are never touched again.
//   - Weapons: keyed by weapon slot; visuals of finished weapons go to a per-model pool for reuse.

#include <cstdint>
#include <unordered_map>
#include <vector>

#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>

#include "render/materials.h"
#include "render/shell_mesh.h"

class FsSimulation;
class FsAirplane;
class FsVisualDnm;
class YsVec3;

namespace ysgd {

class MotionInterp;

class VisualSync {
public:
    struct Perf {
        double air_ms = 0.0, gnd_ms = 0.0, wpn_ms = 0.0;
        long long gnd_full_updates = 0; // ground objects that went through a full DNM update
        int frames = 0;
    };

    VisualSync(const Materials &materials, ShellMeshCache &meshes) : mats(materials), mesh_cache(meshes) {}
    ~VisualSync();

    // New scene roots (after a mission load); forgets every visual.
    void attach(godot::Node3D *airplanes, godot::Node3D *grounds, godot::Node3D *weapons);
    void sync(FsSimulation *sim, const MotionInterp &interp, const YsVec3 &camera_pos);

    void set_cockpit_mode(bool enabled);

    // A degenerate triangle drawn with the cockpit materials for the first frames after load, so their
    // shaders are compiled before the player first presses F1.
    void build_prewarm(godot::Node3D *parent);
    void step_prewarm();

    size_t airplane_count() const { return airplane_visuals.size(); }
    size_t ground_count() const { return ground_visuals.size(); }
    size_t weapon_count() const { return weapon_visuals.size(); }
    Perf take_perf();

private:
    struct EntityVisual {
        godot::Node3D *root_node = nullptr;
        const void *dnm_ptr = nullptr;
        bool static_settled = false;
        bool cockpit_applied = false;
        std::vector<godot::Node3D *> dnm_nodes;
        std::vector<godot::Node3D *> hardpoint_nodes;
        // Last values pushed to Godot (-1 = unknown)
        int8_t root_visible = -1;
        bool has_root_tfm = false;
        godot::Transform3D root_tfm;
        std::vector<int8_t> node_visible;
        std::vector<godot::Transform3D> node_tfm;
        std::vector<uint8_t> node_has_tfm;
    };
    using VisualTable = std::unordered_map<unsigned int, EntityVisual>;

    void sync_airplanes(FsSimulation *sim, const MotionInterp &interp);
    void sync_cockpit(FsSimulation *sim, const MotionInterp &interp);
    void sync_grounds(FsSimulation *sim, const MotionInterp &interp, const YsVec3 &camera_pos);
    void sync_weapons(FsSimulation *sim, const MotionInterp &interp);

    EntityVisual create_visual(FsVisualDnm &vis, const godot::String &name, godot::Node3D *parent);
    EntityVisual *get_or_create(VisualTable &table, unsigned int key, FsVisualDnm &vis, godot::Node3D *parent, const char *prefix);
    void update_visual(EntityVisual &ev, FsVisualDnm &vis, const godot::Transform3D &root_tfm, bool is_alive, bool is_static_prop);
    void update_hardpoints(EntityVisual &ev, ::FsAirplane *air);
    static void set_root_visible(EntityVisual &ev, bool visible);
    void apply_cockpit_materials(EntityVisual &ev, bool enabled);

    const Materials &mats;
    ShellMeshCache &mesh_cache;

    godot::Node3D *airplanes_root = nullptr;
    godot::Node3D *grounds_root = nullptr;
    godot::Node3D *weapons_root = nullptr;

    VisualTable airplane_visuals;
    VisualTable ground_visuals;
    VisualTable weapon_visuals;  // by FsWeapon slot
    VisualTable cockpit_visuals; // player cockpit shell (F1), by airplane key
    std::unordered_map<const void *, std::vector<EntityVisual>> weapon_pool; // hidden, reusable, by DNM
    std::vector<unsigned int> seen_slots;
    FsVisualDnm *generic_cockpit = nullptr; // aircraft/cockpit1.srf, YS fallback for aircraft without a cockpit

    bool cockpit_mode = false;
    unsigned int cockpit_key = 0;
    bool cockpit_key_valid = false;
    uint32_t ground_frame_index = 0;

    godot::MeshInstance3D *prewarm_node = nullptr;
    int prewarm_frames_left = 0;

    Perf perf;
};

} // namespace ysgd

#endif // YSGD_VISUAL_SYNC_H
