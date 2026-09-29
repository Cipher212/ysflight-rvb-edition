#include "ysflight_simulation_node.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/plane_mesh.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <direct.h>
#include <cstdio>
#include <ctime>
#include <csignal>
#include <chrono>
#include <algorithm>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#include "fsworld.h"
#include "fssimulation.h"
#include "fsexistence.h"
#include "fsdef.h"
#include "fsproperty.h"
#include "fsfilename.h"
#include "fsfield.h"
#include "fsvisual.h"
#include "fsdogfightautopilot.h"
#include "fsairsoundbridge.h"
#include "ysscenery.h"

// FsProgramName is declared extern in fsfilename.cpp (normally defined in fsmain.cpp
// which we don't compile). Providing it here prevents a null-pointer crash when
// FsGetUserYsflightDir() tries to build a path using this name.
const wchar_t *FsProgramName = L"YSFLIGHT";
const char *FsProgramTitle = "YSFLIGHT";

using namespace godot;

// ============================================================================
// Automatic Crash & Session Logger (writes to <game folder>/crashlog/, set in init_crashlog_system)
// ============================================================================

static FILE *g_session_log_fp = nullptr;
static wchar_t g_crashlog_dir[512] = L"crashlog"; // replaced by init_crashlog_system()
static volatile const char *g_crash_breadcrumb = "uninitialized";
static volatile uint64_t g_physics_frame_count = 0;
static volatile double g_last_sim_time = 0.0;
static volatile int g_last_airplane_count = 0;
static volatile int g_last_weapon_count = 0;
static bool g_crash_handlers_installed = false;

static void write_log_line(const char *msg) {
    if (g_session_log_fp != nullptr) {
        std::time_t now = std::time(nullptr);
        struct tm tbuf;
        localtime_s(&tbuf, &now);
        fprintf(g_session_log_fp, "[%02d:%02d:%02d] [Frame %llu | SimT %.2fs] %s\n",
                tbuf.tm_hour, tbuf.tm_min, tbuf.tm_sec,
                (unsigned long long)g_physics_frame_count, g_last_sim_time, msg);
        fflush(g_session_log_fp);
    }
}

#ifdef _WIN32
static const char *exception_code_to_string(DWORD code) {
    switch (code) {
        case EXCEPTION_ACCESS_VIOLATION: return "EXCEPTION_ACCESS_VIOLATION (0xC0000005)";
        case EXCEPTION_ARRAY_BOUNDS_EXCEEDED: return "EXCEPTION_ARRAY_BOUNDS_EXCEEDED";
        case EXCEPTION_DATATYPE_MISALIGNMENT: return "EXCEPTION_DATATYPE_MISALIGNMENT";
        case EXCEPTION_FLT_DIVIDE_BY_ZERO: return "EXCEPTION_FLT_DIVIDE_BY_ZERO";
        case EXCEPTION_ILLEGAL_INSTRUCTION: return "EXCEPTION_ILLEGAL_INSTRUCTION";
        case EXCEPTION_IN_PAGE_ERROR: return "EXCEPTION_IN_PAGE_ERROR";
        case EXCEPTION_INT_DIVIDE_BY_ZERO: return "EXCEPTION_INT_DIVIDE_BY_ZERO";
        case EXCEPTION_PRIV_INSTRUCTION: return "EXCEPTION_PRIV_INSTRUCTION";
        case EXCEPTION_STACK_OVERFLOW: return "EXCEPTION_STACK_OVERFLOW (0xC00000FD)";
        default: return "UNKNOWN_HARDWARE_EXCEPTION";
    }
}

static void write_crash_dump_file(EXCEPTION_POINTERS *ep, const char *source_tag) {
    wchar_t crash_path[600];
    swprintf(crash_path, 600, L"%ls\\crash_report.txt", g_crashlog_dir);
    FILE *cfp = _wfopen(crash_path, L"a");
    FILE *targets[2] = { cfp, g_session_log_fp };

    std::time_t now = std::time(nullptr);
    struct tm tbuf;
    localtime_s(&tbuf, &now);

    for (int i = 0; i < 2; ++i) {
        FILE *fp = targets[i];
        if (fp == nullptr) continue;
        fprintf(fp, "\n============================================================\n");
        fprintf(fp, "YSFLIGHT-GODOT CRASH REPORT (%04d-%02d-%02d %02d:%02d:%02d)\n",
                tbuf.tm_year + 1900, tbuf.tm_mon + 1, tbuf.tm_mday,
                tbuf.tm_hour, tbuf.tm_min, tbuf.tm_sec);
        fprintf(fp, "Handler Source   : %s\n", source_tag);
        fprintf(fp, "Last Breadcrumb  : %s\n", g_crash_breadcrumb ? (const char *)g_crash_breadcrumb : "none");
        fprintf(fp, "Physics Frame    : %llu\n", (unsigned long long)g_physics_frame_count);
        fprintf(fp, "Simulation Time  : %.3f sec\n", g_last_sim_time);
        fprintf(fp, "Active Airplanes : %d\n", g_last_airplane_count);
        fprintf(fp, "Active Weapons   : %d\n", g_last_weapon_count);

        if (ep != nullptr && ep->ExceptionRecord != nullptr) {
            DWORD code = ep->ExceptionRecord->ExceptionCode;
            void *addr = ep->ExceptionRecord->ExceptionAddress;
            fprintf(fp, "Exception Code   : 0x%08lX (%s)\n", (unsigned long)code, exception_code_to_string(code));
            fprintf(fp, "Fault Address    : 0x%p\n", addr);

            if (code == EXCEPTION_ACCESS_VIOLATION && ep->ExceptionRecord->NumberParameters >= 2) {
                ULONG_PTR op = ep->ExceptionRecord->ExceptionInformation[0];
                ULONG_PTR target_addr = ep->ExceptionRecord->ExceptionInformation[1];
                fprintf(fp, "Access Type      : %s at address 0x%p\n",
                        (op == 0) ? "READ" : (op == 1) ? "WRITE" : "EXECUTE",
                        (void *)target_addr);
            }

            HMODULE hMod = nullptr;
            if (GetModuleHandleExA(
                    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                    (LPCSTR)addr, &hMod) && hMod != nullptr) {
                char mod_name[MAX_PATH] = {0};
                GetModuleFileNameA(hMod, mod_name, MAX_PATH);
                uintptr_t offset = (uintptr_t)addr - (uintptr_t)hMod;
                fprintf(fp, "Faulting Module  : %s + 0x%llX\n", mod_name, (unsigned long long)offset);
            }
        }
        fprintf(fp, "============================================================\n");
        fflush(fp);
    }
    if (cfp != nullptr) {
        fclose(cfp);
    }
}

