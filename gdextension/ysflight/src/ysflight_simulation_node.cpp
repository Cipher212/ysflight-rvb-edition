#include "ysflight_simulation_node.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <direct.h>

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "bridge/radar_query.h"
#include "core/crashlog.h"
#include "core/ys_convert.h"
#include "core/ys_headers.h"
#include "render/scenery_builder.h"
#include "sim/ai_setup.h"
#include "sim/flight_setup.h"
#include "sim/player_input.h"
#include "sim/sim_queries.h"

// Declared extern in fsfilename.cpp (normally defined in fsmain.cpp, which is not compiled here).
// FsGetUserYsflightDir() builds paths with it and would crash on a null name.
const wchar_t *FsProgramName = L"YSFLIGHT";
const char *FsProgramTitle = "YSFLIGHT";

using namespace godot;

namespace {

using Clock = std::chrono::high_resolution_clock;

double ms_since(Clock::time_point t0) {
    return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

Node3D *make_root(Node *parent, const char *name) {
    Node3D *n = memnew(Node3D);
    n->set_name(name);
    parent->add_child(n);
    return n;
}

// Lines of fserr.txt (YS load errors) go to the session log and the console.
void forward_fserr_to_log() {
    FILE *fp = fopen("fserr.txt", "r");
    if (fp == nullptr) {
        return;
    }
    char line[512];
    while (fgets(line, sizeof(line), fp) != nullptr) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
            line[--len] = '\0';
        }
        if (len > 0) {
            char msg[600];
            snprintf(msg, sizeof(msg), "fserr.txt: %s", line);
            ysgd::log_line(msg);
            UtilityFunctions::print(String(msg));
        }
    }
    fclose(fp);
}

} // namespace

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
    ClassDB::bind_method(D_METHOD("get_map_base_color"), &YSFlightSimulation::get_map_base_color);
    ClassDB::bind_method(D_METHOD("get_frame_stats"), &YSFlightSimulation::get_frame_stats);
    ClassDB::bind_method(D_METHOD("get_audio_state"), &YSFlightSimulation::get_audio_state);
    ClassDB::bind_method(D_METHOD("reset_interpolation"), &YSFlightSimulation::reset_interpolation);
    ClassDB::bind_method(D_METHOD("set_interpolation_enabled", "enabled"), &YSFlightSimulation::set_interpolation_enabled);
    ClassDB::bind_method(D_METHOD("set_random_seed", "seed"), &YSFlightSimulation::set_random_seed);
    ClassDB::bind_method(D_METHOD("enable_player_autopilot"), &YSFlightSimulation::enable_player_autopilot);
    ClassDB::bind_method(D_METHOD("debug_kill_player"), &YSFlightSimulation::debug_kill_player);
    ClassDB::bind_method(D_METHOD("set_rvb_ai_enabled", "enabled"), &YSFlightSimulation::set_rvb_ai_enabled);
    ClassDB::bind_method(D_METHOD("set_ai_respawn_enabled", "enabled"), &YSFlightSimulation::set_ai_respawn_enabled);
    ClassDB::bind_method(D_METHOD("set_ai_ground_ops", "enabled"), &YSFlightSimulation::set_ai_ground_ops);
    ClassDB::bind_method(D_METHOD("get_ai_state"), &YSFlightSimulation::get_ai_state);
    ClassDB::bind_method(D_METHOD("set_sim_speed", "steps_per_tick"), &YSFlightSimulation::set_sim_speed);
    ClassDB::bind_method(D_METHOD("get_airplane_template_names"), &YSFlightSimulation::get_airplane_template_names);
    ClassDB::bind_method(D_METHOD("get_start_position_names"), &YSFlightSimulation::get_start_position_names);
    ClassDB::bind_method(D_METHOD("is_helicopter_template", "airplane_name"), &YSFlightSimulation::is_helicopter_template);
    ClassDB::bind_method(D_METHOD("respawn_player", "airplane_name", "start_position", "iff"), &YSFlightSimulation::respawn_player);
    ClassDB::bind_method(D_METHOD("get_radar_contacts", "range_m"), &YSFlightSimulation::get_radar_contacts);
    ClassDB::bind_method(D_METHOD("set_radar_mode", "mode"), &YSFlightSimulation::set_radar_mode);
    ClassDB::bind_method(D_METHOD("get_aircraft_fx_state"), &YSFlightSimulation::get_aircraft_fx_state);
    ClassDB::bind_method(D_METHOD("set_effects_quality", "quality"), &YSFlightSimulation::set_effects_quality);
    ClassDB::bind_method(D_METHOD("set_aircraft_shadows_enabled", "enabled"), &YSFlightSimulation::set_aircraft_shadows_enabled);
    ClassDB::bind_method(D_METHOD("get_effects_stats"), &YSFlightSimulation::get_effects_stats);
    ClassDB::bind_method(D_METHOD("set_cockpit_cull_mode", "enabled"), &YSFlightSimulation::set_cockpit_cull_mode);
    ClassDB::bind_method(D_METHOD("set_player_flight_inputs", "elevator", "aileron", "rudder", "throttle", "afterburner", "trim"),
                         &YSFlightSimulation::set_player_flight_inputs);
    ClassDB::bind_method(D_METHOD("press_button", "function_name"), &YSFlightSimulation::press_button);
    ClassDB::bind_method(D_METHOD("set_player_control", "name", "value"), &YSFlightSimulation::set_player_control);
    ClassDB::bind_method(D_METHOD("select_weapon", "weapon_type"), &YSFlightSimulation::select_weapon);
    ClassDB::bind_method(D_METHOD("set_player_weapon_inputs", "fire_selected_held", "fire_selected_just_pressed", "fire_gun_held",
                                  "cycle_weapon_just_pressed", "dispense_flare_just_pressed"),
                         &YSFlightSimulation::set_player_weapon_inputs);
}

