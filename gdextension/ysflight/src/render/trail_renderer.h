#ifndef YSGD_TRAIL_RENDERER_H
#define YSGD_TRAIL_RENDERER_H

// Continuous trails drawn as camera-facing ribbons (shader: res://shaders/trail_ribbon.gdshader):
//   - wingtip lines: one thin white line per wingtip while YS reports vapour (high G), longer-lived above
//     CONTRAIL_ALT_M (YSFlight draws its vapour the same way: thin white lines from the wingtips)
//   - missile / rocket / flare smoke
//   - damage smoke (damaged, still flying)
//   - shot-down plume: fire turning into thick charcoal smoke (colour ramp by age in the shader)
// Points are recorded from raw sim positions after every physics tick; each frame the newest point is the
// emitter's interpolated position, so a trail stays attached to the drawn model. When a source stops (vapour
// ends, missile hits, wreck hits the ground) its trail is left behind and fades out point by point.
// All trails are ONE MultiMesh (one draw call); each instance is one segment. The instance buffer is
// rebuilt every frame in C++ and uploaded with a single MultiMesh::set_buffer call.

#include <cstdint>
#include <unordered_map>
#include <vector>

#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

class FsSimulation;

namespace ysgd {

class MotionInterp;

class TrailRenderer {
public:
    // 0 = low (half the points), 1 = medium, 2 = high
    void set_quality(int quality);
    // New scene (after a mission load): creates the MultiMeshInstance3D under parent, forgets all trails.
    void attach(godot::Node3D *parent);
    // After every physics tick (raw sim positions).
    void record(FsSimulation *sim);
    // Every rendered frame. render_time = sim time of what is drawn (interpolated).
    void draw(FsSimulation *sim, const MotionInterp &interp, double render_time, const godot::Vector3 &camera_pos);

    int segment_count() const { return visible_segments; }
    int trail_count() const { return (int)trails.size() - (int)free_list.size(); }
    int death_trail_count() const; // shot-down plumes still drawn (tests)

private:
    enum Style : uint8_t { STYLE_WINGTIP, STYLE_MISSILE, STYLE_FLARE, STYLE_DAMAGE, STYLE_DEATH };
    enum Owner : uint8_t { OWNER_AIRPLANE, OWNER_WEAPON };

    struct Point {
        godot::Vector3 pos;
        float time;        // sim time when recorded
        float life;        // seconds until it has faded out
        float w0, w1;      // width (m) when new / when faded
        float alpha;       // opacity when new
    };
    // What a point is recorded with; the source decides it every tick (e.g. vapour vs contrail).
    struct PointParams {
        float life, w0, w1, alpha;
    };
    struct Trail {
        bool used = false;             // false = free slot in `trails`
        Style style = STYLE_MISSILE;
        Owner owner = OWNER_AIRPLANE;
        unsigned int owner_id = 0;     // airplane search key or weapon slot
        godot::Vector3 local_offset;   // emitter position in the owner's frame (Godot local)
        godot::Color color;
        PointParams params{};          // current emission parameters
        std::vector<Point> pts;        // ring buffer
        int head = -1;                 // newest point
        int count = 0;
        double next_record = 0.0;
        bool emitting = false;
        bool seen = false;             // emitter still present in this record() pass
    };

    struct StyleDef {
        float interval;   // seconds between recorded points (medium quality)
        float fade_pow;   // alpha = alpha0 * (1 - fade)^fade_pow, fade = 0..1 from fade_from to the end of life
        float fade_from;  // age/life where fading starts
        float min_px;     // minimum on-screen width; negative = widen without fading (thin lines)
        int pass;         // draw order: 0 smoke, 2 lines
        bool ramp;        // colour from age (shader ramp) instead of the trail's colour
    };
    static const StyleDef STYLES[];

    int acquire_trail(uint64_t source, Style style, Owner owner, unsigned int owner_id, const godot::Vector3 &local_offset,
                      int max_points);
    void emit(uint64_t source, Style style, Owner owner, unsigned int owner_id, const godot::Vector3 &local_offset,
              const godot::Color &color, const PointParams &params, const godot::Vector3 &world_pos, double now);
    void record_airplanes(FsSimulation *sim, double now);
    void record_weapons(FsSimulation *sim, double now);
    bool emitter_position(FsSimulation *sim, const MotionInterp &interp, const Trail &t, godot::Vector3 &out) const;
    void release_trail(int index);
    void ensure_capacity(int segments);

    std::vector<Trail> trails;
    std::vector<int> free_list;
    std::unordered_map<uint64_t, int> active;   // source -> trail index (emitting trails only)
    std::vector<int16_t> weapon_code;            // per weapon slot: weapon type + 1 at the last record, 0 = none
    std::vector<float> weapon_life;              // per weapon slot: lifeRemain at the last record

    float interval_mult = 1.0f;

    godot::MultiMeshInstance3D *node = nullptr;
    godot::Ref<godot::MultiMesh> multimesh;
    godot::PackedFloat32Array buffer;
    int capacity = 0;
    int visible_segments = 0;
};

} // namespace ysgd

#endif // YSGD_TRAIL_RENDERER_H