static LONG WINAPI ysflight_vectored_exception_handler(EXCEPTION_POINTERS *ep) {
    if (ep != nullptr && ep->ExceptionRecord != nullptr) {
        DWORD c = ep->ExceptionRecord->ExceptionCode;
        if (c == EXCEPTION_ACCESS_VIOLATION ||
            c == EXCEPTION_STACK_OVERFLOW ||
            c == EXCEPTION_INT_DIVIDE_BY_ZERO ||
            c == EXCEPTION_ILLEGAL_INSTRUCTION ||
            c == EXCEPTION_ARRAY_BOUNDS_EXCEEDED) {
            write_crash_dump_file(ep, "VectoredExceptionHandler");
        }
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static LONG WINAPI ysflight_unhandled_exception_filter(EXCEPTION_POINTERS *ep) {
    write_crash_dump_file(ep, "UnhandledExceptionFilter");
    return EXCEPTION_EXECUTE_HANDLER;
}
#endif

static void ysflight_signal_handler(int sig) {
    const char *sig_name = (sig == SIGSEGV) ? "SIGSEGV" : (sig == SIGABRT) ? "SIGABRT" : "SIGNAL";
#ifdef _WIN32
    write_crash_dump_file(nullptr, sig_name);
#else
    write_log_line(sig_name);
#endif
}

static void init_crashlog_system(const String &res_global_path) {
    // Place crashlog folder at workspace root (parent of godot_project)
    String base_dir = res_global_path.trim_suffix("/").trim_suffix("\\");
    int slash_idx = (int)base_dir.rfind("/");
    int bslash_idx = (int)base_dir.rfind("\\");
    int cut = (slash_idx > bslash_idx) ? slash_idx : bslash_idx;
    String crash_dir_str = (cut > 0) ? (base_dir.substr(0, cut) + "/crashlog") : (base_dir + "/crashlog");

    Char16String wdir = crash_dir_str.utf16();
    wcsncpy_s(g_crashlog_dir, 512, (const wchar_t *)wdir.get_data(), _TRUNCATE);
    _wmkdir(g_crashlog_dir);

    if (g_session_log_fp == nullptr) {
        wchar_t latest_path[600];
        swprintf(latest_path, 600, L"%ls\\latest_run.txt", g_crashlog_dir);
        g_session_log_fp = _wfopen(latest_path, L"w");
        write_log_line("=== YSFlight-Godot Session Log Initialized ===");
    }

    if (!g_crash_handlers_installed) {
#ifdef _WIN32
        AddVectoredExceptionHandler(0, ysflight_vectored_exception_handler);
        SetUnhandledExceptionFilter(ysflight_unhandled_exception_filter);
#endif
        std::signal(SIGSEGV, ysflight_signal_handler);
        std::signal(SIGABRT, ysflight_signal_handler);
        g_crash_handlers_installed = true;
        write_log_line("Installed Windows SEH Vectored + Unhandled Exception + Signal crash handlers.");
    }
}

// ============================================================================
// Coordinate & Transform Helpers (YSFlight Left-Handed +Z Forward -> Godot Right-Handed -Z Forward)
// Reflection matrix S = diag(1, 1, -1)
// ============================================================================

static inline Vector3 ys_to_godot_pos(const YsVec3 &v) {
    return Vector3((real_t)v.x(), (real_t)v.y(), (real_t)-v.z());
}

static inline Vector3 ys_to_godot_normal(const YsVec3 &n) {
    Vector3 gn((real_t)n.x(), (real_t)n.y(), (real_t)-n.z());
    if (gn.length_squared() > 1e-12f) {
        return gn.normalized();
    }
    return Vector3(0.0f, 1.0f, 0.0f);
}

static inline Color ys_to_godot_color(const YsColor &c) {
    return Color((float)c.Rd(), (float)c.Gd(), (float)c.Bd(), (float)c.Ad());
}

static inline Transform3D ys_matrix_to_godot_transform(const YsMatrix4x4 &m);

static inline Transform3D ys_to_godot_transform(const YsVec3 &pos, const YsAtt3 &att) {
    YsMatrix4x4 m;
    m.Initialize();
    m.Translate(pos);
    m.RotateXZ(att.h());
    m.RotateZY(att.p());
    m.RotateXY(att.b());
    return ys_matrix_to_godot_transform(m);
}

static inline Transform3D ys_matrix_to_godot_transform(const YsMatrix4x4 &m) {
    // Similarity transform M_godot = S * M_ys * S where S = diag(1, 1, -1, 1)
    Basis basis(
        (real_t) m.v(1, 1), (real_t) m.v(1, 2), (real_t)-m.v(1, 3),
        (real_t) m.v(2, 1), (real_t) m.v(2, 2), (real_t)-m.v(2, 3),
        (real_t)-m.v(3, 1), (real_t)-m.v(3, 2), (real_t) m.v(3, 3)
    );
    Vector3 origin((real_t)m.v(1, 4), (real_t)m.v(2, 4), (real_t)-m.v(3, 4));
    return Transform3D(basis, origin);
}

static inline void add_oriented_triangle(
    PackedVector3Array &verts,
    PackedVector3Array &norms,
    PackedColorArray &cols,
    const Vector3 &p0, const Vector3 &p1, const Vector3 &p2,
    const Vector3 &n0, const Vector3 &n1, const Vector3 &n2,
    const Vector3 &face_n,
    const Color &c0, const Color &c1, const Color &c2)
{
    // In Godot 3D, clockwise triangles are front-facing, meaning (p1-p0).cross(p2-p0)
    // points opposite to the front-face normal (dot < 0). Ensuring winding matches face_n
    // prevents Godot's fragment shader from inverting NORMAL when CULL_DISABLED is active.
    if ((p1 - p0).cross(p2 - p0).dot(face_n) > 0.0f) {
        verts.push_back(p0); verts.push_back(p2); verts.push_back(p1);
        norms.push_back(n0); norms.push_back(n2); norms.push_back(n1);
        cols.push_back(c0);  cols.push_back(c2);  cols.push_back(c1);
    } else {
        verts.push_back(p0); verts.push_back(p1); verts.push_back(p2);
        norms.push_back(n0); norms.push_back(n1); norms.push_back(n2);
        cols.push_back(c0);  cols.push_back(c1);  cols.push_back(c2);
    }
}

static inline void add_oriented_triangle_uv(
    PackedVector3Array &verts,
    PackedVector3Array &norms,
    PackedColorArray &cols,
    PackedVector2Array &uvs,
    const Vector3 &p0, const Vector3 &p1, const Vector3 &p2,
    const Vector3 &n0, const Vector3 &n1, const Vector3 &n2,
    const Vector3 &face_n,
    const Color &c0, const Color &c1, const Color &c2,
    const Vector2 &uv)
{
    add_oriented_triangle(verts, norms, cols, p0, p1, p2, n0, n1, n2, face_n, c0, c1, c2);
    uvs.push_back(uv);
    uvs.push_back(uv);
    uvs.push_back(uv);
}

// ============================================================================
// YSFlightSimulation Implementation
// ============================================================================

void YSFlightSimulation::_bind_methods() {
    ClassDB::bind_method(D_METHOD("initialize_simulation"), &YSFlightSimulation::initialize_simulation);
    ClassDB::bind_method(D_METHOD("load_yfs", "file_path"), &YSFlightSimulation::load_yfs);
    ClassDB::bind_method(D_METHOD("log_to_crashlog", "msg"), &YSFlightSimulation::log_to_crashlog);
    ClassDB::bind_method(D_METHOD("get_airplane_transforms"), &YSFlightSimulation::get_airplane_transforms);
    ClassDB::bind_method(D_METHOD("get_ground_transforms"), &YSFlightSimulation::get_ground_transforms);
    ClassDB::bind_method(D_METHOD("get_ground_transform", "key"), &YSFlightSimulation::get_ground_transform);
    ClassDB::bind_method(D_METHOD("get_active_weapons"), &YSFlightSimulation::get_active_weapons);
    ClassDB::bind_method(D_METHOD("get_active_explosions"), &YSFlightSimulation::get_active_explosions);
    ClassDB::bind_method(D_METHOD("get_player_transform"), &YSFlightSimulation::get_player_transform);
    ClassDB::bind_method(D_METHOD("get_player_telemetry"), &YSFlightSimulation::get_player_telemetry);
    ClassDB::bind_method(D_METHOD("get_tower_positions"), &YSFlightSimulation::get_tower_positions);
    ClassDB::bind_method(D_METHOD("get_sky_color"), &YSFlightSimulation::get_sky_color);
    ClassDB::bind_method(D_METHOD("get_ground_color"), &YSFlightSimulation::get_ground_color);
    ClassDB::bind_method(D_METHOD("get_frame_stats"), &YSFlightSimulation::get_frame_stats);
    ClassDB::bind_method(D_METHOD("get_audio_state"), &YSFlightSimulation::get_audio_state);
    ClassDB::bind_method(D_METHOD("reset_interpolation"), &YSFlightSimulation::reset_interpolation);
    ClassDB::bind_method(D_METHOD("set_interpolation_enabled", "enabled"), &YSFlightSimulation::set_interpolation_enabled);
    ClassDB::bind_method(D_METHOD("get_airplane_template_names"), &YSFlightSimulation::get_airplane_template_names);
    ClassDB::bind_method(D_METHOD("get_start_position_names"), &YSFlightSimulation::get_start_position_names);
    ClassDB::bind_method(D_METHOD("is_helicopter_template", "airplane_name"), &YSFlightSimulation::is_helicopter_template);
    ClassDB::bind_method(D_METHOD("respawn_player", "airplane_name", "start_position", "iff"), &YSFlightSimulation::respawn_player);
    ClassDB::bind_method(D_METHOD("debug_kill_player"), &YSFlightSimulation::debug_kill_player);
    ClassDB::bind_method(D_METHOD("get_radar_contacts", "range_m"), &YSFlightSimulation::get_radar_contacts);
    ClassDB::bind_method(D_METHOD("set_radar_mode", "mode"), &YSFlightSimulation::set_radar_mode);
    ClassDB::bind_method(D_METHOD("get_aircraft_fx_state"), &YSFlightSimulation::get_aircraft_fx_state);
    ClassDB::bind_method(D_METHOD("set_random_seed", "seed"), &YSFlightSimulation::set_random_seed);
    ClassDB::bind_method(D_METHOD("enable_player_autopilot"), &YSFlightSimulation::enable_player_autopilot);
    ClassDB::bind_method(D_METHOD("set_cockpit_cull_mode", "enabled"), &YSFlightSimulation::set_cockpit_cull_mode);
    ClassDB::bind_method(D_METHOD("set_player_inputs", "elevator", "aileron", "rudder", "throttle"), &YSFlightSimulation::set_player_inputs);
    ClassDB::bind_method(D_METHOD("set_player_flight_inputs", "elevator", "aileron", "rudder", "throttle", "afterburner", "trim"), &YSFlightSimulation::set_player_flight_inputs);
    ClassDB::bind_method(D_METHOD("press_button", "function_name"), &YSFlightSimulation::press_button);
    ClassDB::bind_method(D_METHOD("set_player_control", "name", "value"), &YSFlightSimulation::set_player_control);
    ClassDB::bind_method(D_METHOD("select_weapon", "weapon_type"), &YSFlightSimulation::select_weapon);
    ClassDB::bind_method(D_METHOD("set_player_weapon_inputs",
        "fire_selected_held",
        "fire_selected_just_pressed",
        "fire_gun_held",
        "cycle_weapon_just_pressed",
        "dispense_flare_just_pressed"), &YSFlightSimulation::set_player_weapon_inputs);
}

YSFlightSimulation::YSFlightSimulation() {
    world = nullptr;
    sim = nullptr;
    scenery_root = nullptr;
    airplanes_root = nullptr;
    grounds_root = nullptr;
    weapons_root = nullptr;
}

YSFlightSimulation::~YSFlightSimulation() {
    delete generic_cockpit;
    generic_cockpit = nullptr;
    shell_mesh_cache.clear();
    airplane_visuals.clear();
    ground_visuals.clear();
    weapon_visuals.clear();
    if (world != nullptr) {
        delete world;
        world = nullptr;
    }
}

void YSFlightSimulation::init_materials() {
    if (mat_lit.is_valid()) {
        return;
    }

    mat_lit.instantiate();
    mat_lit->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    mat_lit->set_flag(BaseMaterial3D::FLAG_SRGB_VERTEX_COLOR, true);
    mat_lit->set_cull_mode(BaseMaterial3D::CULL_DISABLED);
    mat_lit->set_shading_mode(BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    mat_lit->set_roughness(0.55f);
    mat_lit->set_specular(0.35f);

    mat_bright.instantiate();
    mat_bright->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    mat_bright->set_flag(BaseMaterial3D::FLAG_SRGB_VERTEX_COLOR, true);
    mat_bright->set_cull_mode(BaseMaterial3D::CULL_DISABLED);
    mat_bright->set_shading_mode(BaseMaterial3D::SHADING_MODE_UNSHADED);

    mat_trans.instantiate();
    mat_trans->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    mat_trans->set_flag(BaseMaterial3D::FLAG_SRGB_VERTEX_COLOR, true);
    mat_trans->set_cull_mode(BaseMaterial3D::CULL_DISABLED);
    mat_trans->set_shading_mode(BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    mat_trans->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
    mat_trans->set_roughness(0.2f);
    mat_trans->set_specular(0.6f);

    // Cockpit (F1) variants: identical except back-face culling. Separate, permanent materials so
    // entering/leaving the cockpit view never triggers a shader recompile (that caused 55-90 ms hitches).
    mat_lit_cockpit.instantiate();
    mat_lit_cockpit->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    mat_lit_cockpit->set_flag(BaseMaterial3D::FLAG_SRGB_VERTEX_COLOR, true);
    mat_lit_cockpit->set_cull_mode(BaseMaterial3D::CULL_BACK);
    mat_lit_cockpit->set_shading_mode(BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    mat_lit_cockpit->set_roughness(0.55f);
    mat_lit_cockpit->set_specular(0.35f);

    mat_trans_cockpit.instantiate();
    mat_trans_cockpit->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    mat_trans_cockpit->set_flag(BaseMaterial3D::FLAG_SRGB_VERTEX_COLOR, true);
    mat_trans_cockpit->set_cull_mode(BaseMaterial3D::CULL_BACK);
    mat_trans_cockpit->set_shading_mode(BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    mat_trans_cockpit->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
    mat_trans_cockpit->set_roughness(0.2f);
    mat_trans_cockpit->set_specular(0.6f);

    mat_terrain.instantiate();
    mat_terrain->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    mat_terrain->set_flag(BaseMaterial3D::FLAG_SRGB_VERTEX_COLOR, true);
    mat_terrain->set_cull_mode(BaseMaterial3D::CULL_DISABLED);
    mat_terrain->set_shading_mode(BaseMaterial3D::SHADING_MODE_PER_PIXEL);
    mat_terrain->set_roughness(1.0f);
    mat_terrain->set_specular_mode(BaseMaterial3D::SPECULAR_DISABLED);

    mat_point.instantiate();
    mat_point->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    mat_point->set_flag(BaseMaterial3D::FLAG_SRGB_VERTEX_COLOR, true);
    mat_point->set_flag(BaseMaterial3D::FLAG_USE_POINT_SIZE, true);
    mat_point->set_point_size(4.0f);
    mat_point->set_cull_mode(BaseMaterial3D::CULL_DISABLED);
    mat_point->set_shading_mode(BaseMaterial3D::SHADING_MODE_UNSHADED);

    // Depth-biased opaque ShaderMaterials for coplanar 2D Maps (PC2) and Signboards (PLT).
    // Vertices stay at exact physical y=0.0 in world space (so aircraft wheels never sink),
    // while UV.x carries the signed layer index to bias clip-space depth along the camera ray
    // without moving 2D screen (X, Y) coordinates or breaking SSAO/Fog depth buffers.
    Ref<Shader> shd_map_poly;
    shd_map_poly.instantiate();
    shd_map_poly->set_code(
        "shader_type spatial;\n"
        "render_mode cull_disabled, specular_disabled;\n"
        "void vertex() {\n"
        "    if (!OUTPUT_IS_SRGB) {\n"
        "        COLOR.rgb = mix(\n"
        "            pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)),\n"
        "            COLOR.rgb * (1.0 / 12.92),\n"
        "            lessThan(COLOR.rgb, vec3(0.04045))\n"
        "        );\n"
        "    }\n"
        "    vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);\n"
        "    view_pos.xyz *= (1.0 - UV.x * 0.000015);\n"
        "    POSITION = PROJECTION_MATRIX * view_pos;\n"
        "}\n"
        "void fragment() {\n"
        "    ALBEDO = COLOR.rgb;\n"
        "    ROUGHNESS = 1.0;\n"
        "    SPECULAR = 0.0;\n"
        "}\n"
    );
    mat_map_poly.instantiate();
    mat_map_poly->set_shader(shd_map_poly);

    Ref<Shader> shd_map_line;
    shd_map_line.instantiate();
    shd_map_line->set_code(
        "shader_type spatial;\n"
        "render_mode unshaded, cull_disabled;\n"
        "void vertex() {\n"
        "    if (!OUTPUT_IS_SRGB) {\n"
        "        COLOR.rgb = mix(\n"
        "            pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)),\n"
        "            COLOR.rgb * (1.0 / 12.92),\n"
        "            lessThan(COLOR.rgb, vec3(0.04045))\n"
        "        );\n"
        "    }\n"
        "    vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);\n"
        "    view_pos.xyz *= (1.0 - UV.x * 0.000015);\n"
        "    POSITION = PROJECTION_MATRIX * view_pos;\n"
        "}\n"
        "void fragment() {\n"
        "    ALBEDO = COLOR.rgb;\n"
        "}\n"
    );
    mat_map_line.instantiate();
    mat_map_line->set_shader(shd_map_line);

    Ref<Shader> shd_map_point;
    shd_map_point.instantiate();
    shd_map_point->set_code(
        "shader_type spatial;\n"
        "render_mode unshaded, cull_disabled;\n"
        "void vertex() {\n"
        "    if (!OUTPUT_IS_SRGB) {\n"
        "        COLOR.rgb = mix(\n"
        "            pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)),\n"
        "            COLOR.rgb * (1.0 / 12.92),\n"
        "            lessThan(COLOR.rgb, vec3(0.04045))\n"
        "        );\n"
        "    }\n"
        "    POINT_SIZE = 4.0;\n"
        "    vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);\n"
        "    view_pos.xyz *= (1.0 - UV.x * 0.000015);\n"
        "    POSITION = PROJECTION_MATRIX * view_pos;\n"
        "}\n"
        "void fragment() {\n"
        "    ALBEDO = COLOR.rgb;\n"
        "}\n"
    );
    mat_map_point.instantiate();
    mat_map_point->set_shader(shd_map_point);
}

void YSFlightSimulation::clear_scene_nodes() {
    airplane_visuals.clear();
    ground_visuals.clear();
    weapon_visuals.clear();
    weapon_pool.clear();
    cockpit_visuals.clear();
    shell_mesh_cache.clear();
    audio_initialized = false;
    audio_prev_weapon_code.clear();
    audio_seen_explosions.clear();
    fx_crashed_keys.clear();
    cockpit_key_valid = false;
    prewarm_node = nullptr; // child of scenery_root, freed with it
    prewarm_frames_left = 0;

    if (scenery_root != nullptr) {
        scenery_root->queue_free();
        scenery_root = nullptr;
    }
    if (airplanes_root != nullptr) {
        airplanes_root->queue_free();
        airplanes_root = nullptr;
    }
    if (grounds_root != nullptr) {
        grounds_root->queue_free();
        grounds_root = nullptr;
    }
    if (weapons_root != nullptr) {
        weapons_root->queue_free();
        weapons_root = nullptr;
    }

    scenery_root = memnew(Node3D);
    scenery_root->set_name("SceneryRoot");
    add_child(scenery_root);

    airplanes_root = memnew(Node3D);
    airplanes_root->set_name("AirplanesRoot");
    add_child(airplanes_root);

    grounds_root = memnew(Node3D);
    grounds_root->set_name("GroundsRoot");
    add_child(grounds_root);

    weapons_root = memnew(Node3D);
    weapons_root->set_name("WeaponsRoot");
    add_child(weapons_root);
}

void YSFlightSimulation::initialize_simulation() {
    // Physics: run AFTER every other node so player inputs set in the same tick are simulated
    // immediately (no extra tick of input latency). Process: run BEFORE every other node so the
    // camera, HUD and effects read this frame's interpolated transforms.
    set_physics_process_priority(100);
    set_process_priority(-100);
    godot::String res_path = godot::ProjectSettings::get_singleton()->globalize_path("res://");
    init_crashlog_system(res_path);
    g_crash_breadcrumb = "initialize_simulation: new FsWorld";
    write_log_line("initialize_simulation() called.");

    UtilityFunctions::print("YSFlight: Initializing FsWorld...");
    init_materials();
    if (world != nullptr) {
        delete world;
    }
    world = new FsWorld();
    sim = nullptr;
    g_crash_breadcrumb = "initialize_simulation: done";
    write_log_line("FsWorld initialized successfully.");
    UtilityFunctions::print("YSFlight: FsWorld initialized successfully in memory!");
}

void YSFlightSimulation::log_to_crashlog(godot::String msg) {
    write_log_line(msg.utf8().get_data());
}

// ============================================================================
// .SRF / .DNM Shell to Godot ArrayMesh Converter
// ============================================================================

Ref<ArrayMesh> YSFlightSimulation::build_mesh_from_shell(const YsShellExt &shl) {
    const void *cache_key = static_cast<const void *>(&shl);
    auto it = shell_mesh_cache.find(cache_key);
    if (it != shell_mesh_cache.end()) {
        return it->second;
    }

    // 1. Precompute smooth vertex normals for vertices marked with 'R' (IsRound)
    // Accumulating over AllPolygon() avoids requiring a SearchTable attached to shl.
    YsHashTable<YsVec3> vtx_nom_hash;
    for (auto plHd : shl.AllPolygon()) {
        int nVt = 0;
        const YsShellVertexHandle *vtIdx = nullptr;
        shl.GetVertexListOfPolygon(nVt, vtIdx, plHd);
        if (nVt < 3) {
            continue;
        }
        YsVec3 plNom;
        shl.GetNormal(plNom, plHd);
        if (plNom == YsOrigin()) {
            YsArray<YsVec3, 16> pts(nVt, nullptr);
            for (int i = 0; i < nVt; ++i) {
                shl.GetVertexPosition(pts[i], vtIdx[i]);
            }
            YsGetAverageNormalVector(plNom, nVt, pts);
        }
        if (plNom == YsOrigin()) {
            continue;
        }
        for (int i = 0; i < nVt; ++i) {
            const YsShellExt::VertexAttrib *vtAttr = shl.GetVertexAttrib(vtIdx[i]);
            if (vtAttr != nullptr && vtAttr->IsRound() == YSTRUE) {
                const auto vkey = shl.GetSearchKey(vtIdx[i]);
                YsVec3 cur = YsOrigin();
                vtx_nom_hash.FindElement(cur, vkey);
                vtx_nom_hash.UpdateElement(vkey, cur + plNom);
            }
        }
    }

    // 2. Three buckets: LIT (shaded opaque), BRIGHT (unshaded opaque), TRANS (alpha < 0.99)
    PackedVector3Array lit_verts, lit_norms;
    PackedColorArray lit_cols;

    PackedVector3Array bright_verts, bright_norms;
    PackedColorArray bright_cols;

    PackedVector3Array trans_verts, trans_norms;
    PackedColorArray trans_cols;

    for (auto plHd : shl.AllPolygon()) {
        int nPlVt = 0;
        const YsShellVertexHandle *plVtHd = nullptr;
        shl.GetVertexListOfPolygon(nPlVt, plVtHd, plHd);
        if (nPlVt < 3) {
            continue;
        }

        YsArray<YsVec3, 16> plg(nPlVt, nullptr);
        YsArray<YsVec3, 16> vtxNoms(nPlVt, nullptr);

        YsVec3 faceNom;
        shl.GetNormal(faceNom, plHd);

        for (int i = 0; i < nPlVt; ++i) {
            shl.GetVertexPosition(plg[i], plVtHd[i]);
        }

        if (faceNom == YsOrigin()) {
            YsGetAverageNormalVector(faceNom, nPlVt, plg);
        }

        for (int i = 0; i < nPlVt; ++i) {
            YsVec3 smoothNom;
            if (vtx_nom_hash.FindElement(smoothNom, shl.GetSearchKey(plVtHd[i])) == YSOK && smoothNom != YsOrigin()) {
                vtxNoms[i] = smoothNom;
            } else {
                vtxNoms[i] = faceNom;
            }
        }

        YsColor plCol;
        shl.GetColor(plCol, plHd);
        Color gcol = ys_to_godot_color(plCol);

        const YsShellExt::PolygonAttrib *plAttr = shl.GetPolygonAttrib(plHd);
        bool is_bright = (plAttr != nullptr && plAttr->GetNoShading() == YSTRUE);
        bool is_trans = (gcol.a < 0.99f);

        PackedVector3Array *target_verts = &lit_verts;
        PackedVector3Array *target_norms = &lit_norms;
        PackedColorArray *target_cols = &lit_cols;

        if (is_trans) {
            target_verts = &trans_verts;
            target_norms = &trans_norms;
            target_cols = &trans_cols;
        } else if (is_bright) {
            target_verts = &bright_verts;
            target_norms = &bright_norms;
            target_cols = &bright_cols;
        }

        Vector3 gface_n = ys_to_godot_normal(faceNom);

        if (nPlVt == 3 || YsCheckConvex3(nPlVt, plg) == YSTRUE) {
            Vector3 p0 = ys_to_godot_pos(plg[0]);
            Vector3 n0 = ys_to_godot_normal(vtxNoms[0]);
            for (int i = 1; i < nPlVt - 1; ++i) {
                Vector3 p1 = ys_to_godot_pos(plg[i]);
                Vector3 p2 = ys_to_godot_pos(plg[i + 1]);
                Vector3 n1 = ys_to_godot_normal(vtxNoms[i]);
                Vector3 n2 = ys_to_godot_normal(vtxNoms[i + 1]);
                add_oriented_triangle(*target_verts, *target_norms, *target_cols,
                    p0, p1, p2, n0, n1, n2, gface_n, gcol, gcol, gcol);
            }
        } else {
            // Concave polygon: triangulate using YsSword
            YsSword sword;
            YsArray<int, 16> idx(nPlVt, nullptr);
            for (int i = 0; i < nPlVt; ++i) {
                idx[i] = i;
            }
            if (sword.SetInitialPolygon(nPlVt, plg, idx) == YSOK && sword.Triangulate() == YSOK) {
                for (int i = 0; i < sword.GetNumPolygon(); ++i) {
                    const YsArray<YsVec3> *tri = sword.GetPolygon(i);
                    const YsArray<int> *triIdx = sword.GetVertexIdList(i);
                    if (tri != nullptr && triIdx != nullptr && tri->GetN() >= 3) {
                        Vector3 p0 = ys_to_godot_pos((*tri)[0]);
                        Vector3 n0 = (0 <= (*triIdx)[0] && (*triIdx)[0] < nPlVt)
                            ? ys_to_godot_normal(vtxNoms[(*triIdx)[0]]) : gface_n;
                        for (int j = 1; j < tri->GetN() - 1; ++j) {
                            Vector3 p1 = ys_to_godot_pos((*tri)[j]);
                            Vector3 p2 = ys_to_godot_pos((*tri)[j + 1]);
                            Vector3 n1 = (0 <= (*triIdx)[j] && (*triIdx)[j] < nPlVt)
                                ? ys_to_godot_normal(vtxNoms[(*triIdx)[j]]) : gface_n;
                            Vector3 n2 = (0 <= (*triIdx)[j + 1] && (*triIdx)[j + 1] < nPlVt)
                                ? ys_to_godot_normal(vtxNoms[(*triIdx)[j + 1]]) : gface_n;
                            add_oriented_triangle(*target_verts, *target_norms, *target_cols,
                                p0, p1, p2, n0, n1, n2, gface_n, gcol, gcol, gcol);
                        }
                    }
                }
            }
        }
    }

    Ref<ArrayMesh> mesh;
    mesh.instantiate();

    auto append_surface = [&](const PackedVector3Array &v, const PackedVector3Array &n, const PackedColorArray &c, const Ref<StandardMaterial3D> &mat) {
        if (v.is_empty()) {
            return;
        }
        Array arrays;
        arrays.resize(Mesh::ARRAY_MAX);
        arrays[Mesh::ARRAY_VERTEX] = v;
        arrays[Mesh::ARRAY_NORMAL] = n;
        arrays[Mesh::ARRAY_COLOR] = c;
        int surf_idx = mesh->get_surface_count();
        mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
        mesh->surface_set_material(surf_idx, mat);
    };

    append_surface(lit_verts, lit_norms, lit_cols, mat_lit);
    append_surface(bright_verts, bright_norms, bright_cols, mat_bright);
    append_surface(trans_verts, trans_norms, trans_cols, mat_trans);

    shell_mesh_cache[cache_key] = mesh;
    return mesh;
}

// ============================================================================
// .FLD Scenery Builder (PC2 2D Maps, TER Elevation Grids, SRF Shells, PLT Signboards)
// ============================================================================

static void append_2d_drawing_to_buffers(
    const Ys2DDrawing &drw,
    const YsMatrix4x4 &world_tfm,
    bool map_mode,
    int &elem_counter,
    PackedVector3Array &tri_verts,
    PackedVector3Array &tri_norms,
    PackedColorArray &tri_cols,
    PackedVector2Array &tri_uvs,
    PackedVector3Array &line_verts,
    PackedColorArray &line_cols,
    PackedVector2Array &line_uvs,
    PackedVector3Array &point_verts,
    PackedColorArray &point_cols,
    PackedVector2Array &point_uvs)
{
    YsVec3 local_nom = map_mode ? YsVec3(0.0, 1.0, 0.0) : YsVec3(0.0, 0.0, -1.0);
    YsVec3 world_nom_ys;
    world_tfm.Mul(world_nom_ys, local_nom, 0.0);
    Vector3 gface_n = ys_to_godot_normal(world_nom_ys);

    const YsListItem<Ys2DDrawingElement> *elemItem = nullptr;
    while ((elemItem = drw.FindNextElem(elemItem)) != nullptr) {
        const Ys2DDrawingElement &elem = elemItem->dat;
        const YsArray<YsVec2> &pts = elem.GetPointList();
        const int nPts = (int)pts.GetN();
        if (nPts == 0) {
            continue;
        }

        ++elem_counter;
        // Store the layer index in UV.x for clip-space depth biasing in the shader,
        // while keeping physical 3D vertices at exact 0.0 offset so aircraft wheels never sink.
        const Vector2 layer_uv((float)elem_counter, 0.0f);

        auto to_godot_pt = [&](const YsVec2 &p2) -> Vector3 {
            YsVec3 local_pt = map_mode
                ? YsVec3(p2.x(), 0.0, p2.y())
                : YsVec3(p2.x(), p2.y(), 0.0);
            YsVec3 world_pt;
            world_tfm.Mul(world_pt, local_pt, 1.0);
            return ys_to_godot_pos(world_pt);
        };

        Color col1 = ys_to_godot_color(elem.GetColor());
        Color col2 = ys_to_godot_color(elem.GetSecondColor());

        switch (elem.GetElemType()) {
            case Ys2DDrawingElement::POINTS:
            case Ys2DDrawingElement::APPROACHLIGHT: {
                for (int i = 0; i < nPts; ++i) {
                    point_verts.push_back(to_godot_pt(pts[i]));
                    point_cols.push_back(col1);
                    point_uvs.push_back(layer_uv);
                }
                break;
            }
            case Ys2DDrawingElement::LINESEGMENTS: {
                for (int i = 0; i < nPts - 1; ++i) {
                    line_verts.push_back(to_godot_pt(pts[i]));
                    line_cols.push_back(col1);
                    line_uvs.push_back(layer_uv);
                    line_verts.push_back(to_godot_pt(pts[i + 1]));
                    line_cols.push_back(col1);
                    line_uvs.push_back(layer_uv);
                }
                break;
            }
            case Ys2DDrawingElement::LINES: {
                for (int i = 0; i <= nPts - 2; i += 2) {
                    line_verts.push_back(to_godot_pt(pts[i]));
                    line_cols.push_back(col1);
                    line_uvs.push_back(layer_uv);
                    line_verts.push_back(to_godot_pt(pts[i + 1]));
                    line_cols.push_back(col1);
                    line_uvs.push_back(layer_uv);
                }
                break;
            }
            case Ys2DDrawingElement::TRIANGLES: {
                for (int i = 0; i <= nPts - 3; i += 3) {
                    Vector3 p0 = to_godot_pt(pts[i]);
                    Vector3 p1 = to_godot_pt(pts[i + 1]);
                    Vector3 p2 = to_godot_pt(pts[i + 2]);
                    add_oriented_triangle_uv(tri_verts, tri_norms, tri_cols, tri_uvs,
                        p0, p1, p2, gface_n, gface_n, gface_n, gface_n, col1, col1, col1, layer_uv);
                }
                break;
            }
            case Ys2DDrawingElement::QUADS: {
                for (int i = 0; i <= nPts - 4; i += 4) {
                    Vector3 p0 = to_godot_pt(pts[i]);
                    Vector3 p1 = to_godot_pt(pts[i + 1]);
                    Vector3 p2 = to_godot_pt(pts[i + 2]);
                    Vector3 p3 = to_godot_pt(pts[i + 3]);
                    add_oriented_triangle_uv(tri_verts, tri_norms, tri_cols, tri_uvs,
                        p0, p1, p2, gface_n, gface_n, gface_n, gface_n, col1, col1, col1, layer_uv);
                    add_oriented_triangle_uv(tri_verts, tri_norms, tri_cols, tri_uvs,
                        p0, p2, p3, gface_n, gface_n, gface_n, gface_n, col1, col1, col1, layer_uv);
                }
                break;
            }
            case Ys2DDrawingElement::QUADSTRIP: {
                for (int i = 0; i <= nPts - 4; i += 2) {
                    Vector3 p0 = to_godot_pt(pts[i]);
                    Vector3 p1 = to_godot_pt(pts[i + 1]);
                    Vector3 p2 = to_godot_pt(pts[i + 2]);
                    Vector3 p3 = to_godot_pt(pts[i + 3]);
                    add_oriented_triangle_uv(tri_verts, tri_norms, tri_cols, tri_uvs,
                        p0, p1, p2, gface_n, gface_n, gface_n, gface_n, col1, col1, col1, layer_uv);
                    add_oriented_triangle_uv(tri_verts, tri_norms, tri_cols, tri_uvs,
                        p1, p3, p2, gface_n, gface_n, gface_n, gface_n, col1, col1, col1, layer_uv);
                }
                break;
            }
            case Ys2DDrawingElement::GRADATIONQUADSTRIP: {
                for (int i = 0; i <= nPts - 4; i += 2) {
                    Vector3 p0 = to_godot_pt(pts[i]);
                    Vector3 p1 = to_godot_pt(pts[i + 1]);
                    Vector3 p2 = to_godot_pt(pts[i + 2]);
                    Vector3 p3 = to_godot_pt(pts[i + 3]);
                    add_oriented_triangle_uv(tri_verts, tri_norms, tri_cols, tri_uvs,
                        p0, p1, p2, gface_n, gface_n, gface_n, gface_n, col1, col1, col2, layer_uv);
                    add_oriented_triangle_uv(tri_verts, tri_norms, tri_cols, tri_uvs,
                        p1, p3, p2, gface_n, gface_n, gface_n, gface_n, col1, col2, col2, layer_uv);
                }
                break;
            }
            case Ys2DDrawingElement::POLYGON: {
                if (nPts < 3) {
                    break;
                }
                if (elem.IsConvex() == YSTRUE || nPts == 3) {
                    Vector3 p0 = to_godot_pt(pts[0]);
                    for (int i = 1; i < nPts - 1; ++i) {
                        Vector3 p1 = to_godot_pt(pts[i]);
                        Vector3 p2 = to_godot_pt(pts[i + 1]);
                        add_oriented_triangle_uv(tri_verts, tri_norms, tri_cols, tri_uvs,
                            p0, p1, p2, gface_n, gface_n, gface_n, gface_n, col1, col1, col1, layer_uv);
                    }
                } else {
                    YsShell2dTessellator tess;
                    YsArray<YsShell2dVertexHandle> v2HdArray;
                    if (tess.SetDomain(v2HdArray, nPts, pts) == YSOK) {
                        YsHashTable<YSSIZE_T> v2KeyToPntIdx;
                        for (YSSIZE_T idx = 0; idx < v2HdArray.GetN(); ++idx) {
                            v2KeyToPntIdx.AddElement(tess.GetSearchKey(v2HdArray[idx]), idx);
                        }
                        for (;;) {
                            YSBOOL repeat = YSFALSE;
                            YsShell2dEdgeHandle edHd;
                            tess.GetShell2d().RewindEdgePtr();
                            while (nullptr != (edHd = tess.GetShell2d().StepEdgePtr())) {
                                if (tess.RemoveEdge(edHd, 100, YSFALSE) == YSOK) {
                                    repeat = YSTRUE;
                                }
                            }
                            if (repeat != YSTRUE) {
                                break;
                            }
                        }
                        YsListItem<YsShell2dTessTriangle> *ptr;
                        tess.triList.RewindPointer();
                        while (nullptr != (ptr = tess.triList.StepPointer())) {
                            YSSIZE_T pntIdx[3] = {0, 0, 0};
                            if (v2KeyToPntIdx.FindElement(pntIdx[0], tess.GetSearchKey(ptr->dat.trVtHd[0])) == YSOK &&
                                v2KeyToPntIdx.FindElement(pntIdx[1], tess.GetSearchKey(ptr->dat.trVtHd[1])) == YSOK &&
                                v2KeyToPntIdx.FindElement(pntIdx[2], tess.GetSearchKey(ptr->dat.trVtHd[2])) == YSOK) {
                                Vector3 p0 = to_godot_pt(pts[pntIdx[0]]);
                                Vector3 p1 = to_godot_pt(pts[pntIdx[1]]);
                                Vector3 p2 = to_godot_pt(pts[pntIdx[2]]);
                                add_oriented_triangle_uv(tri_verts, tri_norms, tri_cols, tri_uvs,
                                    p0, p1, p2, gface_n, gface_n, gface_n, gface_n, col1, col1, col1, layer_uv);
                            }
                        }
                    } else {
                        // Fallback triangle fan if 2D tessellator rejects self-intersecting boundary
                        Vector3 p0 = to_godot_pt(pts[0]);
                        for (int i = 1; i < nPts - 1; ++i) {
                            Vector3 p1 = to_godot_pt(pts[i]);
                            Vector3 p2 = to_godot_pt(pts[i + 1]);
                            add_oriented_triangle_uv(tri_verts, tri_norms, tri_cols, tri_uvs,
                                p0, p1, p2, gface_n, gface_n, gface_n, gface_n, col1, col1, col1, layer_uv);
                        }
                    }
                }
                break;
            }
            default:
                break;
        }
    }
}

void YSFlightSimulation::build_scenery_recursive(const YsScenery *scn, const YsMatrix4x4 &parent_tfm, Node3D *parent_node) {
    if (scn == nullptr) {
        return;
    }

    YsMatrix4x4 scn_tfm = parent_tfm;
    scn_tfm.Translate(scn->GetPosition());
    scn_tfm.RotateXZ(scn->GetAttitude().h());
    scn_tfm.RotateZY(scn->GetAttitude().p());
    scn_tfm.RotateXY(scn->GetAttitude().b());

    // 1. Elevation Grids (TER)
    const YsListItem<YsSceneryElevationGrid> *evgItem = nullptr;
    while ((evgItem = scn->FindNextElevationGrid(evgItem)) != nullptr) {
        const YsSceneryElevationGrid &evgScn = evgItem->dat;
        const YsElevationGrid &evg = evgScn.GetElevationGridData();

        YsMatrix4x4 item_tfm = scn_tfm;
        item_tfm.Translate(evgScn.GetPosition());
        item_tfm.RotateXZ(evgScn.GetAttitude().h());
        item_tfm.RotateZY(evgScn.GetAttitude().p());
        item_tfm.RotateXY(evgScn.GetAttitude().b());

        PackedVector3Array verts, norms;
        PackedColorArray cols;

        for (int z = 0; z < evg.nz; ++z) {
            for (int x = 0; x < evg.nx; ++x) {
                for (int f = 0; f < 2; ++f) {
                    const YsElevationGridNode &nd = evg.node[(evg.nx + 1) * z + x];
                    if (nd.visible[f] != YSTRUE) {
                        continue;
                    }
                    YsVec3 tri[3], nom;
                    evg.GetTriangle(tri, x, z, f);
                    evg.GetTriangleNormal(nom, x, z, f);

                    Vector3 p0 = ys_to_godot_pos(tri[0]);
                    Vector3 p1 = ys_to_godot_pos(tri[1]);
                    Vector3 p2 = ys_to_godot_pos(tri[2]);
                    Vector3 gn = ys_to_godot_normal(nom);

                    Color c0, c1, c2;
                    if (evg.colorByElevation == YSTRUE) {
                        c0 = ys_to_godot_color(evg.ColorByElevation(tri[0].y()));
                        c1 = ys_to_godot_color(evg.ColorByElevation(tri[1].y()));
                        c2 = ys_to_godot_color(evg.ColorByElevation(tri[2].y()));
                    } else {
                        c0 = ys_to_godot_color(nd.c[f]);
                        c1 = c0;
                        c2 = c0;
                    }

                    add_oriented_triangle(verts, norms, cols, p0, p1, p2, gn, gn, gn, gn, c0, c1, c2);
                }
            }
        }

        // Side walls (0: z=0, 1: x=nx, 2: z=nz, 3: x=0)
        auto add_wall_quad = [&](const YsVec3 &top0, const YsVec3 &top1, const YsVec3 &wall_nom, const Color &wcol) {
            YsVec3 bot0(top0.x(), 0.0, top0.z());
            YsVec3 bot1(top1.x(), 0.0, top1.z());
            Vector3 p0 = ys_to_godot_pos(bot0);
            Vector3 p1 = ys_to_godot_pos(bot1);
            Vector3 p2 = ys_to_godot_pos(top1);
            Vector3 p3 = ys_to_godot_pos(top0);
            Vector3 gn = ys_to_godot_normal(wall_nom);
            if (top0.y() > 1e-3 || top1.y() > 1e-3) {
                add_oriented_triangle(verts, norms, cols, p0, p1, p2, gn, gn, gn, gn, wcol, wcol, wcol);
                add_oriented_triangle(verts, norms, cols, p0, p2, p3, gn, gn, gn, gn, wcol, wcol, wcol);
            }
        };

        if (evg.sideWall[0] == YSTRUE) {
            Color wc = ys_to_godot_color(evg.sideWallColor[0]);
            for (int x = 0; x < evg.nx; ++x) {
                YsVec3 a, b;
                evg.GetGridPosition(a, x, 0);
                evg.GetGridPosition(b, x + 1, 0);
                add_wall_quad(a, b, YsVec3(0.0, 0.0, -1.0), wc);
            }
        }
        if (evg.sideWall[1] == YSTRUE) {
            Color wc = ys_to_godot_color(evg.sideWallColor[1]);
            for (int z = 0; z < evg.nz; ++z) {
                YsVec3 a, b;
                evg.GetGridPosition(a, evg.nx, z);
                evg.GetGridPosition(b, evg.nx, z + 1);
                add_wall_quad(a, b, YsVec3(1.0, 0.0, 0.0), wc);
            }
        }
        if (evg.sideWall[2] == YSTRUE) {
            Color wc = ys_to_godot_color(evg.sideWallColor[2]);
            for (int x = 0; x < evg.nx; ++x) {
                YsVec3 a, b;
                evg.GetGridPosition(a, x + 1, evg.nz);
                evg.GetGridPosition(b, x, evg.nz);
                add_wall_quad(a, b, YsVec3(0.0, 0.0, 1.0), wc);
            }
        }
        if (evg.sideWall[3] == YSTRUE) {
            Color wc = ys_to_godot_color(evg.sideWallColor[3]);
            for (int z = 0; z < evg.nz; ++z) {
                YsVec3 a, b;
                evg.GetGridPosition(a, 0, z + 1);
                evg.GetGridPosition(b, 0, z);
                add_wall_quad(a, b, YsVec3(-1.0, 0.0, 0.0), wc);
            }
        }

        if (!verts.is_empty()) {
            Ref<ArrayMesh> mesh;
            mesh.instantiate();
            Array arrays;
            arrays.resize(Mesh::ARRAY_MAX);
            arrays[Mesh::ARRAY_VERTEX] = verts;
            arrays[Mesh::ARRAY_NORMAL] = norms;
            arrays[Mesh::ARRAY_COLOR] = cols;
            mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
            mesh->surface_set_material(0, mat_terrain);

            MeshInstance3D *mi = memnew(MeshInstance3D);
            mi->set_mesh(mesh);
            mi->set_transform(ys_matrix_to_godot_transform(item_tfm));
            parent_node->add_child(mi);
        }
    }

    // 2. 3D Scenery Shells (SRF)
    const YsListItem<YsSceneryShell> *shlItem = nullptr;
    while ((shlItem = scn->FindNextShell(shlItem)) != nullptr) {
        const YsSceneryShell &shlScn = shlItem->dat;
        const YsVisualSrf &visSrf = shlScn.GetVisualShell();

        YsMatrix4x4 item_tfm = scn_tfm;
        item_tfm.Translate(shlScn.GetPosition());
        item_tfm.RotateXZ(shlScn.GetAttitude().h());
        item_tfm.RotateZY(shlScn.GetAttitude().p());
        item_tfm.RotateXY(shlScn.GetAttitude().b());

        Ref<ArrayMesh> mesh = build_mesh_from_shell(visSrf);
        if (mesh.is_valid() && mesh->get_surface_count() > 0) {
            MeshInstance3D *mi = memnew(MeshInstance3D);
            mi->set_mesh(mesh);
            mi->set_transform(ys_matrix_to_godot_transform(item_tfm));
            parent_node->add_child(mi);
        }
    }

    // 3. Signboards (PLT)
    const YsListItem<YsScenery2DDrawing> *sbItem = nullptr;
    while ((sbItem = scn->FindNextSignBoard(sbItem)) != nullptr) {
        const YsScenery2DDrawing &sbScn = sbItem->dat;

        YsMatrix4x4 item_tfm = scn_tfm;
        item_tfm.Translate(sbScn.GetPosition());
        item_tfm.RotateXZ(sbScn.GetAttitude().h());
        item_tfm.RotateZY(sbScn.GetAttitude().p());
        item_tfm.RotateXY(sbScn.GetAttitude().b());

        PackedVector3Array tri_v, tri_n, line_v, pt_v;
        PackedColorArray tri_c, line_c, pt_c;
        PackedVector2Array tri_uv, line_uv, pt_uv;
        int elem_counter = 0;

        append_2d_drawing_to_buffers(
            sbScn.GetDrawing(), item_tfm, false, elem_counter,
            tri_v, tri_n, tri_c, tri_uv,
            line_v, line_c, line_uv,
            pt_v, pt_c, pt_uv);

        if (!tri_v.is_empty() || !line_v.is_empty() || !pt_v.is_empty()) {
            Ref<ArrayMesh> mesh;
            mesh.instantiate();
            if (!tri_v.is_empty()) {
                Array arr;
                arr.resize(Mesh::ARRAY_MAX);
                arr[Mesh::ARRAY_VERTEX] = tri_v;
                arr[Mesh::ARRAY_NORMAL] = tri_n;
                arr[Mesh::ARRAY_COLOR] = tri_c;
                arr[Mesh::ARRAY_TEX_UV] = tri_uv;
                int s = mesh->get_surface_count();
                mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arr);
                mesh->surface_set_material(s, mat_map_poly);
            }
            if (!line_v.is_empty()) {
                Array arr;
                arr.resize(Mesh::ARRAY_MAX);
                arr[Mesh::ARRAY_VERTEX] = line_v;
                arr[Mesh::ARRAY_COLOR] = line_c;
                arr[Mesh::ARRAY_TEX_UV] = line_uv;
                int s = mesh->get_surface_count();
                mesh->add_surface_from_arrays(Mesh::PRIMITIVE_LINES, arr);
                mesh->surface_set_material(s, mat_map_line);
            }
            if (!pt_v.is_empty()) {
                Array arr;
                arr.resize(Mesh::ARRAY_MAX);
                arr[Mesh::ARRAY_VERTEX] = pt_v;
                arr[Mesh::ARRAY_COLOR] = pt_c;
                arr[Mesh::ARRAY_TEX_UV] = pt_uv;
                int s = mesh->get_surface_count();
                mesh->add_surface_from_arrays(Mesh::PRIMITIVE_POINTS, arr);
                mesh->surface_set_material(s, mat_map_point);
            }
            MeshInstance3D *mi = memnew(MeshInstance3D);
            mi->set_mesh(mesh);
            parent_node->add_child(mi);
        }
    }

    // 4. Recurse into child sub-sceneries
    const YsListItem<YsScenery> *childScn = nullptr;
    while ((childScn = scn->FindNextChildScenery(childScn)) != nullptr) {
        build_scenery_recursive(&childScn->dat, scn_tfm, parent_node);
    }
}

void YSFlightSimulation::build_scenery_nodes() {
    if (sim == nullptr || scenery_root == nullptr) {
        return;
    }

    const FsField *fsField = sim->GetField();
    if (fsField == nullptr) {
        return;
    }

    const YsScenery *rootScn = fsField->GetFieldPtr();
    if (rootScn == nullptr) {
        return;
    }

    // 1. Base ground plane is now handled by Godot's ProceduralSkyMaterial in main.gd
    // to prevent Z-fighting with Maps and Elevation Grids at y=0.0.

    // 2. Build 2D Map Groups (PC2) via MakeMapDrawingOrder
    YsMatrix4x4 field_only_tfm;
    field_only_tfm.Initialize();
    field_only_tfm.Translate(fsField->GetPosition());
    field_only_tfm.RotateXZ(fsField->GetAttitude().h());
    field_only_tfm.RotateZY(fsField->GetAttitude().p());
    field_only_tfm.RotateXY(fsField->GetAttitude().b());

    YsMatrix4x4 root_scn_tfm = field_only_tfm;
    root_scn_tfm.Translate(rootScn->GetPosition());
    root_scn_tfm.RotateXZ(rootScn->GetAttitude().h());
    root_scn_tfm.RotateZY(rootScn->GetAttitude().p());
    root_scn_tfm.RotateXY(rootScn->GetAttitude().b());

    YsScenery::MapDrawingOrder mdo = rootScn->MakeMapDrawingOrder(root_scn_tfm, 0.05);

    for (int grpIdx = 0; grpIdx < mdo.samePlaneMapGroup.GetN(); ++grpIdx) {
        const YsScenery::SamePlaneMapGroup &grp = mdo.samePlaneMapGroup[grpIdx];

        PackedVector3Array tri_v, tri_n, line_v, pt_v;
        PackedColorArray tri_c, line_c, pt_c;
        PackedVector2Array tri_uv, line_uv, pt_uv;

        // Monotonically increment map_elem_counter across the entire SamePlaneMapGroup
        // in the exact painter's order computed by YsScenery::MakeMapDrawingOrder.
        int map_elem_counter = 0;
        for (int infoIdx = 0; infoIdx < grp.mapDrawingInfo.GetN(); ++infoIdx) {
            const YsScenery::MapDrawingInfo &mapInfo = grp.mapDrawingInfo[infoIdx];
            if (mapInfo.mapPtr == nullptr) {
                continue;
            }

            YsMatrix4x4 map_world_tfm = mapInfo.mapOwnerToWorldTfm;
            map_world_tfm.Translate(mapInfo.mapPtr->GetPosition());
            map_world_tfm.RotateXZ(mapInfo.mapPtr->GetAttitude().h());
            map_world_tfm.RotateZY(mapInfo.mapPtr->GetAttitude().p());
            map_world_tfm.RotateXY(mapInfo.mapPtr->GetAttitude().b());

            append_2d_drawing_to_buffers(
                mapInfo.mapPtr->GetDrawing(),
                map_world_tfm,
                true,
                map_elem_counter,
                tri_v, tri_n, tri_c, tri_uv,
                line_v, line_c, line_uv,
                pt_v, pt_c, pt_uv);
        }

        // Shift UV.x by -(map_elem_counter + 1) so all coplanar PC2 map layers have negative
        // signed layer indices (-N .. -1): later map layers (runways/markings) always win
        // against earlier map layers (landmass/grass), while 3D objects at y=0.0 (aircraft tires,
        // TER mountain bases, SRF buildings) at bias 0 always win against the map.
        const float bias_shift = -(float)(map_elem_counter + 1);
        for (int i = 0; i < tri_uv.size(); ++i) {
            tri_uv.set(i, Vector2(tri_uv[i].x + bias_shift, 0.0f));
        }
        for (int i = 0; i < line_uv.size(); ++i) {
            line_uv.set(i, Vector2(line_uv[i].x + bias_shift, 0.0f));
        }
        for (int i = 0; i < pt_uv.size(); ++i) {
            pt_uv.set(i, Vector2(pt_uv[i].x + bias_shift, 0.0f));
        }

        if (!tri_v.is_empty() || !line_v.is_empty() || !pt_v.is_empty()) {
            Ref<ArrayMesh> map_mesh;
            map_mesh.instantiate();
            if (!tri_v.is_empty()) {
                Array arr;
                arr.resize(Mesh::ARRAY_MAX);
                arr[Mesh::ARRAY_VERTEX] = tri_v;
                arr[Mesh::ARRAY_NORMAL] = tri_n;
                arr[Mesh::ARRAY_COLOR] = tri_c;
                arr[Mesh::ARRAY_TEX_UV] = tri_uv;
                int s = map_mesh->get_surface_count();
                map_mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arr);
                map_mesh->surface_set_material(s, mat_map_poly);
            }
            if (!line_v.is_empty()) {
                Array arr;
                arr.resize(Mesh::ARRAY_MAX);
                arr[Mesh::ARRAY_VERTEX] = line_v;
                arr[Mesh::ARRAY_COLOR] = line_c;
                arr[Mesh::ARRAY_TEX_UV] = line_uv;
                int s = map_mesh->get_surface_count();
                map_mesh->add_surface_from_arrays(Mesh::PRIMITIVE_LINES, arr);
                map_mesh->surface_set_material(s, mat_map_line);
            }
            if (!pt_v.is_empty()) {
                Array arr;
                arr.resize(Mesh::ARRAY_MAX);
                arr[Mesh::ARRAY_VERTEX] = pt_v;
                arr[Mesh::ARRAY_COLOR] = pt_c;
                arr[Mesh::ARRAY_TEX_UV] = pt_uv;
                int s = map_mesh->get_surface_count();
                map_mesh->add_surface_from_arrays(Mesh::PRIMITIVE_POINTS, arr);
                map_mesh->surface_set_material(s, mat_map_point);
            }

            MeshInstance3D *mi = memnew(MeshInstance3D);
            mi->set_name("MapGroup_" + String::num_int64(grpIdx));
            mi->set_mesh(map_mesh);
            scenery_root->add_child(mi);
        }
    }

    // 3. Build 3D Scenery (TER elevation grids, SRF 3D shells, PLT signboards)
    build_scenery_recursive(rootScn, field_only_tfm, scenery_root);

    UtilityFunctions::print("YSFlight: Built scenery nodes for field successfully.");
}

// ============================================================================
// .DNM / .SRF Entity Hierarchy Builder & Per-Frame Animator
// ============================================================================

// ============================================================================
// Motion interpolation between physics ticks
// ----------------------------------------------------------------------------
// The sim runs at a fixed 60 Hz; frames are rendered at any rate. Showing the latest tick directly makes
// motion stutter whenever the frame rate is not a multiple of 60. After every physics tick we store each
// moving object's transform (prev <- cur, cur <- new); each rendered frame blends prev -> cur by
// Engine::get_physics_interpolation_fraction(). Everything the player sees reads the SAME blended values:
// the model sync, get_player_transform (camera), get_airplane/ground_transforms (HUD boxes, radar),
// get_active_weapons (tracers, smoke) and the gun-lead point in telemetry. Cost: display is up to one
// tick (16.7 ms) behind the sim, which is standard for fixed-timestep games.
// Snaps (no blending): new objects, a reused weapon slot, and jumps > 500 m in one tick (respawn/teleport).
// Audio and game logic keep using raw sim positions.
// ============================================================================
static inline void interp_push(YSFlightSimulation::InterpState &st, const Transform3D &t) {
    if (!st.valid || st.cur.origin.distance_squared_to(t.origin) > 500.0 * 500.0) {
        st.prev = t;
        st.cur = t;
        st.valid = true;
    } else {
        st.prev = st.cur;
        st.cur = t;
    }
}

static inline Transform3D interp_blend(const YSFlightSimulation::InterpState &st, double a) {
    if (a >= 1.0) {
        return st.cur;
    }
    if (a <= 0.0) {
        return st.prev;
    }
    const Quaternion q0 = st.prev.basis.get_rotation_quaternion();
    const Quaternion q1 = st.cur.basis.get_rotation_quaternion();
    return Transform3D(Basis(q0.slerp(q1, (real_t)a)), st.prev.origin.lerp(st.cur.origin, (real_t)a));
}

void YSFlightSimulation::capture_interp_snapshot() {
    if (sim == nullptr) {
        return;
    }
    ++interp_tick;
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        interp_push(interp_air[air->SearchKey()], ys_to_godot_transform(air->GetPosition(), air->GetAttitude()));
    }
    FsGround *gnd = nullptr;
    while ((gnd = sim->FindNextGround(gnd)) != nullptr) {
        if (gnd->Prop().IsNonGameObject() != YSTRUE) { // static props never move
            interp_push(interp_gnd[gnd->SearchKey()], ys_to_godot_transform(gnd->GetPosition(), gnd->GetAttitude()));
        }
    }
    const FsWeapon *base = sim->GetWeaponStore().buf;
    const FsWeapon *wpn = nullptr;
    while ((wpn = sim->FindNextActiveWeapon(wpn)) != nullptr) {
        const size_t slot = (size_t)(wpn - base);
        if (slot >= interp_wpn.size()) {
            interp_wpn.resize(slot + 1);
            interp_wpn_code.resize(slot + 1, 0);
            interp_wpn_stamp.resize(slot + 1, 0);
        }
        const int16_t code = (int16_t)((int)wpn->type + 1);
        // A slot that was not active on the previous tick, or now holds another weapon type, is a new weapon
        if (interp_wpn_stamp[slot] != interp_tick - 1 || interp_wpn_code[slot] != code) {
            interp_wpn[slot].valid = false;
        }
        interp_wpn_stamp[slot] = interp_tick;
        interp_wpn_code[slot] = code;
        interp_push(interp_wpn[slot], ys_to_godot_transform(wpn->pos, wpn->att));
    }
}

void YSFlightSimulation::reset_interpolation() {
    interp_air.clear();
    interp_gnd.clear();
    interp_wpn.clear();
    interp_wpn_code.clear();
    interp_wpn_stamp.clear();
    capture_interp_snapshot();
}

void YSFlightSimulation::set_interpolation_enabled(bool enabled) {
    interp_enabled = enabled;
}

Transform3D YSFlightSimulation::air_render_transform(FsAirplane *air) const {
    auto it = interp_air.find(air->SearchKey());
    if (it != interp_air.end() && it->second.valid) {
        return interp_blend(it->second, interp_alpha);
    }
    return ys_to_godot_transform(air->GetPosition(), air->GetAttitude());
}

Transform3D YSFlightSimulation::gnd_render_transform(FsGround *gnd) const {
    auto it = interp_gnd.find(gnd->SearchKey());
    if (it != interp_gnd.end() && it->second.valid) {
        return interp_blend(it->second, interp_alpha);
    }
    return ys_to_godot_transform(gnd->GetPosition(), gnd->GetAttitude());
}

Transform3D YSFlightSimulation::wpn_render_transform(const FsWeapon *wpn) const {
    const size_t slot = (size_t)(wpn - sim->GetWeaponStore().buf);
    if (slot < interp_wpn.size() && interp_wpn[slot].valid && interp_wpn_stamp[slot] == interp_tick) {
        return interp_blend(interp_wpn[slot], interp_alpha);
    }
    return ys_to_godot_transform(wpn->pos, wpn->att);
}

// Sync-split timers (ms, summed per rendered frame), reported in the heartbeat line.
static double g_sync_air_ms = 0.0, g_sync_gnd_ms = 0.0, g_sync_wpn_ms = 0.0;
static int g_sync_frames = 0;
static long long g_gnd_full_updates = 0; // ground entities that went through a full DNM update

void YSFlightSimulation::sync_visual_entities() {
    if (sim == nullptr) {
        return;
    }

    const double ctime = sim->CurrentTime();
    FsAirplane *player = sim->GetPlayerAirplane();
    YsVec3 view_pos = YsOrigin();
    if (player != nullptr) {
        view_pos = player->GetPosition();
    }

    using DnmPtr = decltype(std::declval<FsVisualDnm &>().GetDnmPtr()); // shared_ptr to YsVisualDnm's protected Dnm type

    // Builds the Godot node hierarchy for one DNM model: one MeshInstance3D per DNM node, parented like the DNM tree.
    auto create_ev = [&](const DnmPtr &dnm_ptr, const String &name, Node3D *parent_root) -> EntityVisual {
        EntityVisual ev;
        ev.dnm_ptr = static_cast<const void *>(dnm_ptr.get());
        ev.root_node = memnew(Node3D);
        ev.root_node->set_name(name);
        parent_root->add_child(ev.root_node);

        auto node_array = dnm_ptr->GetNodePointerAll();
        const int num_nodes = (int)node_array.GetN();
        ev.dnm_nodes.resize(num_nodes, nullptr);
        ev.node_visible.assign(num_nodes, -1);
        ev.node_tfm.resize(num_nodes);
        ev.node_has_tfm.assign(num_nodes, 0);
        std::unordered_map<const void *, Node3D *> ptr_to_gnode;
        for (int i = 0; i < num_nodes; ++i) {
            auto *dnm_node = node_array[i];
            MeshInstance3D *mi = memnew(MeshInstance3D);
            if (dnm_node != nullptr) {
                if (dnm_node->nodeName.Strlen() > 0) {
                    mi->set_name(String(dnm_node->nodeName.Txt()));
                } else {
                    mi->set_name("DnmNode_" + String::num_int64(i));
                }
                Ref<ArrayMesh> mesh = build_mesh_from_shell(*dnm_node);
                if (mesh.is_valid() && mesh->get_surface_count() > 0) {
                    mi->set_mesh(mesh);
                }
                ptr_to_gnode[static_cast<const void *>(dnm_node)] = mi;
            }
            ev.dnm_nodes[i] = mi;
        }
        for (int i = 0; i < num_nodes; ++i) {
            auto *dnm_node = node_array[i];
            Node3D *child_node = ev.dnm_nodes[i];
            Node3D *parent_node = ev.root_node;
            if (dnm_node != nullptr && dnm_node->parent != nullptr) {
                auto pit = ptr_to_gnode.find(static_cast<const void *>(dnm_node->parent));
                if (pit != ptr_to_gnode.end() && pit->second != nullptr) {
                    parent_node = pit->second;
                }
            }
            parent_node->add_child(child_node);
        }
        return ev;
    };

    auto set_root_visible = [](EntityVisual &ev, bool visible) {
        if (ev.root_visible != (int8_t)visible) {
            ev.root_node->set_visible(visible);
            ev.root_visible = (int8_t)visible;
        }
    };

    // Pushes position/attitude and animated DNM part states, skipping anything unchanged since last frame.
    auto update_ev = [&](EntityVisual &ev, FsVisualDnm &vis, const DnmPtr &dnm_ptr, const Transform3D &root_tfm,
                         bool is_alive, bool is_static_prop) {
        set_root_visible(ev, is_alive);
        if (!is_alive) {
            return;
        }
        auto node_array = dnm_ptr->GetNodePointerAll();
        const int num_nodes = (int)node_array.GetN();

        // Settled single-node static props (trees, buildings, clouds) never change.
        if (is_static_prop && num_nodes <= 1 && ev.static_settled) {
            return;
        }

        if (!ev.has_root_tfm || root_tfm != ev.root_tfm) {
            ev.root_node->set_transform(root_tfm);
            ev.root_tfm = root_tfm;
            ev.has_root_tfm = true;
        }

        vis.SetUpSpecialRenderingRequirement();
        auto &dnm_state = vis.GetDnmState();
        dnm_ptr->CacheTransformation(dnm_state);

        for (int i = 0; i < num_nodes && i < (int)ev.dnm_nodes.size(); ++i) {
            auto *dnm_node = node_array[i];
            Node3D *gnode = ev.dnm_nodes[i];
            if (dnm_node == nullptr || gnode == nullptr) {
                continue;
            }
            const auto &nstate = dnm_state.GetState(dnm_node);
            const bool show = (nstate.GetShow() == YSTRUE);
            if (ev.node_visible[i] != (int8_t)show) {
                gnode->set_visible(show);
                ev.node_visible[i] = (int8_t)show;
            }
            if (show) {
                const Transform3D t = ys_matrix_to_godot_transform(nstate.tfmCache);
                if (!ev.node_has_tfm[i] || t != ev.node_tfm[i]) {
                    gnode->set_transform(t);
                    ev.node_tfm[i] = t;
                    ev.node_has_tfm[i] = 1;
                }
            }
        }

        if (is_static_prop && num_nodes <= 1) {
            ev.static_settled = true;
        }
    };

    // Airplanes and ground objects: one EntityVisual per sim object, rebuilt only if its DNM model changes.
    auto get_or_create = [&](std::unordered_map<unsigned int, EntityVisual> &table, unsigned int key, const DnmPtr &dnm_ptr,
                             Node3D *parent_root, const char *prefix) -> EntityVisual * {
        const void *raw_dnm = static_cast<const void *>(dnm_ptr.get());
        auto it = table.find(key);
        if (it != table.end() && it->second.dnm_ptr != raw_dnm) {
            if (it->second.root_node != nullptr) {
                it->second.root_node->queue_free();
            }
            table.erase(it);
            it = table.end();
        }
        if (it == table.end()) {
            it = table.emplace(key, create_ev(dnm_ptr, String(prefix) + "_" + String::num_int64(key), parent_root)).first;
        }
        return &it->second;
    };

    auto get_static_weapon_vis = [](const FsAirplane *owner, FSWEAPONTYPE wpnType) -> FsVisualDnm * {
        if (wpnType == FSWEAPON_FLARE) {
            wpnType = FSWEAPON_FLAREPOD;
        }
        if (owner != nullptr && (int)wpnType >= 0 && (int)wpnType < (int)FSWEAPON_NUMWEAPONTYPE) {
            FsVisualDnm &ov = owner->weaponShapeOverrideStatic[(int)wpnType];
            if (ov.GetDnmPtr() != nullptr) {
                return &ov;
            }
        }
        switch (wpnType) {
            case FSWEAPON_AIM9: return &FsWeapon::aim9s;
            case FSWEAPON_AIM9X: return &FsWeapon::aim9xs;
            case FSWEAPON_AIM120: return &FsWeapon::aim120s;
            case FSWEAPON_AGM65: return &FsWeapon::agm65s;
            case FSWEAPON_BOMB: return &FsWeapon::bomb;
            case FSWEAPON_BOMB250: return &FsWeapon::bomb250;
            case FSWEAPON_BOMB500HD: return &FsWeapon::bomb500hds;
            case FSWEAPON_ROCKET: return &FsWeapon::rockets;
            case FSWEAPON_FUELTANK: return &FsWeapon::fuelTank;
            case FSWEAPON_FLAREPOD: return &FsWeapon::flarePod;
            default: return nullptr;
        }
    };

    // 1. Airplanes (including external hardpoint stores)
    g_crash_breadcrumb = "sync_visual_entities: airplanes";
    auto t_air = std::chrono::high_resolution_clock::now();
    int air_count = 0;
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        ++air_count;
        const bool alive = (air->IsAlive() == YSTRUE) || (air == player);
        if (alive && air->vis != nullptr) {
            air->Prop().SetupVisual(air->vis);
        }
        DnmPtr dnm_ptr = air->vis.GetDnmPtr();
        if (dnm_ptr == nullptr) {
            continue;
        }
        EntityVisual *ev = get_or_create(airplane_visuals, air->SearchKey(), dnm_ptr, airplanes_root, "Airplane");
        update_ev(*ev, air->vis, dnm_ptr, air_render_transform(air), alive, false);

        if (alive) {
            const int num_slots = air->Prop().GetNumWeaponSlots();
            if (num_slots > 0 && (int)ev->hardpoint_nodes.size() != num_slots) {
                for (Node3D *old_hp : ev->hardpoint_nodes) {
                    if (old_hp != nullptr) {
                        old_hp->queue_free();
                    }
                }
                ev->hardpoint_nodes.assign(num_slots, nullptr);
                for (int s = 0; s < num_slots; ++s) {
                    FSWEAPONTYPE slot_type = air->Prop().GetWeaponSlotType(s);
                    FsVisualDnm *slot_vis = get_static_weapon_vis(air, slot_type);
                    MeshInstance3D *hp_mi = memnew(MeshInstance3D);
                    hp_mi->set_name("Hardpoint_" + String::num_int64(s));
                    hp_mi->set_position(ys_to_godot_pos(air->Prop().GetWeaponSlotPos(s)));
                    if (slot_vis != nullptr && slot_vis->GetDnmPtr() != nullptr) {
                        auto slot_nodes = slot_vis->GetDnmPtr()->GetNodePointerAll();
                        if (slot_nodes.GetN() > 0 && slot_nodes[0] != nullptr) {
                            Ref<ArrayMesh> mesh = build_mesh_from_shell(*slot_nodes[0]);
                            if (mesh.is_valid() && mesh->get_surface_count() > 0) {
                                hp_mi->set_mesh(mesh);
                            }
                        }
                    }
                    ev->root_node->add_child(hp_mi);
                    ev->hardpoint_nodes[s] = hp_mi;
                }
            }
            for (int s = 0; s < num_slots && s < (int)ev->hardpoint_nodes.size(); ++s) {
                Node3D *hp = ev->hardpoint_nodes[s];
                const bool hp_visible = (air->Prop().IsWeaponSlotCurrentlyVisible(s) == YSTRUE);
                if (hp != nullptr && hp->is_visible() != hp_visible) {
                    hp->set_visible(hp_visible);
                }
            }
        }
    }
    g_last_airplane_count = air_count;

    // Cockpit view: back-face culled materials on the player's own aircraft only.
    if (cockpit_mode && player != nullptr) {
        const unsigned int pkey = player->SearchKey();
        if (cockpit_key_valid && cockpit_key != pkey) {
            auto old_it = airplane_visuals.find(cockpit_key);
            if (old_it != airplane_visuals.end()) {
                apply_cockpit_materials(old_it->second, false);
            }
            cockpit_key_valid = false;
        }
        auto pit = airplane_visuals.find(pkey);
        if (pit != airplane_visuals.end() && !pit->second.cockpit_applied) {
            apply_cockpit_materials(pit->second, true);
            cockpit_key = pkey;
            cockpit_key_valid = true;
        }
    }

    // 1b. Cockpit shell (F1 only, player aircraft only). Like YSFlight, the cockpit model is drawn IN ADDITION
    //     to the aircraft's exterior model (whose back faces are culled in cockpit view), at the same
    //     interpolated transform. Aircraft without a cockpit model use YS's generic aircraft/cockpit1.srf.
    {
        FsVisualDnm *cockpit_vis = nullptr;
        if (cockpit_mode && player != nullptr && player->IsAlive() == YSTRUE) {
            if (player->cockpit != nullptr) {
                cockpit_vis = &player->cockpit;
            } else {
                if (generic_cockpit == nullptr) {
                    generic_cockpit = new FsVisualDnm;
                    if (generic_cockpit->Load(L"aircraft/cockpit1.srf") != YSOK) {
                        write_log_line("Cockpit: aircraft/cockpit1.srf could not be loaded");
                    }
                }
                if (*generic_cockpit != nullptr) {
                    cockpit_vis = generic_cockpit;
                }
            }
        }
        const unsigned int cockpit_key = (cockpit_vis != nullptr) ? player->SearchKey() : 0xFFFFFFFFu;
        for (auto &kv : cockpit_visuals) {
            if (kv.first != cockpit_key) {
                set_root_visible(kv.second, false);
            }
        }
        if (cockpit_vis != nullptr) {
            DnmPtr cockpit_dnm = cockpit_vis->GetDnmPtr();
            if (cockpit_dnm != nullptr) {
                EntityVisual *cev = get_or_create(cockpit_visuals, cockpit_key, cockpit_dnm, airplanes_root, "Cockpit");
                update_ev(*cev, *cockpit_vis, cockpit_dnm, air_render_transform(player), true, false);
            }
        }
    }

    // 2. Ground objects. Recomputing a ground object's animated DNM parts is YS-side work (~15 us each), so
    //    distant ones are time-sliced: every frame under 2.5 km from the camera, every 4th frame to 8 km,
    //    every 16th beyond. The phase is spread by key so the work is even across frames. A change of
    //    alive state (destroyed) is always applied immediately.
    g_crash_breadcrumb = "sync_visual_entities: grounds";
    auto t_gnd = std::chrono::high_resolution_clock::now();
    static uint32_t ground_frame_index = 0;
    ++ground_frame_index;
    YsVec3 cam_pos = view_pos;
    if (Viewport *vp = get_viewport()) {
        if (Camera3D *cam = vp->get_camera_3d()) {
            const Vector3 c = cam->get_global_position();
            cam_pos.Set(c.x, c.y, -c.z); // Godot -> YS: flip Z
        }
    }
    FsGround *gnd = nullptr;
    while ((gnd = sim->FindNextGround(gnd)) != nullptr) {
        const bool alive = (gnd->IsAlive() == YSTRUE);
        const bool is_static_prop = (gnd->Prop().IsNonGameObject() == YSTRUE);
        const unsigned int key = gnd->SearchKey();
        auto existing = ground_visuals.find(key);
        const bool settled = existing != ground_visuals.end() && existing->second.static_settled;
        if (existing != ground_visuals.end() && !settled && existing->second.has_root_tfm &&
            existing->second.root_visible == (int8_t)alive) {
            const double dist = (gnd->GetPosition() - cam_pos).GetLength();
            const uint32_t interval = dist < 2500.0 ? 1u : (dist < 8000.0 ? 4u : 16u);
            if (interval > 1u && ((key + ground_frame_index) % interval) != 0u) {
                continue;
            }
        }
        if (alive && gnd->vis != nullptr && (!is_static_prop || existing == ground_visuals.end())) {
            gnd->Prop().SetupVisual(gnd->vis, view_pos, ctime);
        }
        DnmPtr dnm_ptr = gnd->vis.GetDnmPtr();
        if (dnm_ptr == nullptr) {
            continue;
        }
        EntityVisual *ev = get_or_create(ground_visuals, key, dnm_ptr, grounds_root, "Ground");
        if (!settled) {
            ++g_gnd_full_updates;
        }
        update_ev(*ev, gnd->vis, dnm_ptr, gnd_render_transform(gnd), alive, is_static_prop);
    }

    // 3. Flying ordnance. Visuals are keyed by weapon slot; when a slot goes inactive its visual is hidden
    //    and returned to a per-model pool, so node count is bounded by peak concurrent weapons.
    g_crash_breadcrumb = "sync_visual_entities: weapons";
    auto t_wpn = std::chrono::high_resolution_clock::now();
    auto release_weapon_visual = [&](EntityVisual &ev) {
        set_root_visible(ev, false);
        weapon_pool[ev.dnm_ptr].push_back(std::move(ev));
    };
    std::vector<unsigned int> seen_slots;
    seen_slots.reserve(weapon_visuals.size() + 16);
    int wpn_count = 0;
    const FsWeapon *wpn = nullptr;
    while ((wpn = sim->FindNextActiveWeapon(wpn)) != nullptr) {
        ++wpn_count;
        if (wpn->lifeRemain <= 0.0) {
            continue; // Impacted; only smoke trail remains while timeRemain > 0
        }
        FsVisualDnm *vis_ptr = nullptr;
        if (wpn->firedBy != nullptr && (int)wpn->type >= 0 && (int)wpn->type < (int)FSWEAPON_NUMWEAPONTYPE) {
            FsVisualDnm &override_vis = (wpn->shouldJettison == YSTRUE)
                ? wpn->firedBy->weaponShapeOverrideStatic[(int)wpn->type]
                : wpn->firedBy->weaponShapeOverrideFlying[(int)wpn->type];
            if (override_vis.GetDnmPtr() != nullptr) {
                vis_ptr = &override_vis;
            }
        }
        if (vis_ptr == nullptr) {
            const bool jett = (wpn->shouldJettison == YSTRUE);
            switch (wpn->type) {
                case FSWEAPON_AIM9: vis_ptr = jett ? &FsWeapon::aim9s : &FsWeapon::aim9; break;
                case FSWEAPON_AIM9X: vis_ptr = jett ? &FsWeapon::aim9xs : &FsWeapon::aim9x; break;
                case FSWEAPON_AIM120: vis_ptr = jett ? &FsWeapon::aim120s : &FsWeapon::aim120; break;
                case FSWEAPON_AGM65: vis_ptr = jett ? &FsWeapon::agm65s : &FsWeapon::agm65; break;
                case FSWEAPON_BOMB: vis_ptr = &FsWeapon::bomb; break;
                case FSWEAPON_BOMB250: vis_ptr = &FsWeapon::bomb250; break;
                case FSWEAPON_BOMB500HD: vis_ptr = jett ? &FsWeapon::bomb500hds : &FsWeapon::bomb500hd; break;
                case FSWEAPON_ROCKET: vis_ptr = jett ? &FsWeapon::rockets : &FsWeapon::rocket; break;
                case FSWEAPON_FUELTANK: vis_ptr = &FsWeapon::fuelTank; break;
                case FSWEAPON_FLAREPOD: vis_ptr = &FsWeapon::flarePod; break;
                default: break;
            }
        }
        if (vis_ptr == nullptr) {
            continue;
        }
        DnmPtr dnm_ptr = vis_ptr->GetDnmPtr();
        if (dnm_ptr == nullptr) {
            continue;
        }
        const void *raw_dnm = static_cast<const void *>(dnm_ptr.get());
        const unsigned int slot = (unsigned int)(wpn - sim->GetWeaponStore().buf);
        auto it = weapon_visuals.find(slot);
        if (it != weapon_visuals.end() && it->second.dnm_ptr != raw_dnm) {
            release_weapon_visual(it->second);
            weapon_visuals.erase(it);
            it = weapon_visuals.end();
        }
        if (it == weapon_visuals.end()) {
            auto pool_it = weapon_pool.find(raw_dnm);
            if (pool_it != weapon_pool.end() && !pool_it->second.empty()) {
                it = weapon_visuals.emplace(slot, std::move(pool_it->second.back())).first;
                pool_it->second.pop_back();
            } else {
                it = weapon_visuals.emplace(slot, create_ev(dnm_ptr, "Weapon_" + String::num_int64(slot), weapons_root)).first;
            }
        }
        seen_slots.push_back(slot);
        update_ev(it->second, *vis_ptr, dnm_ptr, wpn_render_transform(wpn), true, false);
    }
    g_last_weapon_count = wpn_count;

    // Return visuals of weapons that are no longer flying to the pool.
    if (seen_slots.size() != weapon_visuals.size()) {
        std::sort(seen_slots.begin(), seen_slots.end());
        for (auto it = weapon_visuals.begin(); it != weapon_visuals.end();) {
            if (!std::binary_search(seen_slots.begin(), seen_slots.end(), it->first)) {
                release_weapon_visual(it->second);
                it = weapon_visuals.erase(it);
            } else {
                ++it;
            }
        }
    }

    auto t_end = std::chrono::high_resolution_clock::now();
    g_sync_air_ms += std::chrono::duration<double, std::milli>(t_gnd - t_air).count();
    g_sync_gnd_ms += std::chrono::duration<double, std::milli>(t_wpn - t_gnd).count();
    g_sync_wpn_ms += std::chrono::duration<double, std::milli>(t_end - t_wpn).count();
    ++g_sync_frames;
    g_crash_breadcrumb = "sync_visual_entities: done";
}

void YSFlightSimulation::load_yfs(godot::String file_path) {
    if (world == nullptr) {
        UtilityFunctions::print("YSFlight Error: Cannot load YFS. You must call initialize_simulation() first.");
        return;
    }

    g_crash_breadcrumb = "load_yfs: init_materials & clear_scene_nodes";
    write_log_line((String("load_yfs() starting for: ") + file_path).utf8().get_data());
    init_materials();
    clear_scene_nodes();

    godot::String res_path = godot::ProjectSettings::get_singleton()->globalize_path("res://");
    _wchdir((const wchar_t *)res_path.utf16().get_data());

    char cwd[256];
    _getcwd(cwd, 256);
    UtilityFunctions::print(godot::String("CWD after _wchdir: ") + cwd);

    g_crash_breadcrumb = "load_yfs: LoadTemplateAll";
    UtilityFunctions::print("YSFlight: Loading templates from local directories...");
    write_log_line("Calling world->LoadTemplateAll()...");
    FsUseLocalFolderSetting();
    remove("fserr.txt");
    world->LoadTemplateAll();
    FsWeaponHolder::LoadMissilePattern();
    write_log_line("Templates and missile patterns loaded.");

    godot::String global_path = godot::ProjectSettings::get_singleton()->globalize_path(file_path);
    UtilityFunctions::print("YSFlight: Loading YFS Flight Save: " + global_path);
    godot::Char16String char16_str = global_path.utf16();

    g_crash_breadcrumb = "load_yfs: world->Load";
    write_log_line("Calling world->Load()...");
    UtilityFunctions::print("YSFlight: About to call world->Load...");
    YSRESULT load_res = world->Load((const wchar_t *)char16_str.get_data());
    if (load_res == YSOK) {
        UtilityFunctions::print("YSFlight: world->Load finished successfully (YSOK).");
        write_log_line("world->Load() finished with YSOK.");
    } else {
        UtilityFunctions::print("YSFlight Error: world->Load returned YSERR!");
        write_log_line("ERROR: world->Load() returned YSERR!");
    }

    FILE *err_fp = fopen("fserr.txt", "r");
    if (err_fp != nullptr) {
        char err_line[512];
        while (fgets(err_line, sizeof(err_line), err_fp) != nullptr) {
            size_t len = strlen(err_line);
            while (len > 0 && (err_line[len - 1] == '\n' || err_line[len - 1] == '\r')) {
                err_line[--len] = '\0';
            }
            if (len > 0) {
                char msg_buf[600];
                snprintf(msg_buf, sizeof(msg_buf), "fserr.txt: %s", err_line);
                write_log_line(msg_buf);
                UtilityFunctions::print(String(msg_buf));
            }
        }
        fclose(err_fp);
    }

    g_crash_breadcrumb = "load_yfs: world->PrepareSimulation";
    write_log_line("Calling world->PrepareSimulation()...");
    UtilityFunctions::print("YSFlight: Preparing simulation...");
    world->PrepareSimulation();

    sim = world->GetSimulation();

    // Build .fld scenery and initial .dnm/.srf entity hierarchy
    g_crash_breadcrumb = "load_yfs: build_scenery_nodes";
    write_log_line("Building scenery nodes...");
    build_scenery_nodes();

    build_prewarm_node();
    reset_interpolation();

    g_crash_breadcrumb = "load_yfs: initial sync_visual_entities";
    write_log_line("Running initial sync_visual_entities()...");
    sync_visual_entities();

    String summary = "YSFlight: Visual sync complete. Airplanes: " + String::num_int64((int64_t)airplane_visuals.size()) +
        ", Ground objects: " + String::num_int64((int64_t)ground_visuals.size()) +
        ", Cached unique shells: " + String::num_int64((int64_t)shell_mesh_cache.size());
    UtilityFunctions::print(summary);
    write_log_line(summary.utf8().get_data());
    g_crash_breadcrumb = "load_yfs: done";
}

// PERF: timers summarised in the heartbeat line every 300 physics ticks
static double perf_sim_sum = 0.0, perf_sim_max = 0.0, perf_sync_sum = 0.0, perf_sync_max = 0.0;
static int perf_sync_frames = 0;
// Per-rendered-frame stats, read and reset by get_frame_stats()
static double frame_sim_ms = 0.0, frame_sync_ms = 0.0;
static int frame_ticks = 0;

void YSFlightSimulation::_physics_process(double delta) {
    if (world == nullptr || sim == nullptr) {
        return;
    }
    ++g_physics_frame_count;
    g_last_sim_time = sim->CurrentTime();

    // PERF: per-section timers, summarised in the heartbeat line every 300 ticks
    // The physics tick only steps the simulation. Visual sync runs once per rendered frame in _process(),
    // so catch-up ticks (several per frame when FPS drops) stay cheap.
    auto perf_t0 = std::chrono::high_resolution_clock::now();

    g_crash_breadcrumb = "_physics_process: world->SimulateOneStep";
    world->SimulateOneStep(delta, YSFALSE, YSFALSE, YSFALSE, YSFALSE, FSUSC_SCRIPT, YSFALSE);
    g_crash_breadcrumb = "_physics_process: capture_interp_snapshot";
    capture_interp_snapshot();
    g_crash_breadcrumb = "_physics_process: idle";

    const double sim_ms = std::chrono::duration<double, std::milli>(std::chrono::high_resolution_clock::now() - perf_t0).count();
    perf_sim_sum += sim_ms;
    if (sim_ms > perf_sim_max) perf_sim_max = sim_ms;
    frame_sim_ms += sim_ms;
    ++frame_ticks;

    if (g_physics_frame_count % 300 == 0) {
        int alive_air = 0;
        FsAirplane *air = nullptr;
        while ((air = sim->FindNextAirplane(air)) != nullptr) {
            if (air->IsAlive() == YSTRUE) {
                ++alive_air;
            }
        }
        char hb[512];
        snprintf(hb, sizeof(hb), "Heartbeat: Alive Airplanes=%d/%d | Active Weapons=%d",
                 alive_air, (int)g_last_airplane_count, (int)g_last_weapon_count);
        write_log_line(hb);
        const int sync_n = perf_sync_frames > 0 ? perf_sync_frames : 1;
        snprintf(hb, sizeof(hb), "PERF C++: SimulateOneStep %.2f/%.2f ms per tick | sync_visual_entities %.2f/%.2f ms per frame (avg/max)",
                 perf_sim_sum / 300.0, perf_sim_max, perf_sync_sum / sync_n, perf_sync_max);
        write_log_line(hb);
        const int split_n = g_sync_frames > 0 ? g_sync_frames : 1;
        snprintf(hb, sizeof(hb), "PERF sync split (ms per frame): airplanes %.2f | grounds %.2f (%.0f full updates/frame) | weapons %.2f | visuals: %d air, %d gnd, %d wpn active",
                 g_sync_air_ms / split_n, g_sync_gnd_ms / split_n, (double)g_gnd_full_updates / split_n, g_sync_wpn_ms / split_n,
                 (int)airplane_visuals.size(), (int)ground_visuals.size(), (int)weapon_visuals.size());
        write_log_line(hb);
        g_sync_air_ms = g_sync_gnd_ms = g_sync_wpn_ms = 0.0;
        g_sync_frames = 0;
        g_gnd_full_updates = 0;
        perf_sim_sum = perf_sim_max = perf_sync_sum = perf_sync_max = 0.0;
        perf_sync_frames = 0;
    }
}

void YSFlightSimulation::_process(double delta) {
    if (world == nullptr || sim == nullptr) {
        return;
    }
    if (prewarm_node != nullptr && --prewarm_frames_left <= 0) {
        prewarm_node->queue_free();
        prewarm_node = nullptr;
    }
    interp_alpha = interp_enabled ? YsBound((double)Engine::get_singleton()->get_physics_interpolation_fraction(), 0.0, 1.0) : 1.0;
    auto perf_t0 = std::chrono::high_resolution_clock::now();
    g_crash_breadcrumb = "_process: sync_visual_entities";
    sync_visual_entities();
    g_crash_breadcrumb = "_process: idle";
    const double sync_ms = std::chrono::duration<double, std::milli>(std::chrono::high_resolution_clock::now() - perf_t0).count();
    perf_sync_sum += sync_ms;
    if (sync_ms > perf_sync_max) perf_sync_max = sync_ms;
    ++perf_sync_frames;
    frame_sync_ms = sync_ms;
}

// [sim_ms, physics_ticks, sync_ms, alive_airplanes, active_weapons, active_explosions, visual_nodes]
// sim_ms and physics_ticks accumulate since the previous call (i.e. since the previous rendered frame).
godot::PackedFloat64Array YSFlightSimulation::get_frame_stats() {
    godot::PackedFloat64Array out;
    out.resize(7);
    int alive_air = 0, explosions = 0;
    if (sim != nullptr) {
        FsAirplane *air = nullptr;
        while ((air = sim->FindNextAirplane(air)) != nullptr) {
            if (air->IsAlive() == YSTRUE) {
                ++alive_air;
            }
        }
        for (const FsExplosion *exp = sim->GetExplosionStore().activeList; exp != nullptr; exp = exp->next) {
            ++explosions;
        }
    }
    size_t visual_entities = airplane_visuals.size() + ground_visuals.size() + weapon_visuals.size();
    out.set(0, frame_sim_ms);
    out.set(1, (double)frame_ticks);
    out.set(2, frame_sync_ms);
    out.set(3, (double)alive_air);
    out.set(4, (double)g_last_weapon_count);
    out.set(5, (double)explosions);
    out.set(6, (double)visual_entities);
    frame_sim_ms = 0.0;
    frame_ticks = 0;
    return out;
}

// Everything the audio manager needs for one rendered frame. Call exactly once per frame: the event lists
// ("onetime", "launches", "explosions") contain what happened since the previous call.
//   player:     { key, engine_type (FSSND_ENGINETYPE), engine_power 0..1, gun (0/1), alarm (FSSND_ALARMTYPE) }
//               = what the YS sound logic (SimBlastSound) requested for the player aircraft.
//   onetime:    PackedInt32Array of FSSND_ONETIMETYPE values fired by YS (touchdown, gear, ...).
//   aircraft:   PackedFloat32Array, stride 11 per alive aircraft:
//               key, pos x/y/z, vel x/y/z (Godot space), engine_kind (0 jet, 1 jet+afterburner, 2 prop/rotor),
//               power 0..1, gun_firing (0/1), is_player (0/1)
//   launches:   PackedFloat32Array, stride 6: kind (0 missile, 1 rocket, 2 bomb), pos x/y/z, shooter key (-1 none), FSWEAPONTYPE
//   explosions: PackedFloat32Array, stride 5: pos x/y/z, radius (m), explosion type
godot::Dictionary YSFlightSimulation::get_audio_state() {
    godot::Dictionary out;
    if (sim == nullptr) {
        return out;
    }
    const FsSoundBridgeState &bridge = FsSoundGetBridgeState();
    FsAirplane *player = sim->GetPlayerAirplane();

    godot::Dictionary pl;
    pl["key"] = player != nullptr ? (int64_t)player->SearchKey() : (int64_t)-1;
    pl["engine_type"] = (int64_t)bridge.engineType;
    pl["engine_power"] = bridge.enginePower;
    pl["gun"] = (int64_t)(bridge.machineGun != 0 ? 1 : 0);
    pl["alarm"] = (int64_t)bridge.alarm;
    out["player"] = pl;

    godot::PackedInt32Array onetime;
    for (int t = 0; t < FsSoundBridgeState::MAX_ONETIME_TYPES; ++t) {
        const unsigned int n = bridge.oneTimeCount[t] - audio_prev_onetime[t];
        if (audio_initialized) {
            for (unsigned int i = 0; i < n && i < 4; ++i) {
                onetime.push_back(t);
            }
        }
        audio_prev_onetime[t] = bridge.oneTimeCount[t];
    }
    out["onetime"] = onetime;

    godot::PackedFloat32Array aircraft;
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        if (air->IsAlive() != YSTRUE) {
            continue;
        }
        auto &prop = air->Prop();
        YsVec3 vel = YsOrigin();
        prop.GetVelocity(vel);
        double power = prop.GetThrottle();
        double rpm_min, rpm_max; // propellers: YS drives the sound from propeller RPM, as in SimBlastSound
        if (prop.IsJet() != YSTRUE && prop.GetRPMRangeForSoundEffect(rpm_min, rpm_max, 0) == YSOK && rpm_max - rpm_min > YsTolerance) {
            power = YsBound((prop.GetRealPropRPM(0) - rpm_min) / (rpm_max - rpm_min), 0.0, 1.0);
        }
        const int kind = prop.IsJet() == YSTRUE ? (prop.GetAfterBurner() == YSTRUE ? 1 : 0) : 2;
        const Vector3 p = ys_to_godot_pos(air->GetPosition());
        const Vector3 v = ys_to_godot_pos(vel);
        const float row[11] = {(float)air->SearchKey(), p.x, p.y, p.z, v.x, v.y, v.z, (float)kind, (float)power,
                               prop.IsFiringGun() == YSTRUE ? 1.0f : 0.0f, air == player ? 1.0f : 0.0f};
        for (float f : row) {
            aircraft.push_back(f);
        }
    }
    out["aircraft"] = aircraft;

    // Launches: a weapon slot that is active now but was empty (or held another type) last frame.
    godot::PackedFloat32Array launches;
    std::vector<int16_t> cur_code(audio_prev_weapon_code.size(), 0);
    const FsWeapon *base = sim->GetWeaponStore().buf;
    const FsWeapon *wpn = nullptr;
    while ((wpn = sim->FindNextActiveWeapon(wpn)) != nullptr) {
        const size_t slot = (size_t)(wpn - base);
        if (slot >= cur_code.size()) {
            cur_code.resize(slot + 1, 0);
        }
        const int16_t code = (int16_t)((int)wpn->type + 1);
        cur_code[slot] = code;
        const int16_t prev = slot < audio_prev_weapon_code.size() ? audio_prev_weapon_code[slot] : 0;
        if (!audio_initialized || prev == code || wpn->lifeRemain <= 0.0) {
            continue;
        }
        int kind = -1;
        switch (wpn->type) {
            case FSWEAPON_AIM9: case FSWEAPON_AIM9X: case FSWEAPON_AIM120: case FSWEAPON_AGM65: kind = 0; break;
            case FSWEAPON_ROCKET: kind = 1; break;
            case FSWEAPON_BOMB: case FSWEAPON_BOMB250: case FSWEAPON_BOMB500HD: kind = 2; break;
            default: break; // guns (looped per aircraft), flares, fuel tanks, debris: no launch sound
        }
        if (kind < 0) {
            continue;
        }
        const Vector3 p = ys_to_godot_pos(wpn->pos);
        const float row[6] = {(float)kind, p.x, p.y, p.z,
                              wpn->firedBy != nullptr ? (float)wpn->firedBy->SearchKey() : -1.0f, (float)wpn->type};
        for (float f : row) {
            launches.push_back(f);
        }
    }
    audio_prev_weapon_code.swap(cur_code);
    out["launches"] = launches;

    // Explosions that started since the last call.
    godot::PackedFloat32Array explosions;
    std::unordered_set<int64_t> current;
    const FsExplosionHolder &holder = sim->GetExplosionStore();
    for (const FsExplosion *exp = holder.activeList; exp != nullptr; exp = exp->next) {
        const int64_t slot_id = (int64_t)(exp - holder.buf);
        const int64_t uid = (slot_id << 32) | (int64_t)((uint32_t)exp->random);
        current.insert(uid);
        if (!audio_initialized || audio_seen_explosions.count(uid) != 0) {
            continue;
        }
        const Vector3 p = ys_to_godot_pos(exp->pos);
        const float row[5] = {p.x, p.y, p.z, (float)YsGreater(exp->iniRadius, exp->radius), (float)exp->expType};
        for (float f : row) {
            explosions.push_back(f);
        }
    }
    audio_seen_explosions.swap(current);
    out["explosions"] = explosions;

    audio_initialized = true;
    return out;
}

// Call before load_yfs() so the whole run (including mission load) uses the same random sequence.
void YSFlightSimulation::set_random_seed(int64_t seed) {
    srand((unsigned int)seed);
}

// Hands the player's aircraft to the YS dogfight AI (used by benchmark mode). Call after load_yfs().
bool YSFlightSimulation::enable_player_autopilot() {
    if (sim == nullptr || sim->GetPlayerAirplane() == nullptr) {
        return false;
    }
    FsDogfight *df = FsDogfight::Create();
    df->gLimit = 9.0;
    df->minAlt = 300.0;
    sim->GetPlayerAirplane()->SetAutopilot(df);
    write_log_line("Benchmark: player aircraft handed to FsDogfight autopilot.");
    return true;
}

godot::Dictionary YSFlightSimulation::get_airplane_transforms() const {
    godot::Dictionary transforms;
    if (sim == nullptr) {
        return transforms;
    }

    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        YsVec3 pos = air->GetPosition();
        YsAtt3 att = air->GetAttitude();
        YsVec3 vel = YsOrigin();
        air->Prop().GetVelocity(vel);
        YsVec3 cock = air->GetCockpitPosition();

        godot::Dictionary state;
        godot::Transform3D t = air_render_transform(air); // interpolated (same as the drawn model)
        state["pos"] = t.origin;
        state["rot"] = t.basis.get_euler();
        state["transform"] = t;
        state["velocity"] = ys_to_godot_pos(vel);
        state["cockpit_local"] = ys_to_godot_pos(cock);
        state["outside_radius"] = (double)air->Prop().GetOutsideRadius();
        state["is_player"] = (air == sim->GetPlayerAirplane());
        state["is_alive"] = (air->IsAlive() == YSTRUE);
        state["iff"] = (int64_t)air->GetIff();
        state["identifier"] = godot::String(air->GetIdentifier());
        state["name"] = godot::String(air->GetName());
        transforms[(int64_t)air->SearchKey()] = state;
    }
    return transforms;
}