YSFlightSimulation::YSFlightSimulation() {}

YSFlightSimulation::~YSFlightSimulation() {
    mesh_cache.clear();
    delete world;
    world = nullptr;
}

// ----------------------------------------------------------------------------------------------------------
// Lifecycle
// ----------------------------------------------------------------------------------------------------------

void YSFlightSimulation::initialize_simulation() {
    // Physics: run AFTER every other node so player inputs set in the same tick are simulated immediately.
    // Process: run BEFORE every other node so the camera, HUD and effects read this frame's transforms.
    set_physics_process_priority(100);
    set_process_priority(-100);
    ysgd::crashlog_init(ProjectSettings::get_singleton()->globalize_path("res://"));
    ysgd::set_breadcrumb("initialize_simulation: new FsWorld");
    ysgd::log_line("initialize_simulation() called.");

    materials.init();
    delete world;
    world = new FsWorld();
    sim = nullptr;
    ysgd::set_breadcrumb("initialize_simulation: done");
    ysgd::log_line("FsWorld initialized successfully.");
    UtilityFunctions::print("YSFlight: FsWorld initialized.");
}

void YSFlightSimulation::log_to_crashlog(String msg) {
    ysgd::log_line(msg);
}

void YSFlightSimulation::reset_scene_roots() {
    for (Node3D *root : {scenery_root, airplanes_root, grounds_root, weapons_root, effects_root}) {
        if (root != nullptr) {
            root->queue_free();
        }
    }
    scenery_root = make_root(this, "SceneryRoot");
    airplanes_root = make_root(this, "AirplanesRoot");
    grounds_root = make_root(this, "GroundsRoot");
    weapons_root = make_root(this, "WeaponsRoot");
    effects_root = make_root(this, "EffectsRoot");
    mesh_cache.clear();
    visual_sync.attach(airplanes_root, grounds_root, weapons_root);
    shadows.attach(effects_root);
    trails.attach(effects_root);
    weapon_fx.attach(effects_root);
    audio.reset();
    aircraft_fx.reset();
    telemetry_stamp = FrameStamp();
    airplanes_stamp = FrameStamp();
}

