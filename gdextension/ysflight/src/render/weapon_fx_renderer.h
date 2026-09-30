#ifndef YSGD_WEAPON_FX_RENDERER_H
#define YSGD_WEAPON_FX_RENDERER_H

// Bullet/debris tracers and rocket-motor/flare/muzzle glows, once per rendered frame. Each is one MultiMesh whose
// instance buffer is filled in C++ and uploaded in one call (hundreds of bullets used to cost a GDScript
// Dictionary each). Shaders: res://shaders/tracer.gdshader, res://shaders/exhaust_glow.gdshader.

#include <cstdint>

#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

class FsSimulation;

namespace ysgd {

class MotionInterp;

class WeaponFxRenderer {
public:
    void attach(godot::Node3D *parent);
    void draw(FsSimulation *sim, const MotionInterp &interp, uint64_t frame_number);

    int tracer_count() const { return tracers; }
    int glow_count() const { return glows; }

private:
    godot::Ref<godot::MultiMesh> tracer_mm;
    godot::Ref<godot::MultiMesh> glow_mm;
    godot::PackedFloat32Array tracer_buf;
    godot::PackedFloat32Array glow_buf;
    int tracers = 0;
    int glows = 0;
};

} // namespace ysgd

#endif // YSGD_WEAPON_FX_RENDERER_H