godot::Dictionary YSFlightSimulation::get_ground_transforms() const {
    godot::Dictionary transforms;
    if (sim == nullptr) {
        return transforms;
    }

    FsGround *gnd = nullptr;
    while ((gnd = sim->FindNextGround(gnd)) != nullptr) {
        if (gnd->Prop().IsNonGameObject() == YSTRUE) {
            continue; // Skip static scenery props (trees, clouds, city blocks)
        }
        YsVec3 pos = gnd->GetPosition();
        YsAtt3 att = gnd->GetAttitude();
        godot::Dictionary state;
        godot::Transform3D t = gnd_render_transform(gnd); // interpolated (same as the drawn model)
        state["pos"] = t.origin;
        state["transform"] = t;
        state["is_alive"] = (gnd->IsAlive() == YSTRUE);
        state["iff"] = (int64_t)gnd->GetIff();
        state["identifier"] = godot::String(gnd->GetIdentifier());
        state["name"] = godot::String(gnd->GetName());
        state["is_non_game_object"] = false;
        transforms[(int64_t)gnd->SearchKey()] = state;
    }
    return transforms;
}

// Same fields as one entry of get_ground_transforms(); empty Dictionary if the key is unknown.
godot::Dictionary YSFlightSimulation::get_ground_transform(int64_t key) const {
    godot::Dictionary state;
    if (sim == nullptr || key < 0) {
        return state;
    }
    FsGround *gnd = sim->FindGround((YSHASHKEY)key);
    if (gnd == nullptr) {
        return state;
    }
    const godot::Transform3D t = gnd_render_transform(gnd);
    state["pos"] = t.origin;
    state["transform"] = t;
    state["is_alive"] = (gnd->IsAlive() == YSTRUE);
    state["iff"] = (int64_t)gnd->GetIff();
    state["identifier"] = godot::String(gnd->GetIdentifier());
    state["name"] = godot::String(gnd->GetName());
    return state;
}

