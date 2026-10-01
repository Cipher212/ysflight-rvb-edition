#include "render/trail_renderer.h"

#include <algorithm>
#include <cmath>

#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>

#include "core/ys_convert.h"
#include "core/ys_headers.h"
#include "sim/airplane_state.h"
#include "sim/motion_interp.h"

using namespace godot;

namespace ysgd {

namespace {

// ---- Look of the trails (tune here) -------------------------------------------------------------------------
struct Emission {
    float interval; // seconds between recorded points (medium quality)
    float life, w0, w1, alpha;
};
constexpr double CONTRAIL_ALT_M = 8000.0;
constexpr float DAMAGE_SMOKE_FROM = 0.35f; // damage (0..1) at which a flying aircraft starts to smoke
constexpr Emission VAPOR = {1.0f / 30.0f, 1.0f, 0.175f, 0.175f, 0.9f};  // high-G wingtip lines (YS: 0.5 s; user: 30 % thinner)
constexpr Emission CONTRAIL = {0.2f, 10.0f, 0.4f, 4.0f, 0.55f};         // wingtip lines above CONTRAIL_ALT_M
constexpr Emission MISSILE = {0.1f, 5.0f, 1.0f, 6.0f, 0.75f};           // YS: a point per 0.1 s, 5 s, white, alpha 0.7
constexpr Emission ROCKET = {0.1f, 2.5f, 0.8f, 4.0f, 0.7f};
constexpr Emission FLARE = {0.1f, 2.5f, 0.8f, 4.0f, 0.6f};
constexpr Emission DAMAGE = {0.12f, 4.0f, 2.0f, 10.0f, 0.8f};          // life + 3 s * damage
// Shot down (spinning down): one continuous plume from the smoke point, fire -> charcoal -> grey (the colour ramp
// is in trail_ribbon.gdshader). A point every 1/30 s keeps the ribbon smooth however fast the wreck falls.
constexpr Emission DEATH = {1.0f / 30.0f, 7.0f, 4.5f, 20.0f, 0.92f};
constexpr float DEATH_FADE_FROM = 0.85f; // stays opaque, then fades over the last 15 % of its life
const Color WHITE_LINE(1.0f, 1.0f, 1.0f);
const Color MISSILE_SMOKE(0.93f, 0.93f, 0.93f);
const Color FLARE_SMOKE(1.0f, 0.97f, 0.9f);
constexpr float MISSILE_TAIL_M = 1.8f; // emitter behind the missile's origin (Godot +Z = tail)
constexpr float ROCKET_TAIL_M = 1.0f;
constexpr float MAX_DRAW_DIST_M = 40000.0f;
// ---------------------------------------------------------------------------------------------------------

constexpr int FLOATS_PER_SEGMENT = 20; // transform 12 + colour 4 + custom 4
constexpr int MIN_CAPACITY = 1024;

enum SourceKind : uint64_t { SRC_TIP_R = 1, SRC_TIP_L, SRC_DAMAGE, SRC_DEATH, SRC_WEAPON = 16 };

uint64_t source_key(SourceKind kind, unsigned int id) {
    return ((uint64_t)kind << 32) | (uint64_t)id;
}

bool is_smoking_missile(FSWEAPONTYPE t) {
    return t == FSWEAPON_AIM9 || t == FSWEAPON_AIM9X || t == FSWEAPON_AIM120 || t == FSWEAPON_AGM65;
}

struct DrawPoint {
    Vector3 pos;
    float age, life, w0, w1, alpha;
};

} // namespace

// interval (s), fade_pow, fade_from, min_px, pass, colour ramp
const TrailRenderer::StyleDef TrailRenderer::STYLES[] = {
    {VAPOR.interval, 2.0f, 0.0f, -1.05f, 2, false},             // STYLE_WINGTIP (quadratic fade like YS vapour)
    {MISSILE.interval, 1.3f, 0.0f, 1.5f, 0, false},             // STYLE_MISSILE
    {FLARE.interval, 1.5f, 0.0f, 1.5f, 0, false},               // STYLE_FLARE
    {DAMAGE.interval, 1.5f, 0.0f, 2.0f, 0, false},              // STYLE_DAMAGE
    {DEATH.interval, 1.0f, DEATH_FADE_FROM, 2.0f, 0, true},     // STYLE_DEATH
};

void TrailRenderer::set_quality(int quality) {
    interval_mult = quality <= 0 ? 2.0f : (quality >= 2 ? 0.75f : 1.0f);
}

void TrailRenderer::attach(Node3D *parent) {
    trails.clear();
    free_list.clear();
    active.clear();
    weapon_code.clear();
    weapon_life.clear();
    capacity = 0;
    visible_segments = 0;

    Ref<Shader> shader = ResourceLoader::get_singleton()->load("res://shaders/trail_ribbon.gdshader");
    Ref<ShaderMaterial> material;
    material.instantiate();
    material->set_shader(shader);
    Ref<QuadMesh> quad;
    quad.instantiate();
    quad->set_size(Vector2(1.0f, 1.0f));
    quad->set_material(material);

    multimesh.instantiate();
    multimesh->set_transform_format(MultiMesh::TRANSFORM_3D);
    multimesh->set_use_colors(true);
    multimesh->set_use_custom_data(true);
    multimesh->set_mesh(quad);

    node = memnew(MultiMeshInstance3D);
    node->set_name("Trails");
    node->set_multimesh(multimesh);
    node->set_custom_aabb(AABB(Vector3(-1e7, -1e7, -1e7), Vector3(2e7, 2e7, 2e7)));
    node->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
    parent->add_child(node);
}

int TrailRenderer::acquire_trail(uint64_t source, Style style, Owner owner, unsigned int owner_id, const Vector3 &local_offset,
                                 int max_points) {
    int idx;
    if (!free_list.empty()) {
        idx = free_list.back();
        free_list.pop_back();
    } else {
        idx = (int)trails.size();
        trails.emplace_back();
    }
    Trail &t = trails[idx];
    t.used = true;
    t.style = style;
    t.owner = owner;
    t.owner_id = owner_id;
    t.local_offset = local_offset;
    t.pts.assign((size_t)max_points + 2, Point{});
    t.head = -1;
    t.count = 0;
    t.next_record = -1e30;
    t.emitting = true;
    t.seen = false;
    active[source] = idx;
    return idx;
}

void TrailRenderer::release_trail(int index) {
    Trail &t = trails[index];
    t.pts.clear();
    t.pts.shrink_to_fit();
    t.count = 0;
    t.head = -1;
    t.emitting = false;
    t.used = false;
    free_list.push_back(index);
}

void TrailRenderer::emit(uint64_t source, Style style, Owner owner, unsigned int owner_id, const Vector3 &local_offset,
                         const Color &color, const PointParams &params, const Vector3 &world_pos, double now) {
    auto it = active.find(source);
    int idx;
    // Wingtip lines switch between vapour and contrail spacing; everything else uses its style's spacing
    const bool contrail_spacing = (style == STYLE_WINGTIP && params.life > VAPOR.life);
    const float interval = (contrail_spacing ? CONTRAIL.interval : STYLES[style].interval) * interval_mult;
    if (it == active.end()) {
        float points = params.life / std::max(interval, 0.001f);
        if (style == STYLE_WINGTIP) {
            points = std::max(VAPOR.life / VAPOR.interval, CONTRAIL.life / CONTRAIL.interval) / interval_mult;
        }
        idx = acquire_trail(source, style, owner, owner_id, local_offset, (int)std::ceil(points));
    } else {
        idx = it->second;
    }
    Trail &t = trails[idx];
    t.seen = true;
    t.color = color;
    t.params = params;
    t.local_offset = local_offset;
    if (now < t.next_record) {
        return;
    }
    t.next_record = now + interval - 1e-4;
    const int cap = (int)t.pts.size();
    if (t.count > 0 && t.pts[t.head].pos.distance_squared_to(world_pos) < 0.0025f) {
        return; // not moving (parked, or the same tick twice)
    }
    t.head = (t.head + 1) % cap;
    t.pts[t.head] = Point{world_pos, (float)now, params.life, params.w0, params.w1, params.alpha};
    t.count = std::min(t.count + 1, cap);
}

void TrailRenderer::record_airplanes(FsSimulation *sim, double now) {
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        if (air->IsAlive() != YSTRUE) {
            continue; // wreck on the ground: its trails are left to fade
        }
        const unsigned int key = air->SearchKey();
        const bool dying = is_dying(air);
        const Transform3D raw = ys_to_godot_transform(air->GetPosition(), air->GetAttitude());
        auto &prop = air->Prop();

        const bool vapor = !dying && prop.IsTrailingVapor() == YSTRUE;
        const bool contrail = !dying && air->GetPosition().y() > CONTRAIL_ALT_M;
        if (vapor || contrail) {
            const Emission &e = contrail ? CONTRAIL : VAPOR;
            const PointParams pp{e.life, e.w0, e.w1, e.alpha};
            YsVec3 tip_ys = YsOrigin();
            prop.GetVaporPosition(tip_ys);
            const Vector3 tip_r = ys_to_godot_pos(tip_ys);
            const Vector3 tip_l(-tip_r.x, tip_r.y, tip_r.z);
            emit(source_key(SRC_TIP_R, key), STYLE_WINGTIP, OWNER_AIRPLANE, key, tip_r, WHITE_LINE, pp, raw.xform(tip_r), now);
            emit(source_key(SRC_TIP_L, key), STYLE_WINGTIP, OWNER_AIRPLANE, key, tip_l, WHITE_LINE, pp, raw.xform(tip_l), now);
        }

        // Smoke comes out of the aircraft's smoke generator point (DAT "SMOKEGEN", at the exhaust on RvB jets)
        Vector3 smoke_local;
        if (prop.GetNumSmokeGenerator() > 0) {
            YsVec3 smk;
            prop.GetSmokeGeneratorPosition(smk, 0);
            smoke_local = ys_to_godot_pos(smk);
        }
        const Vector3 smoke_world = raw.xform(smoke_local);

        if (dying) {
            const PointParams pp{DEATH.life, DEATH.w0, DEATH.w1, DEATH.alpha};
            emit(source_key(SRC_DEATH, key), STYLE_DEATH, OWNER_AIRPLANE, key, smoke_local, Color(), pp, smoke_world, now);
            continue;
        }
        const float damage = damage_fraction(air);
        if (damage >= DAMAGE_SMOKE_FROM) {
            const float d = (damage - DAMAGE_SMOKE_FROM) / (1.0f - DAMAGE_SMOKE_FROM);
            const float shade = 0.30f + (0.08f - 0.30f) * d; // dark grey -> near black with damage
            const PointParams pp{DAMAGE.life + 3.0f * damage, DAMAGE.w0, DAMAGE.w1, DAMAGE.alpha};
            emit(source_key(SRC_DAMAGE, key), STYLE_DAMAGE, OWNER_AIRPLANE, key, smoke_local, Color(shade, shade, shade), pp, smoke_world, now);
        }
    }
}