void YSFlightSimulation::load_yfs(String file_path) {
    if (world == nullptr) {
        UtilityFunctions::print("YSFlight Error: call initialize_simulation() before load_yfs().");
        return;
    }
    ysgd::set_breadcrumb("load_yfs: reset scene");
    ysgd::log_line(String("load_yfs() starting for: ") + file_path);
    materials.init();
    reset_scene_roots();

    // YS reads its data files relative to the working directory = the Godot project folder
    const String res_path = ProjectSettings::get_singleton()->globalize_path("res://");
    _wchdir((const wchar_t *)res_path.utf16().get_data());

    ysgd::load_rvb_roles("res://rvb_roles.txt");  // Before world->Load: the mission's AIs are wrapped while loading
    ysgd::reset_rvb_ai();
    ai_respawn.reset();

    ysgd::set_breadcrumb("load_yfs: LoadTemplateAll");
    ysgd::log_line("Calling world->LoadTemplateAll()...");
    FsUseLocalFolderSetting();
    remove("fserr.txt");
    world->LoadTemplateAll();
    FsWeaponHolder::LoadMissilePattern();
    ysgd::log_line("Templates and missile patterns loaded.");

    const String global_path = ProjectSettings::get_singleton()->globalize_path(file_path);
    UtilityFunctions::print("YSFlight: Loading " + global_path);
    ysgd::set_breadcrumb("load_yfs: world->Load");
    const YSRESULT load_res = world->Load((const wchar_t *)global_path.utf16().get_data());
    ysgd::log_line(load_res == YSOK ? "world->Load() finished with YSOK." : "ERROR: world->Load() returned YSERR!");
    if (load_res != YSOK) {
        UtilityFunctions::print("YSFlight Error: world->Load returned YSERR!");
    }
    forward_fserr_to_log();

    ysgd::set_breadcrumb("load_yfs: PrepareSimulation");
    world->PrepareSimulation();
    sim = world->GetSimulation();
    ysgd::feed_start_runways(world, sim);

    ysgd::set_breadcrumb("load_yfs: build_scenery");
    map_base_color = ysgd::build_scenery(sim, scenery_root, materials, mesh_cache);
    visual_sync.build_prewarm(scenery_root);
    interp.reset(sim);

    ysgd::set_breadcrumb("load_yfs: initial visual sync");
    visual_sync.sync(sim, interp, YsOrigin());

    const String summary = "YSFlight: Visual sync complete. Airplanes: " + String::num_int64((int64_t)visual_sync.airplane_count()) +
                           ", Ground objects: " + String::num_int64((int64_t)visual_sync.ground_count()) +
                           ", Cached unique shells: " + String::num_int64((int64_t)mesh_cache.size());
    UtilityFunctions::print(summary);
    ysgd::log_line(summary);
    ysgd::set_breadcrumb("load_yfs: done");
}

void YSFlightSimulation::_physics_process(double delta) {
    if (world == nullptr || sim == nullptr) {
        return;
    }
    ++ysgd::g_crash_stats.physics_frame;
    ysgd::g_crash_stats.sim_time = sim->CurrentTime();

    // The physics tick only steps the simulation. Visual sync runs once per rendered frame in _process(),
    // so catch-up ticks (several per frame when FPS drops) stay cheap.
    const auto t0 = Clock::now();
    ysgd::set_breadcrumb("_physics_process: SimulateOneStep");
    for (int step = 0; step < sim_speed; ++step) {
        world->SimulateOneStep(delta, YSFALSE, YSFALSE, YSFALSE, YSFALSE, FSUSC_SCRIPT, YSFALSE);
        ysgd::set_breadcrumb("_physics_process: AI respawn");
        ai_respawn.update(world, sim, delta);
        for (unsigned int key : ai_respawn.removed_keys()) {
            forget_airplane(key);
        }
    }
    ysgd::set_breadcrumb("_physics_process: interpolation capture");
    interp.capture(sim);
    ysgd::set_breadcrumb("_physics_process: trail record");
    trails.record(sim);
    ysgd::set_breadcrumb("_physics_process: idle");

    const double sim_ms = ms_since(t0);
    perf_sim_sum += sim_ms;
    perf_sim_max = sim_ms > perf_sim_max ? sim_ms : perf_sim_max;
    frame_sim_ms += sim_ms;
    ++frame_ticks;
    if (ysgd::g_crash_stats.physics_frame % 300 == 0) {
        write_heartbeat();
    }
}