godot::Array YSFlightSimulation::get_active_weapons() const {
    godot::Array list;
    if (sim == nullptr) {
        return list;
    }

    const FsWeapon *wpn = nullptr;
    const FsWeapon *buf_base = sim->GetWeaponStore().buf;
    while ((wpn = sim->FindNextActiveWeapon(wpn)) != nullptr) {
        godot::Dictionary d;
        d["slot_id"] = (int64_t)(wpn - buf_base);
        d["type"] = (int64_t)wpn->type;
        // Interpolated position; the tracer segment keeps its sim length/direction (pos - prv)
        const godot::Transform3D t = wpn_render_transform(wpn);
        d["pos"] = t.origin;
        d["prev_pos"] = t.origin - (ys_to_godot_pos(wpn->pos) - ys_to_godot_pos(wpn->prv));
        d["vel"] = ys_to_godot_pos(wpn->vec);
        d["transform"] = t;
        d["life_remain"] = (double)wpn->lifeRemain;
        d["time_remain"] = (double)wpn->timeRemain;
        d["has_trail"] = (wpn->trail != nullptr && wpn->trail->used == YSTRUE);
        list.push_back(d);
    }
    return list;
}

godot::Array YSFlightSimulation::get_active_explosions() const {
    godot::Array list;
    if (sim == nullptr) {
        return list;
    }

    const FsExplosionHolder &holder = sim->GetExplosionStore();
    const FsExplosion *exp = holder.activeList;
    while (exp != nullptr) {
        const int64_t slot_id = (int64_t)(exp - holder.buf);
        const int64_t uid = (slot_id << 32) | (int64_t)((uint32_t)exp->random);
        godot::Dictionary d;
        d["slot_id"] = slot_id;
        d["uid"] = uid;
        d["exp_type"] = (int64_t)exp->expType;
        d["pos"] = ys_to_godot_pos(exp->pos);
        d["time_passed"] = (double)exp->timePassed;
        d["time_remain"] = (double)exp->timeRemain;
        d["ini_radius"] = (double)exp->iniRadius;
        d["radius"] = (double)exp->radius;
        d["flash"] = (exp->flash == YSTRUE);
        list.push_back(d);
        exp = exp->next;
    }
    return list;
}