void TrailRenderer::record_weapons(FsSimulation *sim, double now) {
    const FsWeapon *base = sim->GetWeaponStore().buf;
    std::vector<int16_t> cur_code(weapon_code.size(), 0);
    const FsWeapon *w = nullptr;
    while ((w = sim->FindNextActiveWeapon(w)) != nullptr) {
        const unsigned int slot = (unsigned int)(w - base);
        if (slot >= cur_code.size()) {
            cur_code.resize(slot + 1, 0);
        }
        if (slot >= weapon_life.size()) {
            weapon_life.resize(slot + 1, 0.0f);
        }
        const int16_t code = (int16_t)((int)w->type + 1);
        cur_code[slot] = code;
        const uint64_t source = source_key(SRC_WEAPON, slot);
        const int16_t prev = slot < weapon_code.size() ? weapon_code[slot] : 0;
        // lifeRemain only goes down during a flight, so a jump up means the slot was reused within one tick
        const bool reused = prev != code || (float)w->lifeRemain > weapon_life[slot] + 1.0f;
        weapon_life[slot] = (float)w->lifeRemain;
        if (reused) {
            // Another weapon now uses this slot: leave the old trail behind
            auto it = active.find(source);
            if (it != active.end()) {
                trails[it->second].emitting = false;
                active.erase(it);
            }
        }
        if (w->lifeRemain <= 0.0 || w->shouldJettison == YSTRUE) {
            continue; // impacted (trail fades) or a dropped store
        }
        const Emission *e = nullptr;
        Style style = STYLE_MISSILE;
        Color color = MISSILE_SMOKE;
        float tail = 0.0f;
        if (is_smoking_missile(w->type)) {
            e = &MISSILE;
            tail = MISSILE_TAIL_M;
        } else if (w->type == FSWEAPON_ROCKET) {
            e = &ROCKET;
            tail = ROCKET_TAIL_M;
        } else if (w->type == FSWEAPON_FLARE) {
            e = &FLARE;
            style = STYLE_FLARE;
            color = FLARE_SMOKE;
        }
        if (e == nullptr) {
            continue; // bullets, bombs, fuel tanks, debris
        }
        const Transform3D raw = ys_to_godot_transform(w->pos, w->att);
        const Vector3 offset(0.0f, 0.0f, tail);
        emit(source, style, OWNER_WEAPON, slot, offset, color, PointParams{e->life, e->w0, e->w1, e->alpha}, raw.xform(offset), now);
    }
    weapon_code.swap(cur_code);
}