void YSFlightSimulation::_process(double delta) {
    if (world == nullptr || sim == nullptr) {
        return;
    }
    visual_sync.step_prewarm();
    interp.begin_frame((double)Engine::get_singleton()->get_physics_interpolation_fraction());

    YsVec3 camera_pos = YsOrigin();
    if (sim->GetPlayerAirplane() != nullptr) {
        camera_pos = sim->GetPlayerAirplane()->GetPosition();
    }
    if (Viewport *vp = get_viewport()) {
        if (Camera3D *cam = vp->get_camera_3d()) {
            camera_pos = ysgd::godot_to_ys_pos(cam->get_global_position());
        }
    }
    const auto t0 = Clock::now();
    ysgd::set_breadcrumb("_process: visual sync");
    visual_sync.sync(sim, interp, camera_pos);
    shadows.sync(sim, interp, camera_pos);
    const double sync_ms = ms_since(t0);
    perf_sync_sum += sync_ms;
    perf_sync_max = sync_ms > perf_sync_max ? sync_ms : perf_sync_max;
    ++perf_sync_frames;
    frame_sync_ms = sync_ms;

    const auto t1 = Clock::now();
    ysgd::set_breadcrumb("_process: effects");
    const double tick_s = 1.0 / (double)Engine::get_singleton()->get_physics_ticks_per_second();
    const double render_time = sim->CurrentTime() - (1.0 - interp.alpha()) * tick_s; // what the models show
    trails.draw(sim, interp, render_time, ysgd::ys_to_godot_pos(camera_pos));
    weapon_fx.draw(sim, interp, Engine::get_singleton()->get_process_frames());
    frame_fx_ms = ms_since(t1);
    ysgd::set_breadcrumb("_process: idle");
}

void YSFlightSimulation::write_heartbeat() {
    int alive = 0;
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        alive += (air->IsAlive() == YSTRUE) ? 1 : 0;
    }
    char hb[512];
    snprintf(hb, sizeof(hb), "Heartbeat: Alive Airplanes=%d/%d | Active Weapons=%d", alive,
             (int)ysgd::g_crash_stats.airplanes, (int)ysgd::g_crash_stats.weapons);
    ysgd::log_line(hb);
    const int sync_n = perf_sync_frames > 0 ? perf_sync_frames : 1;
    snprintf(hb, sizeof(hb), "PERF C++: SimulateOneStep %.2f/%.2f ms per tick | sync_visual_entities %.2f/%.2f ms per frame (avg/max)",
             perf_sim_sum / 300.0, perf_sim_max, perf_sync_sum / sync_n, perf_sync_max);
    ysgd::log_line(hb);
    const ysgd::VisualSync::Perf vp = visual_sync.take_perf();
    const int split_n = vp.frames > 0 ? vp.frames : 1;
    snprintf(hb, sizeof(hb), "PERF sync split (ms per frame): airplanes %.2f | grounds %.2f (%.0f full updates/frame) | weapons %.2f | visuals: %d air, %d gnd, %d wpn active",
             vp.air_ms / split_n, vp.gnd_ms / split_n, (double)vp.gnd_full_updates / split_n, vp.wpn_ms / split_n,
             (int)visual_sync.airplane_count(), (int)visual_sync.ground_count(), (int)visual_sync.weapon_count());
    ysgd::log_line(hb);
    perf_sim_sum = perf_sim_max = perf_sync_sum = perf_sync_max = 0.0;
    perf_sync_frames = 0;
}

