#ifndef YSGD_AIRCRAFT_SHADOWS_H
#define YSGD_AIRCRAFT_SHADOWS_H
// Aircraft shadows like YSFlight's (FsSimulation::SimDrawComplexShadow): the model flattened straight down onto
// the plane of the terrain under the aircraft (FsExistence::terrainOrg / terrainNom), solid black. Within
// FULL_DETAIL_M of the camera the whole model, further away its collision shell (YS DrawApproximatedShadow).
// One MeshInstance3D per aircraft in range (res://shaders/aircraft_shadow.gdshader). The flattening is the
// node's transform, so the meshes are static and shared per aircraft type; per frame this only sets one
// transform per shadow in range.

#include <unordered_map>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/shader_material.hpp>

#include "ysclass.h"

class FsSimulation;
class FsAirplane;

namespace ysgd {

class MotionInterp;

class AircraftShadows {
public:
    void attach(godot::Node3D *parent); // new scene root (after a mission load); forgets everything
    void sync(FsSimulation *sim, const MotionInterp &interp, const YsVec3 &camera_pos);
    void forget_airplane(unsigned int key); // deleted from the sim (AI respawn wreck clean-up)
    void set_enabled(bool on);              // Graphics setting "Aircraft Shadows"

private:
    struct TypeMeshes {
        godot::Ref<godot::ArrayMesh> full, coarse;
    };
    struct Shadow {
        godot::MeshInstance3D *node = nullptr;
        int detail = -1; // mesh in use: 0 coarse, 1 full
        bool visible = false;
        godot::Transform3D tfm;
    };
    const TypeMeshes &meshes_for(FsAirplane *air);

    godot::Node3D *root = nullptr;
    bool enabled = true;
    godot::Ref<godot::ShaderMaterial> mat;
    std::unordered_map<const void *, TypeMeshes> type_meshes; // by DNM
    std::unordered_map<unsigned int, Shadow> shadows;         // by airplane key
};

} // namespace ysgd

#endif // YSGD_AIRCRAFT_SHADOWS_H