void TrailRenderer::record(FsSimulation *sim) {
    if (sim == nullptr || node == nullptr) {
        return;
    }
    const double now = sim->CurrentTime();
    for (auto &kv : active) {
        trails[kv.second].seen = false;
    }
    record_airplanes(sim, now);
    record_weapons(sim, now);
    // Sources that stopped this tick: their trails stay and fade out
    for (auto it = active.begin(); it != active.end();) {
        Trail &t = trails[it->second];
        if (!t.seen) {
            t.emitting = false;
            it = active.erase(it);
        } else {
            ++it;
        }
    }
}

bool TrailRenderer::emitter_position(FsSimulation *sim, const MotionInterp &interp, const Trail &t, Vector3 &out) const {
    if (t.owner == OWNER_AIRPLANE) {
        FsAirplane *air = sim->FindAirplane((YSHASHKEY)t.owner_id);
        if (air == nullptr) {
            return false;
        }
        out = interp.air(air).xform(t.local_offset);
        return true;
    }
    const FsWeapon *w = sim->GetWeaponStore().buf + t.owner_id;
    if (w->lifeRemain <= 0.0) {
        return false;
    }
    out = interp.wpn(w).xform(t.local_offset);
    return true;
}

int TrailRenderer::death_trail_count() const {
    int n = 0;
    for (const Trail &t : trails) {
        n += (t.used && t.style == STYLE_DEATH) ? 1 : 0;
    }
    return n;
}