// [sim_ms, physics_ticks, sync_ms, alive_airplanes, active_weapons, active_explosions, visual_nodes, fx_ms]
// sim_ms and physics_ticks accumulate since the previous call (the previous rendered frame).
// fx_ms = C++ trails + tracers of the last frame.
PackedFloat64Array YSFlightSimulation::get_frame_stats() {
    PackedFloat64Array out;
    out.resize(8);
    int alive = 0, explosions = 0;
    if (sim != nullptr) {
        FsAirplane *air = nullptr;
        while ((air = sim->FindNextAirplane(air)) != nullptr) {
            alive += (air->IsAlive() == YSTRUE) ? 1 : 0;
        }
        for (const FsExplosion *exp = sim->GetExplosionStore().activeList; exp != nullptr; exp = exp->next) {
            ++explosions;
        }
    }
    out.set(0, frame_sim_ms);
    out.set(1, (double)frame_ticks);
    out.set(2, frame_sync_ms);
    out.set(3, (double)alive);
    out.set(4, (double)ysgd::g_crash_stats.weapons);
    out.set(5, (double)explosions);
    out.set(6, (double)(visual_sync.airplane_count() + visual_sync.ground_count() + visual_sync.weapon_count()));
    out.set(7, frame_fx_ms);
    frame_sim_ms = 0.0;
    frame_ticks = 0;
    return out;
}

// ----------------------------------------------------------------------------------------------------------
// Queries (forwarded to sim/sim_queries.cpp; the two per-frame heavy ones are cached)
// ----------------------------------------------------------------------------------------------------------

YSFlightSimulation::FrameStamp YSFlightSimulation::current_stamp() const {
    FrameStamp s;
    s.tick = ysgd::g_crash_stats.physics_frame;
    s.frame = Engine::get_singleton()->get_process_frames();
    return s;
}

Dictionary YSFlightSimulation::get_player_telemetry() {
    const FrameStamp now = current_stamp();
    if (!(telemetry_stamp == now)) {
        cached_telemetry = ysgd::player_telemetry(sim, interp);
        telemetry_stamp = now;
    }
    return cached_telemetry;
}

Dictionary YSFlightSimulation::get_airplane_transforms() {
    const FrameStamp now = current_stamp();
    if (!(airplanes_stamp == now)) {
        cached_airplanes = ysgd::airplane_states(sim, interp);
        airplanes_stamp = now;
    }
    return cached_airplanes;
}

Dictionary YSFlightSimulation::get_ground_transforms() const { return ysgd::ground_states(sim, interp); }
Dictionary YSFlightSimulation::get_ground_transform(int64_t key) const { return ysgd::ground_state(sim, interp, key); }
Array YSFlightSimulation::get_active_weapons() const { return ysgd::active_weapons(sim, interp); }
Array YSFlightSimulation::get_active_explosions() const { return ysgd::active_explosions(sim); }
PackedVector3Array YSFlightSimulation::get_tower_positions() const { return ysgd::tower_positions(sim); }
Color YSFlightSimulation::get_sky_color() const { return ysgd::sky_color(sim); }
Color YSFlightSimulation::get_map_base_color() const { return map_base_color; }

Transform3D YSFlightSimulation::get_player_transform() const {
    if (sim != nullptr && sim->GetPlayerAirplane() != nullptr) {
        return interp.air(sim->GetPlayerAirplane()); // the camera follows what is drawn
    }
    return Transform3D();
}

Dictionary YSFlightSimulation::get_audio_state() { return audio.collect(sim); }
Dictionary YSFlightSimulation::get_radar_contacts(double range_m) { return ysgd::radar_contacts(sim, interp, range_m, radar_mode); }
void YSFlightSimulation::set_radar_mode(int64_t mode) { radar_mode = (int)mode; }
Dictionary YSFlightSimulation::get_aircraft_fx_state() { return aircraft_fx.collect(sim, interp); }
void YSFlightSimulation::set_effects_quality(int64_t quality) { trails.set_quality((int)quality); }
void YSFlightSimulation::set_aircraft_shadows_enabled(bool enabled) { shadows.set_enabled(enabled); }

PackedInt32Array YSFlightSimulation::get_effects_stats() const {
    PackedInt32Array out;
    out.push_back(trails.segment_count());
    out.push_back(trails.trail_count());
    out.push_back(weapon_fx.tracer_count());
    out.push_back(weapon_fx.glow_count());
    return out;
}