godot::Transform3D YSFlightSimulation::get_player_transform() const {
    if (sim != nullptr) {
        FsAirplane *player = sim->GetPlayerAirplane();
        if (player != nullptr) {
            return air_render_transform(player); // interpolated: the camera follows what is drawn
        }
    }
    return Transform3D();
}

godot::Dictionary YSFlightSimulation::get_player_telemetry() const {
    godot::Dictionary dict;
    if (sim != nullptr) {
        FsAirplane *player = sim->GetPlayerAirplane();
        if (player != nullptr) {
            const double vel_ms = player->Prop().GetVelocity();
            const double alt_m = player->Prop().GetIndicatedTrueAltitude();
            const double vsi_ms = player->Prop().GetClimbRatioWithTimeDelay();
            const YsAtt3 att = player->GetAttitude();
            YsVec3 vel_vec = YsOrigin();
            player->Prop().GetVelocity(vel_vec);

            // In YSFlight, +Z is North, +X is East, and RotateXZ(h) is counter-clockwise,
            // so compass heading is -h wrapped to [0, 360).
            double hdg_deg = std::fmod(-YsRadToDeg(att.h()), 360.0);
            if (hdg_deg < 0.0) {
                hdg_deg += 360.0;
            }

            dict["speed_ms"] = vel_ms;
            dict["speed_kt"] = vel_ms * 1.94384449;
            dict["altitude_m"] = alt_m;
            dict["altitude_ft"] = alt_m * 3.2808399;
            dict["agl_m"] = player->GetPosition().y();
            dict["vsi_fpm"] = vsi_ms * 3.2808399 * 60.0;
            dict["throttle"] = player->Prop().GetThrottle();
            dict["afterburner"] = (player->Prop().GetAfterBurner() == YSTRUE);
            dict["mach"] = player->Prop().GetMach();
            dict["g_force"] = player->Prop().GetG();
            dict["heading_deg"] = hdg_deg;
            dict["pitch_deg"] = YsRadToDeg(att.p());
            dict["bank_deg"] = YsRadToDeg(att.b());
            dict["gear"] = player->Prop().GetLandingGear();
            dict["flaps"] = player->Prop().GetFlap();
            dict["brake"] = (player->Prop().GetBrake() == YSTRUE);
            dict["spoiler"] = player->Prop().GetSpoiler();
            const double max_fuel = player->Prop().GetMaxFuelLoad();
            dict["fuel_pct"] = (max_fuel > 1e-6) ? (100.0 * player->Prop().GetFuelLeft() / max_fuel) : 100.0;
            dict["cockpit_local"] = ys_to_godot_pos(player->GetCockpitPosition());
            dict["velocity"] = ys_to_godot_pos(vel_vec);
            dict["outside_radius"] = (double)player->Prop().GetOutsideRadius();
            dict["is_alive"] = (player->IsAlive() == YSTRUE);
            dict["iff"] = (int64_t)player->GetIff();
            dict["identifier"] = godot::String(player->GetIdentifier());

            // Weapon & Radar Telemetry
            const FSWEAPONTYPE woc = player->Prop().GetWeaponOfChoice();
            const char *woc_str = FsGetWeaponString(woc);
            dict["weapon_type"] = (int64_t)woc;
            dict["weapon_name"] = godot::String(woc_str != nullptr ? woc_str : "NONE");
            dict["ammo_count"] = (int64_t)player->Prop().GetNumWeapon(woc);
            dict["gun_ammo"] = (int64_t)player->Prop().GetNumWeapon(FSWEAPON_GUN);
            dict["flare_count"] = (int64_t)player->Prop().GetNumWeapon(FSWEAPON_FLARE);
            dict["aim9_count"] = (int64_t)player->Prop().GetNumWeapon(FSWEAPON_AIM9);
            dict["aim9x_count"] = (int64_t)player->Prop().GetNumWeapon(FSWEAPON_AIM9X);
            dict["aim120_count"] = (int64_t)player->Prop().GetNumWeapon(FSWEAPON_AIM120);
            dict["agm65_count"] = (int64_t)player->Prop().GetNumWeapon(FSWEAPON_AGM65);
            dict["bomb_count"] = (int64_t)(
                player->Prop().GetNumWeapon(FSWEAPON_BOMB) +
                player->Prop().GetNumWeapon(FSWEAPON_BOMB250) +
                player->Prop().GetNumWeapon(FSWEAPON_BOMB500HD));
            dict["rocket_count"] = (int64_t)player->Prop().GetNumWeapon(FSWEAPON_ROCKET);

            const unsigned int air_tgt_key = player->Prop().GetAirTargetKey();
            const unsigned int gnd_tgt_key = player->Prop().GetGroundTargetKey();
            dict["locked_air_target_key"] = (air_tgt_key != YSNULLHASHKEY) ? (int64_t)air_tgt_key : (int64_t)-1;
            dict["locked_ground_target_key"] = (gnd_tgt_key != YSNULLHASHKEY) ? (int64_t)gnd_tgt_key : (int64_t)-1;
            dict["aam_range"] = (double)player->Prop().GetAAMRange(woc);
            dict["agm_range"] = (double)player->Prop().GetAGMRange();
            dict["radar_range"] = (double)player->Prop().GetCurrentRadarRange();
            dict["is_locked_by_enemy"] = (sim->IsLockedOn(player, YSFALSE) == YSTRUE);
            dict["is_missile_chasing"] = (sim->GetWeaponStore().IsLockedOn(player) == YSTRUE);

            const FsAirplane *gun_target = nullptr;
            YsVec3 gun_aim = YsOrigin();
            if (sim->SimCalculateGunAim(gun_target, gun_aim) == YSOK && gun_target != nullptr) {
                dict["has_gun_lead"] = true;
                // Shift by the player's interpolation offset so the pipper stays locked to the drawn cockpit/HUD
                const Vector3 interp_offset = air_render_transform(player).origin - ys_to_godot_pos(player->GetPosition());
                dict["gun_lead_pos"] = ys_to_godot_pos(gun_aim) + interp_offset;
                dict["gun_lead_target_pos"] = ys_to_godot_pos(gun_target->GetPosition()) + interp_offset;
                dict["gun_lead_target_key"] = (int64_t)gun_target->SearchKey();
            } else {
                dict["has_gun_lead"] = false;
            }
        }
    }
    return dict;
}

