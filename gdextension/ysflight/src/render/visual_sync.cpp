#include "render/visual_sync.h"

#include <algorithm>
#include <chrono>
#include <cmath>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include "core/crashlog.h"
#include "core/ys_convert.h"
#include "core/ys_headers.h"
#include "sim/motion_interp.h"

using namespace godot;

namespace ysgd {

namespace {

using Clock = std::chrono::high_resolution_clock;

const int DNM_CLASS_AFTERBURNER = 2; // DNM "CLA 2": YS shows these parts while the afterburner is on

double ms_between(Clock::time_point a, Clock::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}

// Model of a store hanging on a hardpoint (static shape). Flares are carried in flare pods.
FsVisualDnm *static_weapon_visual(const FsAirplane *owner, FSWEAPONTYPE type) {
    if (type == FSWEAPON_FLARE) {
        type = FSWEAPON_FLAREPOD;
    }
    if (owner != nullptr && (int)type >= 0 && (int)type < (int)FSWEAPON_NUMWEAPONTYPE) {
        FsVisualDnm &ov = owner->weaponShapeOverrideStatic[(int)type];
        if (ov.GetDnmPtr() != nullptr) {
            return &ov;
        }
    }
    switch (type) {
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
}

// Model of a flying (or jettisoned) weapon: the aircraft's override shape if it has one, else YS's own.
FsVisualDnm *flying_weapon_visual(const FsWeapon *wpn) {
    const bool jett = (wpn->shouldJettison == YSTRUE);
    if (wpn->firedBy != nullptr && (int)wpn->type >= 0 && (int)wpn->type < (int)FSWEAPON_NUMWEAPONTYPE) {
        FsVisualDnm &ov = jett ? wpn->firedBy->weaponShapeOverrideStatic[(int)wpn->type]
                               : wpn->firedBy->weaponShapeOverrideFlying[(int)wpn->type];
        if (ov.GetDnmPtr() != nullptr) {
            return &ov;
        }
    }
    switch (wpn->type) {
        case FSWEAPON_AIM9: return jett ? &FsWeapon::aim9s : &FsWeapon::aim9;
        case FSWEAPON_AIM9X: return jett ? &FsWeapon::aim9xs : &FsWeapon::aim9x;
        case FSWEAPON_AIM120: return jett ? &FsWeapon::aim120s : &FsWeapon::aim120;
        case FSWEAPON_AGM65: return jett ? &FsWeapon::agm65s : &FsWeapon::agm65;
        case FSWEAPON_BOMB: return &FsWeapon::bomb;
        case FSWEAPON_BOMB250: return &FsWeapon::bomb250;
        case FSWEAPON_BOMB500HD: return jett ? &FsWeapon::bomb500hds : &FsWeapon::bomb500hd;
        case FSWEAPON_ROCKET: return jett ? &FsWeapon::rockets : &FsWeapon::rocket;
        case FSWEAPON_FUELTANK: return &FsWeapon::fuelTank;
        case FSWEAPON_FLAREPOD: return &FsWeapon::flarePod;
        default: return nullptr;
    }
}

} // namespace

VisualSync::~VisualSync() {
    delete generic_cockpit;
}

void VisualSync::attach(Node3D *airplanes, Node3D *grounds, Node3D *weapons) {
    airplanes_root = airplanes;
    grounds_root = grounds;
    weapons_root = weapons;
    airplane_visuals.clear();
    ground_visuals.clear();
    weapon_visuals.clear();
    weapon_pool.clear();
    cockpit_visuals.clear();
    burner_meshes.clear(); // keyed by shell address, like the scene's ShellMeshCache
    shaded_models.clear();
    cockpit_key_valid = false;
    prewarm_node = nullptr; // freed with its parent
    prewarm_frames_left = 0;
}

VisualSync::EntityVisual VisualSync::create_visual(FsVisualDnm &vis, const String &name, Node3D *parent, VisualKind kind) {
    auto dnm = vis.GetDnmPtr();
    EntityVisual ev;
    ev.dnm_ptr = static_cast<const void *>(dnm.get());
    ev.root_node = memnew(Node3D);
    ev.root_node->set_name(name);
    parent->add_child(ev.root_node);

    auto node_array = dnm->GetNodePointerAll();
    const int num_nodes = (int)node_array.GetN();
    ev.dnm_nodes.resize(num_nodes, nullptr);
    ev.node_visible.assign(num_nodes, -1);
    ev.node_tfm.resize(num_nodes);
    ev.node_has_tfm.assign(num_nodes, 0);
    std::unordered_map<const void *, Node3D *> ptr_to_gnode;
    // Baked shading, once per model type (its meshes are then cached).
    ModelShade shade;
    if (kind != VisualKind::PLAIN && shaded_models.insert(ev.dnm_ptr).second) {
        shade = bake_dnm_shade(vis, kind == VisualKind::AIRCRAFT ? ShadeKind::AIRCRAFT : ShadeKind::GROUND);
    }
    for (int i = 0; i < num_nodes; ++i) {
        auto *dnm_node = node_array[i];
        MeshInstance3D *mi = memnew(MeshInstance3D);
        if (dnm_node != nullptr) {
            mi->set_name(dnm_node->nodeName.Strlen() > 0 ? String(dnm_node->nodeName.Txt()) : "DnmNode_" + String::num_int64(i));
            Ref<ArrayMesh> mesh;
            if (kind == VisualKind::AIRCRAFT && dnm_node->dnmClassType == DNM_CLASS_AFTERBURNER) {
                const BurnerMeshCache::Meshes &burner = burner_meshes.get(*dnm_node);
                mesh = burner.flame;
                if (mesh.is_valid()) {
                    burner_seed = std::fmod(burner_seed + 0.618034f, 1.0f);
                    mi->set_instance_shader_parameter("seed", burner_seed);
                    mi->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
                    MeshInstance3D *haze = memnew(MeshInstance3D); // shown/hidden with its parent
                    haze->set_name("HeatHaze");
                    haze->set_mesh(burner.haze);
                    haze->set_layer_mask(1u << (HEAT_HAZE_LAYER - 1));
                    haze->set_visibility_range_end(HEAT_HAZE_RANGE_M);
                    haze->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
                    haze->set_instance_shader_parameter("seed", burner_seed);
                    mi->add_child(haze);
                }
            }
            if (mesh.is_null()) {
                auto s = shade.find(static_cast<const void *>(dnm_node));
                mesh = mesh_cache.get(*dnm_node, s != shade.end() ? &s->second : nullptr);
            }
            if (mesh.is_valid() && mesh->get_surface_count() > 0) {
                mi->set_mesh(mesh);
            }
            ptr_to_gnode[static_cast<const void *>(dnm_node)] = mi;
        }
        ev.dnm_nodes[i] = mi;
    }
    // Parent like the DNM tree
    for (int i = 0; i < num_nodes; ++i) {
        auto *dnm_node = node_array[i];
        Node3D *parent_node = ev.root_node;
        if (dnm_node != nullptr && dnm_node->parent != nullptr) {
            auto pit = ptr_to_gnode.find(static_cast<const void *>(dnm_node->parent));
            if (pit != ptr_to_gnode.end() && pit->second != nullptr) {
                parent_node = pit->second;
            }
        }
        parent_node->add_child(ev.dnm_nodes[i]);
    }
    return ev;
}

// One visual per sim object, rebuilt only if the object's DNM model changes.
VisualSync::EntityVisual *VisualSync::get_or_create(VisualTable &table, unsigned int key, FsVisualDnm &vis, Node3D *parent,
                                                    const char *prefix, VisualKind kind) {
    const void *raw_dnm = static_cast<const void *>(vis.GetDnmPtr().get());
    auto it = table.find(key);
    if (it != table.end() && it->second.dnm_ptr != raw_dnm) {
        if (it->second.root_node != nullptr) {
            it->second.root_node->queue_free();
        }
        table.erase(it);
        it = table.end();
    }
    if (it == table.end()) {
        it = table.emplace(key, create_visual(vis, String(prefix) + "_" + String::num_int64(key), parent, kind)).first;
    }
    return &it->second;
}

void VisualSync::forget_airplane(unsigned int key) {
    for (VisualTable *table : {&airplane_visuals, &cockpit_visuals}) {
        auto it = table->find(key);
        if (it != table->end()) {
            if (it->second.root_node != nullptr) {
                it->second.root_node->queue_free();
            }
            table->erase(it);
        }
    }
    if (cockpit_key_valid && cockpit_key == key) {
        cockpit_key_valid = false;
    }
}

void VisualSync::set_root_visible(EntityVisual &ev, bool visible) {
    if (ev.root_visible != (int8_t)visible) {
        ev.root_node->set_visible(visible);
        ev.root_visible = (int8_t)visible;
    }
}

// Pushes position/attitude and animated DNM part states, skipping anything unchanged since last frame.
void VisualSync::update_visual(EntityVisual &ev, FsVisualDnm &vis, const Transform3D &root_tfm, bool is_alive, bool is_static_prop) {
    set_root_visible(ev, is_alive);
    if (!is_alive) {
        return;
    }
    auto dnm = vis.GetDnmPtr();
    auto node_array = dnm->GetNodePointerAll();
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
    dnm->CacheTransformation(dnm_state);

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
}

void VisualSync::update_hardpoints(EntityVisual &ev, FsAirplane *air) {
    const int num_slots = air->Prop().GetNumWeaponSlots();
    if (num_slots > 0 && (int)ev.hardpoint_nodes.size() != num_slots) {
        for (Node3D *old_hp : ev.hardpoint_nodes) {
            if (old_hp != nullptr) {
                old_hp->queue_free();
            }
        }
        ev.hardpoint_nodes.assign(num_slots, nullptr);
        for (int s = 0; s < num_slots; ++s) {
            FsVisualDnm *slot_vis = static_weapon_visual(air, air->Prop().GetWeaponSlotType(s));
            MeshInstance3D *hp = memnew(MeshInstance3D);
            hp->set_name("Hardpoint_" + String::num_int64(s));
            hp->set_position(ys_to_godot_pos(air->Prop().GetWeaponSlotPos(s)));
            if (slot_vis != nullptr && slot_vis->GetDnmPtr() != nullptr) {
                auto slot_nodes = slot_vis->GetDnmPtr()->GetNodePointerAll();
                if (slot_nodes.GetN() > 0 && slot_nodes[0] != nullptr) {
                    Ref<ArrayMesh> mesh = mesh_cache.get(*slot_nodes[0]);
                    if (mesh.is_valid() && mesh->get_surface_count() > 0) {
                        hp->set_mesh(mesh);
                    }
                }
            }
            ev.root_node->add_child(hp);
            ev.hardpoint_nodes[s] = hp;
        }
    }
    for (int s = 0; s < num_slots && s < (int)ev.hardpoint_nodes.size(); ++s) {
        Node3D *hp = ev.hardpoint_nodes[s];
        const bool visible = (air->Prop().IsWeaponSlotCurrentlyVisible(s) == YSTRUE);
        if (hp != nullptr && hp->is_visible() != visible) {
            hp->set_visible(visible);
        }
    }
}

void VisualSync::sync_airplanes(FsSimulation *sim, const MotionInterp &interp) {
    FsAirplane *player = sim->GetPlayerAirplane();
    int count = 0;
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        ++count;
        // Dead (FSDEAD: hit the ground or destroyed outright) = removed; the crash site / explosion take over.
        // Shot-down jets spinning down are still "alive" in YS and stay visible until impact.
        const bool alive = (air->IsAlive() == YSTRUE);
        if (alive && air->vis != nullptr) {
            air->Prop().SetupVisual(air->vis);
        }
        if (air->vis.GetDnmPtr() == nullptr) {
            continue;
        }
        EntityVisual *ev = get_or_create(airplane_visuals, air->SearchKey(), air->vis, airplanes_root, "Airplane", VisualKind::AIRCRAFT);
        update_visual(*ev, air->vis, interp.air(air), alive, false);
        if (alive) {
            update_hardpoints(*ev, air);
        }
    }
    g_crash_stats.airplanes = count;

