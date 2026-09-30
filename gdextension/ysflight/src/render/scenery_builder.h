#ifndef YSGD_SCENERY_BUILDER_H
#define YSGD_SCENERY_BUILDER_H

#include <godot_cpp/classes/node3d.hpp>

#include "render/materials.h"
#include "render/shell_mesh.h"

class FsSimulation;

namespace ysgd {

// Builds the static field (.fld) under root: map layers (PC2) as one mesh per same-plane group in YS
// painter's order, elevation grids (TER), 3D shells (SRF) and signboards (PLT), recursing into sub-fields.
// Returns the map's dominant colour by area (on island maps: the sea), used for the ground beyond the map.
godot::Color build_scenery(const FsSimulation *sim, godot::Node3D *root, const Materials &mats, ShellMeshCache &meshes);

} // namespace ysgd

#endif // YSGD_SCENERY_BUILDER_H