godot::PackedVector3Array YSFlightSimulation::get_tower_positions() const {
    godot::PackedVector3Array towers;
    if (sim != nullptr) {
        const int n = sim->GetNumTowerView();
        for (int i = 0; i < n; ++i) {
            towers.push_back(ys_to_godot_pos(sim->GetTowerView(i)));
        }
    }
    return towers;
}

void YSFlightSimulation::set_cockpit_cull_mode(bool enabled) {
    // Only the player's own aircraft needs back-face culling in the cockpit (so the canopy doesn't
    // block the view). Enabling is applied in sync_visual_entities(), which also follows player changes.
    cockpit_mode = enabled;
    if (!enabled && cockpit_key_valid) {
        auto it = airplane_visuals.find(cockpit_key);
        if (it != airplane_visuals.end()) {
            apply_cockpit_materials(it->second, false);
        }
        cockpit_key_valid = false;
    }
}

void YSFlightSimulation::apply_cockpit_materials(EntityVisual &ev, bool enabled) {
    for (Node3D *n : ev.dnm_nodes) {
        MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(n);
        if (mi == nullptr) {
            continue;
        }
        Ref<Mesh> mesh = mi->get_mesh();
        if (mesh.is_null()) {
            continue;
        }
        const int surface_count = mesh->get_surface_count();
        for (int i = 0; i < surface_count; ++i) {
            Ref<Material> override_mat;
            if (enabled) {
                Ref<Material> m = mesh->surface_get_material(i);
                if (m.ptr() == mat_lit.ptr()) {
                    override_mat = mat_lit_cockpit;
                } else if (m.ptr() == mat_trans.ptr()) {
                    override_mat = mat_trans_cockpit;
                }
            }
            mi->set_surface_override_material(i, override_mat);
        }
    }
    ev.cockpit_applied = enabled;
}

