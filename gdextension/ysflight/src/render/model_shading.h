#ifndef YSGD_MODEL_SHADING_H
#define YSGD_MODEL_SHADING_H
// Baked shading for models, computed once per model at load and multiplied into the vertex colours
// (ShellMeshCache), so it costs nothing per frame:
//   - aircraft: a little ambient occlusion (wing roots, intakes, between tail fins) plus a slightly darker
//     belly. Occlusion = short rays from each vertex through a coarse voxel copy of the whole model (all
//     DNM parts together, as currently posed);
//   - ground objects and scenery shells: the same occlusion plus a darker base where they meet the ground.

#include <unordered_map>

#include "ysclass.h"

class FsVisualDnm;
class YsShellExt;

namespace ysgd {

using VertexShade = std::unordered_map<YSHASHKEY, float>;         // vertex search key -> brightness factor
using ModelShade = std::unordered_map<const void *, VertexShade>; // DNM node (its shell) -> its vertices

enum class ShadeKind { AIRCRAFT, GROUND };

ModelShade bake_dnm_shade(FsVisualDnm &vis, ShadeKind kind);
VertexShade bake_shell_shade(const YsShellExt &shell); // one static shell (field scenery), ground style

} // namespace ysgd

#endif // YSGD_MODEL_SHADING_H