void YSFlightSimulation::reset_interpolation() { interp.reset(sim); }
void YSFlightSimulation::set_interpolation_enabled(bool enabled) { interp.set_enabled(enabled); }
// Call before load_yfs() so the whole run (including mission load) uses the same random sequence.
void YSFlightSimulation::set_random_seed(int64_t seed) { srand((unsigned int)seed); }
bool YSFlightSimulation::enable_player_autopilot() { return ysgd::enable_player_autopilot(sim); }
void YSFlightSimulation::debug_kill_player() { ysgd::kill_player(sim); }
void YSFlightSimulation::set_rvb_ai_enabled(bool enabled) { ysgd::set_rvb_ai_enabled(enabled); }
void YSFlightSimulation::set_ai_respawn_enabled(bool enabled) { ai_respawn.set_enabled(enabled); }
void YSFlightSimulation::set_ai_ground_ops(bool enabled) { ysgd::set_rvb_ground_ops(enabled); }

Dictionary YSFlightSimulation::get_ai_state() {
    Dictionary d = ysgd::ai_state(sim);
    d["respawned"] = ai_respawn.respawned();
    d["wrecks_removed"] = ai_respawn.wrecks_removed();
    Dictionary cause, task;
    for (const auto &kv : ai_respawn.deaths_by_cause()) {
        cause[String(kv.first.c_str())] = kv.second;
    }
    for (const auto &kv : ai_respawn.deaths_by_task()) {
        task[String(kv.first.c_str())] = kv.second;
    }
    d["deaths_by_cause"] = cause;
    d["deaths_by_task"] = task;
    d["aircraft"] = ysgd::ai_aircraft_list(sim);
    return d;
}

void YSFlightSimulation::set_sim_speed(int64_t steps_per_tick) {
    sim_speed = (int)(steps_per_tick < 1 ? 1 : (steps_per_tick > 16 ? 16 : steps_per_tick));
}

void YSFlightSimulation::forget_airplane(unsigned int key) {
    visual_sync.forget_airplane(key);
    shadows.forget_airplane(key);
    interp.forget_air(key);
    aircraft_fx.forget(key);
}

// ----------------------------------------------------------------------------------------------------------
// Flight setup (sim/flight_setup.cpp) and controls (sim/player_input.cpp)
// ----------------------------------------------------------------------------------------------------------

PackedStringArray YSFlightSimulation::get_airplane_template_names() const { return ysgd::airplane_template_names(world); }
PackedStringArray YSFlightSimulation::get_start_position_names() const { return ysgd::start_position_names(world, sim); }
bool YSFlightSimulation::is_helicopter_template(String airplane_name) const { return ysgd::is_helicopter_template(world, airplane_name); }

bool YSFlightSimulation::respawn_player(String airplane_name, String start_position, int64_t iff) {
    telemetry_stamp = FrameStamp(); // the player aircraft changes: drop this frame's cached queries
    airplanes_stamp = FrameStamp();
    return ysgd::respawn_player(world, sim, airplane_name, start_position, iff);
}

void YSFlightSimulation::set_cockpit_cull_mode(bool enabled) { visual_sync.set_cockpit_mode(enabled); }

void YSFlightSimulation::set_player_flight_inputs(double elevator, double aileron, double rudder, double throttle, bool afterburner, double trim) {
    ysgd::set_flight_inputs(sim, elevator, aileron, rudder, throttle, afterburner, trim);
}

bool YSFlightSimulation::press_button(String function_name) { return ysgd::press_button(sim, function_name); }
void YSFlightSimulation::set_player_control(String name, double value) { ysgd::set_control(sim, name, value); }
bool YSFlightSimulation::select_weapon(int64_t weapon_type) { return ysgd::select_weapon(sim, weapon_type); }

void YSFlightSimulation::set_player_weapon_inputs(bool fire_selected_held, bool fire_selected_just_pressed, bool fire_gun_held,
                                                  bool cycle_weapon_just_pressed, bool dispense_flare_just_pressed) {
    ysgd::set_weapon_inputs(sim, fire_selected_held, fire_selected_just_pressed, fire_gun_held, cycle_weapon_just_pressed,
                            dispense_flare_just_pressed);
}