// A degenerate (invisible) triangle using the cockpit materials, never frustum-culled, drawn for the
// first frames after load so their shaders and pipelines are compiled before the player presses F1.
void YSFlightSimulation::build_prewarm_node() {
    PackedVector3Array v, n;
    PackedColorArray c;
    for (int i = 0; i < 3; ++i) {
        v.push_back(Vector3());
        n.push_back(Vector3(0, 1, 0));
        c.push_back(Color(1, 1, 1, 0.5));
    }
    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = v;
    arrays[Mesh::ARRAY_NORMAL] = n;
    arrays[Mesh::ARRAY_COLOR] = c;
    Ref<ArrayMesh> mesh;
    mesh.instantiate();
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    mesh->surface_set_material(0, mat_lit_cockpit);
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    mesh->surface_set_material(1, mat_trans_cockpit);
    mesh->set_custom_aabb(AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7)));

    prewarm_node = memnew(MeshInstance3D);
    prewarm_node->set_name("CockpitMaterialPrewarm");
    prewarm_node->set_mesh(mesh);
    prewarm_node->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
    scenery_root->add_child(prewarm_node);
    prewarm_frames_left = 30;
}

godot::Color YSFlightSimulation::get_sky_color() const {
    if (sim != nullptr && sim->GetField() != nullptr) {
        YsColor gndCol, skyCol;
        sim->GetField()->GetGroundSkyColor(gndCol, skyCol);
        return ys_to_godot_color(skyCol);
    }
    return Color(0.4f, 0.6f, 0.9f);
}

godot::Color YSFlightSimulation::get_ground_color() const {
    if (sim != nullptr && sim->GetField() != nullptr) {
        YsColor gndCol, skyCol;
        sim->GetField()->GetGroundSkyColor(gndCol, skyCol);
        return ys_to_godot_color(gndCol);
    }
    return Color(0.2f, 0.5f, 0.2f);
}

void YSFlightSimulation::set_player_inputs(double elevator, double aileron, double rudder, double throttle) {
    if (sim == nullptr) {
        return;
    }
    FsAirplane *player = sim->GetPlayerAirplane();
    if (player != nullptr) {
        FsFlightControl ctrl;
        player->Prop().ReadBackControl(ctrl);
        ctrl.ctlElevator = elevator;
        ctrl.ctlAileron = aileron;
        ctrl.ctlRudder = rudder;
        ctrl.ctlThrottle = throttle;
        ctrl.ctlAb = (throttle >= 0.98) ? YSTRUE : YSFALSE;
        // Apply only stick and throttle so trigger states set via set_player_weapon_inputs are preserved
        player->Prop().ApplyControl(ctrl, FSAPPLYCONTROL_STICK | FSAPPLYCONTROL_THROTTLE);
    }
}

// ----------------------------------------------------------------------------
// Controls bridge. controls.gd owns the continuous values (stick, rudder, throttle, afterburner, trim)
// and sends them every physics tick. Discrete YS button functions (gear, flaps, brakes, radar, ...) go
// through YS's own FsFlightControl::ProcessButtonFunction so they behave exactly like YSFlight.
// ----------------------------------------------------------------------------
void YSFlightSimulation::set_player_flight_inputs(double elevator, double aileron, double rudder, double throttle, bool afterburner, double trim) {
    if (sim == nullptr) {
        return;
    }
    FsAirplane *player = sim->GetPlayerAirplane();
    if (player == nullptr) {
        return;
    }
    FsFlightControl ctrl;
    player->Prop().ReadBackControl(ctrl);
    ctrl.ctlElevator = elevator;
    ctrl.ctlAileron = aileron;
    ctrl.ctlRudder = rudder;
    ctrl.ctlElvTrim = trim;
    ctrl.ctlThrottle = throttle;
    ctrl.ctlAb = afterburner ? YSTRUE : YSFALSE;
    // Stick and throttle only: trigger states set by set_player_weapon_inputs are preserved
    player->Prop().ApplyControl(ctrl, FSAPPLYCONTROL_STICK | FSAPPLYCONTROL_THROTTLE);
}

// YS button functions that act purely on the aircraft's FsFlightControl (names = FSBTF_* without prefix).
static bool ys_button_function_from_name(const godot::String &name, FSBUTTONFUNCTION &fnc) {
    struct Entry { const char *name; FSBUTTONFUNCTION fnc; };
    static const Entry table[] = {
        {"LANDINGGEAR", FSBTF_LANDINGGEAR},
        {"FLAPUP", FSBTF_FLAPUP},
        {"FLAPDOWN", FSBTF_FLAPDOWN},
        {"FLAPFULLUP", FSBTF_FLAPFULLUP},
        {"FLAPFULLDOWN", FSBTF_FLAPFULLDOWN},
        {"BRAKEONOFF", FSBTF_BRAKEONOFF},
        {"SPOILER", FSBTF_SPOILER},
        {"SPOILERBRAKE", FSBTF_SPOILERBRAKE},
        {"RADAR", FSBTF_RADAR},
        {"RADARRANGEUP", FSBTF_RADARRANGEUP},
        {"RADARRANGEDOWN", FSBTF_RADARRANGEDOWN},
        {"VELOCITYINDICATOR", FSBTF_VELOCITYINDICATOR},
        {"BOMBBAYDOOR", FSBTF_BOMBBAYDOOR},
        {"TOGGLELIGHT", FSBTF_TOGGLELIGHT},
        {"TOGGLEALLDOOR", FSBTF_TOGGLEALLDOOR},
        {"NOZZLEUP", FSBTF_NOZZLEUP},
        {"NOZZLEDOWN", FSBTF_NOZZLEDOWN},
    };
    for (const Entry &e : table) {
        if (name == e.name) {
            fnc = e.fnc;
            return true;
        }
    }
    return false;
}

