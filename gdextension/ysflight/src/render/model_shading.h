#ifndef YSGD_MODEL_SHADING_H
#define YSGD_MODEL_SHADING_H
// Ground-only shading, computed when a model is first converted and multiplied into its vertex colours.
// Short rays through a coarse voxel copy estimate occlusion; a darker base anchors objects to the ground.
// Aircraft retain their authored paint because coarse occlusion creates patches on thin detail meshes.

#include <unordered_map>

#include "ysclass.h"

class FsVisualDnm;
class YsShellExt;

namespace ysgd {

using VertexShade = std::unordered_map<YSHASHKEY, float>;         // vertex search key -> brightness factor
using ModelShade = std::unordered_map<const void *, VertexShade>; // DNM node (its shell) -> its vertices

ModelShade bake_ground_dnm_shade(FsVisualDnm &vis);
VertexShade bake_shell_shade(const YsShellExt &shell); // one static shell (field scenery), ground style

} // namespace ysgd

#endif // YSGD_MODEL_SHADING_H