    // Cockpit view: back-face culled materials on the player's own aircraft only (follows player changes).
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
}

// Cockpit shell (F1, player only). Like YSFlight, drawn IN ADDITION to the exterior model at the same
// interpolated transform. Aircraft without a cockpit model use YS's generic aircraft/cockpit1.srf.
void VisualSync::sync_cockpit(FsSimulation *sim, const MotionInterp &interp) {
    FsAirplane *player = sim->GetPlayerAirplane();
    FsVisualDnm *cockpit_vis = nullptr;
    if (cockpit_mode && player != nullptr && player->IsAlive() == YSTRUE) {
        if (player->cockpit != nullptr) {
            cockpit_vis = &player->cockpit;
        } else {
            if (generic_cockpit == nullptr) {
                generic_cockpit = new FsVisualDnm;
                if (generic_cockpit->Load(L"aircraft/cockpit1.srf") != YSOK) {
                    log_line("Cockpit: aircraft/cockpit1.srf could not be loaded");
                }
            }
            if (*generic_cockpit != nullptr) {
                cockpit_vis = generic_cockpit;
            }
        }
    }
    const unsigned int key = (cockpit_vis != nullptr) ? player->SearchKey() : 0xFFFFFFFFu;
    for (auto &kv : cockpit_visuals) {
        if (kv.first != key) {
            set_root_visible(kv.second, false);
        }
    }
    if (cockpit_vis != nullptr && cockpit_vis->GetDnmPtr() != nullptr) {
        EntityVisual *cev = get_or_create(cockpit_visuals, key, *cockpit_vis, airplanes_root, "Cockpit");
        update_visual(*cev, *cockpit_vis, interp.air(player), true, false);
    }
}

// Recomputing a ground object's animated DNM parts is YS-side work (~15 us each), so distant ones are
// time-sliced; the phase is spread by key so the work is even across frames. A change of alive state
// (destroyed) is always applied immediately.
void VisualSync::sync_grounds(FsSimulation *sim, const MotionInterp &interp, const YsVec3 &camera_pos) {
    const double ctime = sim->CurrentTime();
    FsAirplane *player = sim->GetPlayerAirplane();
    const YsVec3 view_pos = player != nullptr ? player->GetPosition() : YsOrigin();
    ++ground_frame_index;
    FsGround *gnd = nullptr;
    while ((gnd = sim->FindNextGround(gnd)) != nullptr) {
        const bool alive = (gnd->IsAlive() == YSTRUE);
        const bool is_static_prop = (gnd->Prop().IsNonGameObject() == YSTRUE);
        const unsigned int key = gnd->SearchKey();
        auto existing = ground_visuals.find(key);
        const bool known = existing != ground_visuals.end();
        const bool settled = known && existing->second.static_settled;
        if (known && !settled && existing->second.has_root_tfm && existing->second.root_visible == (int8_t)alive) {
            const double dist = (gnd->GetPosition() - camera_pos).GetLength();
            const uint32_t interval = dist < 2500.0 ? 1u : (dist < 8000.0 ? 4u : 16u);
            if (interval > 1u && ((key + ground_frame_index) % interval) != 0u) {
                continue;
            }
        }
        if (alive && gnd->vis != nullptr && (!is_static_prop || !known)) {
            gnd->Prop().SetupVisual(gnd->vis, view_pos, ctime);
        }
        if (gnd->vis.GetDnmPtr() == nullptr) {
            continue;
        }
        EntityVisual *ev = get_or_create(ground_visuals, key, gnd->vis, grounds_root, "Ground", VisualKind::GROUND);
        if (!settled) {
            ++perf.gnd_full_updates;
        }
        update_visual(*ev, gnd->vis, interp.gnd(gnd), alive, is_static_prop);
    }
}

void VisualSync::sync_weapons(FsSimulation *sim, const MotionInterp &interp) {
    auto release = [&](EntityVisual &ev) {
        set_root_visible(ev, false);
        weapon_pool[ev.dnm_ptr].push_back(std::move(ev));
    };
    const FsWeapon *base = sim->GetWeaponStore().buf;
    seen_slots.clear();
    int count = 0;
    const FsWeapon *wpn = nullptr;
    while ((wpn = sim->FindNextActiveWeapon(wpn)) != nullptr) {
        ++count;
        if (wpn->lifeRemain <= 0.0) {
            continue; // impacted; only its smoke trail remains while timeRemain > 0
        }
        FsVisualDnm *vis = flying_weapon_visual(wpn);
        if (vis == nullptr || vis->GetDnmPtr() == nullptr) {
            continue;
        }
        const void *raw_dnm = static_cast<const void *>(vis->GetDnmPtr().get());
        const unsigned int slot = (unsigned int)(wpn - base);
        auto it = weapon_visuals.find(slot);
        if (it != weapon_visuals.end() && it->second.dnm_ptr != raw_dnm) {
            release(it->second);
            weapon_visuals.erase(it);
            it = weapon_visuals.end();
        }
        if (it == weapon_visuals.end()) {
            auto pool_it = weapon_pool.find(raw_dnm);
            if (pool_it != weapon_pool.end() && !pool_it->second.empty()) {
                it = weapon_visuals.emplace(slot, std::move(pool_it->second.back())).first;
                pool_it->second.pop_back();
            } else {
                it = weapon_visuals.emplace(slot, create_visual(*vis, "Weapon_" + String::num_int64(slot), weapons_root)).first;
            }
        }
        seen_slots.push_back(slot);
        update_visual(it->second, *vis, interp.wpn(wpn), true, false);
    }
    g_crash_stats.weapons = count;

    // Return visuals of weapons that stopped flying to the pool.
    if (seen_slots.size() != weapon_visuals.size()) {
        std::sort(seen_slots.begin(), seen_slots.end());
        for (auto it = weapon_visuals.begin(); it != weapon_visuals.end();) {
            if (!std::binary_search(seen_slots.begin(), seen_slots.end(), it->first)) {
                release(it->second);
                it = weapon_visuals.erase(it);
            } else {
                ++it;
            }
        }
    }
}

void VisualSync::sync(FsSimulation *sim, const MotionInterp &interp, const YsVec3 &camera_pos) {
    if (sim == nullptr || airplanes_root == nullptr) {
        return;
    }
    set_breadcrumb("visual_sync: airplanes");
    const auto t_air = Clock::now();
    sync_airplanes(sim, interp);
    sync_cockpit(sim, interp);
    set_breadcrumb("visual_sync: grounds");
    const auto t_gnd = Clock::now();
    sync_grounds(sim, interp, camera_pos);
    set_breadcrumb("visual_sync: weapons");
    const auto t_wpn = Clock::now();
    sync_weapons(sim, interp);
    const auto t_end = Clock::now();
    perf.air_ms += ms_between(t_air, t_gnd);
    perf.gnd_ms += ms_between(t_gnd, t_wpn);
    perf.wpn_ms += ms_between(t_wpn, t_end);
    ++perf.frames;
    set_breadcrumb("visual_sync: done");
}

VisualSync::Perf VisualSync::take_perf() {
    const Perf out = perf;
    perf = Perf();
    return out;
}

void VisualSync::set_cockpit_mode(bool enabled) {
    // Enabling is applied in sync_airplanes(), which also follows player changes.
    cockpit_mode = enabled;
    if (!enabled && cockpit_key_valid) {
        auto it = airplane_visuals.find(cockpit_key);
        if (it != airplane_visuals.end()) {
            apply_cockpit_materials(it->second, false);
        }
        cockpit_key_valid = false;
    }
}

void VisualSync::apply_cockpit_materials(EntityVisual &ev, bool enabled) {
    for (Node3D *n : ev.dnm_nodes) {
        MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(n);
        if (mi == nullptr || mi->get_mesh().is_null()) {
            continue;
        }
        Ref<Mesh> mesh = mi->get_mesh();
        for (int i = 0; i < mesh->get_surface_count(); ++i) {
            Ref<Material> override_mat;
            if (enabled) {
                Ref<Material> m = mesh->surface_get_material(i);
                if (m.ptr() == mats.lit.ptr()) {
                    override_mat = mats.lit_cockpit;
                } else if (m.ptr() == mats.trans.ptr()) {
                    override_mat = mats.trans_cockpit;
                }
            }
            mi->set_surface_override_material(i, override_mat);
        }
    }
    ev.cockpit_applied = enabled;
}

void VisualSync::build_prewarm(Node3D *parent) {
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
    mesh->surface_set_material(0, mats.lit_cockpit);
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    mesh->surface_set_material(1, mats.trans_cockpit);
    // Flame material, compiled before the first afterburner (same vertex format as burner_mesh.cpp)
    PackedVector2Array uv;
    uv.resize(3);
    Array flame = arrays.duplicate();
    flame[Mesh::ARRAY_COLOR] = Variant();
    flame[Mesh::ARRAY_TEX_UV] = uv;
    flame[Mesh::ARRAY_TEX_UV2] = uv;
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, flame);
    mesh->surface_set_material(2, burner_meshes.material());
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, flame);
    mesh->surface_set_material(3, burner_meshes.haze_material());
    mesh->set_custom_aabb(AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7)));

    prewarm_node = memnew(MeshInstance3D);
    prewarm_node->set_name("CockpitMaterialPrewarm");
    prewarm_node->set_mesh(mesh);
    prewarm_node->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
    parent->add_child(prewarm_node);
    prewarm_frames_left = 30;
}

void VisualSync::step_prewarm() {
    if (prewarm_node != nullptr && --prewarm_frames_left <= 0) {
        prewarm_node->queue_free();
        prewarm_node = nullptr;
    }
}

} // namespace ysgd