bool YSFlightSimulation::press_button(godot::String function_name) {
    if (sim == nullptr) {
        return false;
    }
    FsAirplane *player = sim->GetPlayerAirplane();
    FSBUTTONFUNCTION fnc;
    if (player == nullptr || player->IsAlive() != YSTRUE || !ys_button_function_from_name(function_name, fnc)) {
        return false;
    }
    FsFlightControl ctrl;
    player->Prop().ReadBackControl(ctrl);
    ctrl.ProcessButtonFunction(sim->CurrentTime(), player, fnc);
    // Everything except stick/throttle (owned by controls.gd) and triggers (set_player_weapon_inputs)
    player->Prop().ApplyControl(ctrl, FSAPPLYCONTROL_ALL & ~(FSAPPLYCONTROL_STICK | FSAPPLYCONTROL_THROTTLE | FSAPPLYCONTROL_TRIGGER));
    return true;
}

// ----------------------------------------------------------------------------
// Flight setup / respawn. Uses the same YS calls as the YS multiplayer server when a player joins:
// FsWorld::AddAirplane + SettleAirplane at a named start position (.stp), zero speed on carriers,
// then SetPlayerAirplane (which also records the player change for flight records).
// The dead aircraft stays in the sim as a wreck (hidden by the visual sync once it is not the player).
// ----------------------------------------------------------------------------
godot::PackedStringArray YSFlightSimulation::get_airplane_template_names() const {
    godot::PackedStringArray names;
    if (world == nullptr) {
        return names;
    }
    for (int i = 0; ; ++i) {
        const char *n = world->GetAirplaneTemplateName(i);
        if (n == nullptr) {
            break;
        }
        names.push_back(godot::String(n));
    }
    return names;
}

godot::PackedStringArray YSFlightSimulation::get_start_position_names() const {
    godot::PackedStringArray names;
    if (world == nullptr || sim == nullptr || sim->GetField() == nullptr) {
        return names;
    }
    const char *field_name = sim->GetField()->GetIdName();
    YsString stp;
    for (int i = 0; world->GetFieldStartPositionName(stp, field_name, i) == YSOK; ++i) {
        names.push_back(godot::String(stp.Txt()));
    }
    return names;
}

bool YSFlightSimulation::is_helicopter_template(godot::String airplane_name) const {
    if (world == nullptr) {
        return false;
    }
    return world->IsHelicopterTemplate(airplane_name.utf8().get_data()) == YSTRUE;
}

bool YSFlightSimulation::respawn_player(godot::String airplane_name, godot::String start_position, int64_t iff) {
    if (world == nullptr || sim == nullptr) {
        return false;
    }
    const godot::CharString name_utf8 = airplane_name.utf8();
    const godot::CharString stp_utf8 = start_position.utf8();
    FsAirplane *air = world->AddAirplane(name_utf8.get_data(), YSTRUE);
    if (air == nullptr) {
        write_log_line((String("respawn_player: unknown aircraft ") + airplane_name).utf8().get_data());
        return false;
    }
    if (world->SettleAirplane(*air, stp_utf8.get_data()) != YSOK) {
        write_log_line((String("respawn_player: unknown start position ") + start_position).utf8().get_data());
    }
    air->SetIff((FSIFF)iff);
    if (start_position.find("CARRIER") >= 0) {
        air->SendCommand("INITSPED 0kt");
    }
    sim->SetPlayerAirplane(air);
    write_log_line((String("respawn_player: ") + airplane_name + " at " + start_position + " IFF" + String::num_int64(iff + 1)).utf8().get_data());
    return true;
}

// ----------------------------------------------------------------------------
// Radar data. All contacts are returned in the player's HEADING-UP horizontal frame (metres):
// right = +x to the right of the nose, fwd = ahead, alt = height above (+) / below (-) the player.
// Positions are the motion-interpolated render positions, so blips move smoothly.
// VISIBILITY RULES ARE CONFIGURABLE HERE (user: show everything for now, but keep it reconfigurable):
//   radar_mode 0 = every alive aircraft within range (current RvB rule)
//   radar_mode 1 = only contacts inside +/-RADAR_CONE_DEG of the nose (azimuth and elevation)
//   future: terrain masking (line of sight against the field), notching, jammers -> add modes here.
// Returns: { contacts: PackedFloat32Array stride 8 [key, right, fwd, alt, rel_heading_rad, iff, locked, speed_ms],
//            ground:   PackedFloat32Array stride 6 [key, right, fwd, alt, iff, locked],
//            missiles: PackedFloat32Array stride 5 [right, fwd, alt, flags (1 = chasing the player,
//                      2 = fired by the player), weapon_type] }
// ----------------------------------------------------------------------------
static const double RADAR_CONE_DEG = 60.0;

void YSFlightSimulation::set_radar_mode(int64_t mode) {
    radar_mode = (int)mode;
}

godot::Dictionary YSFlightSimulation::get_radar_contacts(double range_m) {
    godot::Dictionary out;
    godot::PackedFloat32Array contacts, ground, missiles;
    FsAirplane *player = sim != nullptr ? sim->GetPlayerAirplane() : nullptr;
    if (player == nullptr || player->IsAlive() != YSTRUE) {
        out["contacts"] = contacts;
        out["ground"] = ground;
        out["missiles"] = missiles;
        return out;
    }
    const Transform3D pt = air_render_transform(player);
    Vector3 fwd = -pt.basis.get_column(2);
    fwd.y = 0.0f;
    if (fwd.length_squared() < 1e-6f) {
        fwd = -pt.basis.get_column(1); // pointing straight up/down: use the aircraft's up vector for heading
        fwd.y = 0.0f;
    }
    fwd = fwd.normalized();
    const Vector3 right = fwd.cross(Vector3(0, 1, 0));
    const Vector3 nose = -pt.basis.get_column(2);
    const double range2 = range_m * range_m;
    const double cone_cos = cos(RADAR_CONE_DEG * YsPi / 180.0);
    const unsigned int air_tgt = player->Prop().GetAirTargetKey();
    const unsigned int gnd_tgt = player->Prop().GetGroundTargetKey();

    auto visible = [&](const Vector3 &d) -> bool {
        if ((double)d.length_squared() > range2) {
            return false;
        }
        if (radar_mode == 1) {
            const float len = d.length();
            return len < 1.0f || (double)(nose.dot(d / len)) >= cone_cos;
        }
        return true;
    };

    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        if (air == player || air->IsAlive() != YSTRUE) {
            continue;
        }
        const Transform3D t = air_render_transform(air);
        const Vector3 d = t.origin - pt.origin;
        if (!visible(d)) {
            continue;
        }
        Vector3 cf = -t.basis.get_column(2);
        const float rel_hdg = atan2f(cf.dot(right), cf.dot(fwd));
        YsVec3 vel = YsOrigin();
        air->Prop().GetVelocity(vel);
        const float row[8] = {(float)air->SearchKey(), d.dot(right), d.dot(fwd), d.y, rel_hdg, (float)air->GetIff(),
                              air->SearchKey() == air_tgt ? 1.0f : 0.0f, (float)vel.GetLength()};
        for (float f : row) {
            contacts.push_back(f);
        }
    }

    FsGround *gnd = nullptr;
    while ((gnd = sim->FindNextGround(gnd)) != nullptr) {
        if (gnd->IsAlive() != YSTRUE || gnd->Prop().IsNonGameObject() == YSTRUE) {
            continue;
        }
        const Vector3 d = gnd_render_transform(gnd).origin - pt.origin;
        if (!visible(d)) {
            continue;
        }
        const float row[6] = {(float)gnd->SearchKey(), d.dot(right), d.dot(fwd), d.y, (float)gnd->GetIff(),
                              gnd->SearchKey() == gnd_tgt ? 1.0f : 0.0f};
        for (float f : row) {
            ground.push_back(f);
        }
    }

    const FsWeapon *wpn = nullptr;
    while ((wpn = sim->FindNextActiveWeapon(wpn)) != nullptr) {
        if (wpn->lifeRemain <= 0.0) {
            continue;
        }
        if (wpn->type != FSWEAPON_AIM9 && wpn->type != FSWEAPON_AIM9X && wpn->type != FSWEAPON_AIM120 && wpn->type != FSWEAPON_AGM65) {
            continue;
        }
        const Vector3 d = wpn_render_transform(wpn).origin - pt.origin;
        if ((double)d.length_squared() > range2) {
            continue; // missiles are shown regardless of radar_mode (missile warning is a separate sensor)
        }
        float flags = 0.0f;
        if (wpn->target == player) {
            flags += 1.0f;
        }
        if (wpn->firedBy == player) {
            flags += 2.0f;
        }
        const float row[5] = {d.dot(right), d.dot(fwd), d.y, flags, (float)wpn->type};
        for (float f : row) {
            missiles.push_back(f);
        }
    }

    out["contacts"] = contacts;
    out["ground"] = ground;
    out["missiles"] = missiles;
    return out;
}

// ----------------------------------------------------------------------------
// Aircraft effects state, once per rendered frame (aircraft_fx.gd draws it with the GPU smoke system).
// aircraft: PackedFloat32Array stride 18 per aircraft that is flying or falling after being killed.
//   NOTE: YS keeps a shot-down aircraft "alive" (IsAlive() == true) while it spins down (FSDEADSPIN /
//   FSDEADFLATSPIN) and only sets FSDEAD when it hits the ground; 1 kill in 7 is FSDEAD instantly in the
//   air (explodes, no falling wreck). "dying" = spinning down.
//   [key, pos x/y/z, vel x/y/z, damage 0..1 (1 - damage tolerance / default), state (0 flying, 1 dying),
//    vapor (0/1, YS IsTrailingVapor: high G), vapor tip x/y/z (right wingtip, Godot local; mirror x for
//    the left tip), radius (m), forward x/y/z (unit, world)]
//   Positions are the interpolated render positions (effects line up with the models).
// crashes: PackedFloat32Array stride 5 per aircraft that hit the ground since the previous call:
//   [x, y, z, on_water (0/1), radius]. Water = terrain elevation within 1 m of sea level (y = 0), a
//   heuristic that fits RvB maps (sea at y = 0); revisit if a map has water at other heights.
// ----------------------------------------------------------------------------
godot::Dictionary YSFlightSimulation::get_aircraft_fx_state() {
    godot::Dictionary out;
    godot::PackedFloat32Array aircraft, crashes;
    if (sim == nullptr) {
        out["aircraft"] = aircraft;
        out["crashes"] = crashes;
        return out;
    }
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        const unsigned int key = air->SearchKey();
        const bool alive = (air->IsAlive() == YSTRUE);
        const YsVec3 ys_pos = air->GetPosition();
        const double ground_y = sim->GetFieldElevation(ys_pos.x(), ys_pos.z());
        const bool on_ground = (ys_pos.y() - ground_y) < 5.0;
        if (!alive && on_ground) {
            if (fx_crashed_keys.insert(key).second) { // first frame on the ground after dying
                const Vector3 p = ys_to_godot_pos(ys_pos);
                const float row[5] = {p.x, p.y, p.z, fabs(ground_y) < 1.0 ? 1.0f : 0.0f, (float)air->Prop().GetOutsideRadius()};
                for (float f : row) {
                    crashes.push_back(f);
                }
            }
            continue;
        }
        if (!alive) {
            continue; // FSDEAD in the air: destroyed outright (the explosion effect covers it)
        }
        const FSFLIGHTSTATE flight_state = air->Prop().GetFlightState();
        const bool dying = (flight_state == FSDEADSPIN || flight_state == FSDEADFLATSPIN);
        if (!dying) {
            fx_crashed_keys.erase(key); // flying again (respawned object): allow a new crash event
        }
        const Transform3D t = air_render_transform(air);
        YsVec3 vel = YsOrigin();
        air->Prop().GetVelocity(vel);
        const Vector3 v = ys_to_godot_pos(vel);
        const int def_tol = air->GetDefaultDamageTolerance();
        const double damage = def_tol > 0 ? YsBound(1.0 - (double)air->Prop().GetDamageTolerance() / (double)def_tol, 0.0, 1.0) : 0.0;
        YsVec3 vap_ys = YsOrigin();
        air->Prop().GetVaporPosition(vap_ys);
        const Vector3 vap = ys_to_godot_pos(vap_ys);
        const Vector3 fwd = -t.basis.get_column(2).normalized();
        const float row[18] = {(float)key, t.origin.x, t.origin.y, t.origin.z, v.x, v.y, v.z, (float)damage,
                               dying ? 1.0f : 0.0f, (!dying && air->Prop().IsTrailingVapor() == YSTRUE) ? 1.0f : 0.0f,
                               vap.x, vap.y, vap.z, (float)air->Prop().GetOutsideRadius(), fwd.x, fwd.y, fwd.z};
        for (float f : row) {
            aircraft.push_back(f);
        }
    }
    out["aircraft"] = aircraft;
    out["crashes"] = crashes;
    return out;
}

void YSFlightSimulation::debug_kill_player() {
    if (sim != nullptr && sim->GetPlayerAirplane() != nullptr) {
        // Same as a real shoot-down: spin down until impact (YS GetDamage picks FSDEAD/SPIN/FLATSPIN)
        sim->GetPlayerAirplane()->Prop().SetFlightState(FSDEADSPIN, FSDIEDOF_NULL);
    }
}

// Direct value for hold-style or analog controls: "brake", "spoiler", "flap", "gear" (0..1).
void YSFlightSimulation::set_player_control(godot::String name, double value) {
    if (sim == nullptr) {
        return;
    }
    FsAirplane *player = sim->GetPlayerAirplane();
    if (player == nullptr || player->IsAlive() != YSTRUE) {
        return;
    }
    FsFlightControl ctrl;
    player->Prop().ReadBackControl(ctrl);
    const double v = YsBound(value, 0.0, 1.0);
    unsigned int what = 0;
    if (name == "brake") {
        ctrl.ctlBrake = v;
        what = FSAPPLYCONTROL_BRAKE;
    } else if (name == "spoiler") {
        ctrl.ctlSpoiler = v;
        what = FSAPPLYCONTROL_SPOILER;
    } else if (name == "flap") {
        ctrl.ctlFlap = v;
        what = FSAPPLYCONTROL_FLAP;
    } else if (name == "gear") {
        ctrl.ctlGear = v;
        what = FSAPPLYCONTROL_GEAR;
    }
    if (what != 0) {
        player->Prop().ApplyControl(ctrl, what);
    }
}

// Selects a weapon type (FSWEAPONTYPE) if the player carries it. Returns false if not available.
bool YSFlightSimulation::select_weapon(int64_t weapon_type) {
    if (sim == nullptr) {
        return false;
    }
    FsAirplane *player = sim->GetPlayerAirplane();
    if (player == nullptr || player->IsAlive() != YSTRUE) {
        return false;
    }
    const FSWEAPONTYPE wanted = (FSWEAPONTYPE)weapon_type;
    return player->Prop().SetWeaponOfChoice(wanted) == YSOK && player->Prop().GetWeaponOfChoice() == wanted;
}

void YSFlightSimulation::set_player_weapon_inputs(
    bool fire_selected_held,
    bool fire_selected_just_pressed,
    bool fire_gun_held,
    bool cycle_weapon_just_pressed,
    bool dispense_flare_just_pressed)
{
    if (sim == nullptr) {
        return;
    }
    FsAirplane *player = sim->GetPlayerAirplane();
    if (player == nullptr || player->IsAlive() != YSTRUE) {
        return;
    }

    if (cycle_weapon_just_pressed) {
        player->Prop().CycleWeaponOfChoice();
    }

    // Dedicated gun trigger (fires gun continuously even when another weapon is selected)
    player->Prop().SetFireGunButton(fire_gun_held ? YSTRUE : YSFALSE);

    // Selected weapon trigger:
    // - If GUN or SMOKE is selected, holding the button fires continuously via ctlFireWeaponButton.
    // - Calling SetFireWeaponButton twice synchronizes pCtlFireWeaponButton = ctlFireWeaponButton
    //   so discrete weapons are fired deterministically via explicit VBT_FIREWEAPON below.
    const YSBOOL fw_state = fire_selected_held ? YSTRUE : YSFALSE;
    player->Prop().SetFireWeaponButton(fw_state);
    player->Prop().SetFireWeaponButton(fw_state);

    const FSWEAPONTYPE woc = player->Prop().GetWeaponOfChoice();
    if (fire_selected_just_pressed && woc != FSWEAPON_GUN && woc != FSWEAPON_SMOKE) {
        player->Prop().PressVirtualButton(FsAirplaneProperty::VBT_FIREWEAPON);
    }

    if (dispense_flare_just_pressed) {
        player->Prop().PressVirtualButton(FsAirplaneProperty::VBT_DISPENSEFLARE);
    }
}