void TrailRenderer::ensure_capacity(int segments) {
    if (segments <= capacity) {
        return;
    }
    int cap = std::max(capacity, MIN_CAPACITY);
    while (cap < segments) {
        cap *= 2;
    }
    capacity = cap;
    multimesh->set_instance_count(capacity);
    buffer.resize((int64_t)capacity * FLOATS_PER_SEGMENT);
}

void TrailRenderer::draw(FsSimulation *sim, const MotionInterp &interp, double render_time, const Vector3 &camera_pos) {
    if (sim == nullptr || node == nullptr) {
        return;
    }
    std::vector<DrawPoint> pts;
    pts.reserve(256);
    int written = 0;
    const float max_dist2 = MAX_DRAW_DIST_M * MAX_DRAW_DIST_M;

    for (int pass = 0; pass < 3; ++pass) {
        for (int ti = 0; ti < (int)trails.size(); ++ti) {
            Trail &t = trails[ti];
            if (!t.used) {
                continue;
            }
            const StyleDef &sd = STYLES[t.style];
            if (sd.pass != pass) {
                continue;
            }
            const int cap = (int)t.pts.size();
            // Drop faded points from the old end
            while (t.count > 0) {
                const Point &oldest = t.pts[(t.head - t.count + 1 + cap) % cap];
                if (render_time - oldest.time <= oldest.life) {
                    break;
                }
                --t.count;
            }
            if (t.count == 0 && !t.emitting) {
                release_trail(ti);
                continue;
            }

            pts.clear();
            Vector3 head_pos;
            if (t.emitting && emitter_position(sim, interp, t, head_pos)) {
                pts.push_back(DrawPoint{head_pos, 0.0f, t.params.life, t.params.w0, t.params.w1, t.params.alpha});
            }
            for (int k = 0; k < t.count; ++k) {
                const Point &p = t.pts[(t.head - k + cap) % cap];
                const float age = (float)(render_time - p.time);
                if (age < 0.0f) {
                    continue; // recorded after the moment being drawn (the picture lags the sim by < 1 tick)
                }
                if (age > p.life) {
                    break;
                }
                pts.push_back(DrawPoint{p.pos, age, p.life, p.w0, p.w1, p.alpha});
            }
            const int n = (int)pts.size();
            if (n < 2 || pts[0].pos.distance_squared_to(camera_pos) > max_dist2) {
                continue;
            }

            ensure_capacity(written + n - 1);
            float *buf = buffer.ptrw();
            auto tangent_at = [&](int i) -> Vector3 {
                const Vector3 a = pts[i > 0 ? i - 1 : 0].pos;
                const Vector3 b = pts[i < n - 1 ? i + 1 : n - 1].pos;
                const Vector3 d = a - b;
                const float len = d.length();
                return len > 1e-4f ? d / len : Vector3(0.0f, 0.0f, 1.0f);
            };
            auto width_alpha = [&](const DrawPoint &p, float &w, float &a, float &f) {
                f = std::min(p.age / std::max(p.life, 0.001f), 1.0f);
                const float spread = 1.0f - (1.0f - f) * (1.0f - f);
                w = p.w0 + (p.w1 - p.w0) * spread;
                const float fade = std::max(f - sd.fade_from, 0.0f) / (1.0f - sd.fade_from);
                a = p.alpha * std::pow(1.0f - fade, sd.fade_pow);
            };
            Vector3 t0 = tangent_at(0);
            float w0, a0, f0;
            width_alpha(pts[0], w0, a0, f0);
            for (int i = 0; i < n - 1; ++i) {
                const Vector3 t1 = tangent_at(i + 1);
                float w1, a1, f1;
                width_alpha(pts[i + 1], w1, a1, f1);
                if (a0 > 0.003f || a1 > 0.003f) {
                    const Vector3 &p0 = pts[i].pos;
                    const Vector3 &p1 = pts[i + 1].pos;
                    float *b = buf + (int64_t)written * FLOATS_PER_SEGMENT;
                    // Columns of the instance transform: p0, p1, tangent p0, tangent p1 (see the shader)
                    b[0] = p0.x; b[4] = p0.y; b[8] = p0.z;
                    b[1] = p1.x; b[5] = p1.y; b[9] = p1.z;
                    b[2] = t0.x; b[6] = t0.y; b[10] = t0.z;
                    b[3] = t1.x; b[7] = t1.y; b[11] = t1.z;
                    if (sd.ramp) { // colour from the age along the plume (shader); r < 0 marks it
                        b[12] = -1.0f; b[13] = f0; b[14] = f1;
                    } else {
                        b[12] = t.color.r; b[13] = t.color.g; b[14] = t.color.b;
                    }
                    b[15] = sd.min_px;
                    b[16] = w0; b[17] = w1; b[18] = a0; b[19] = a1;
                    ++written;
                }
                t0 = t1;
                w0 = w1;
                a0 = a1;
                f0 = f1;
            }
        }
    }

    if (written > 0) {
        multimesh->set_buffer(buffer);
    }
    multimesh->set_visible_instance_count(written);
    visible_segments = written;
}

} // namespace ysgd
