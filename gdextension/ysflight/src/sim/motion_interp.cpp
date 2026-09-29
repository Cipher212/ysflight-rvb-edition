#include "sim/motion_interp.h"

#include "core/ys_convert.h"
#include "core/ys_headers.h"

using namespace godot;

namespace ysgd {

namespace {

constexpr double SNAP_DISTANCE_M = 500.0;

void push(MotionInterp::State &st, const Transform3D &t) {
    if (!st.valid || st.cur.origin.distance_squared_to(t.origin) > SNAP_DISTANCE_M * SNAP_DISTANCE_M) {
        st.prev = t;
        st.cur = t;
        st.valid = true;
    } else {
        st.prev = st.cur;
        st.cur = t;
    }
}

Transform3D blend(const MotionInterp::State &st, double a) {
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

} // namespace

void MotionInterp::capture(FsSimulation *sim) {
    if (sim == nullptr) {
        return;
    }
    ++tick_;
    FsAirplane *air = nullptr;
    while ((air = sim->FindNextAirplane(air)) != nullptr) {
        push(air_[air->SearchKey()], ys_to_godot_transform(air->GetPosition(), air->GetAttitude()));
    }
    FsGround *gnd = nullptr;
    while ((gnd = sim->FindNextGround(gnd)) != nullptr) {
        if (gnd->Prop().IsNonGameObject() != YSTRUE) { // static props never move
            push(gnd_[gnd->SearchKey()], ys_to_godot_transform(gnd->GetPosition(), gnd->GetAttitude()));
        }
    }
    wpn_base_ = sim->GetWeaponStore().buf;
    const FsWeapon *w = nullptr;
    while ((w = sim->FindNextActiveWeapon(w)) != nullptr) {
        const size_t slot = (size_t)(w - wpn_base_);
        if (slot >= wpn_.size()) {
            wpn_.resize(slot + 1);
            wpn_code_.resize(slot + 1, 0);
            wpn_stamp_.resize(slot + 1, 0);
        }
        const int16_t code = (int16_t)((int)w->type + 1);
        // A slot that was not active on the previous tick, or now holds another weapon type, is a new weapon
        if (wpn_stamp_[slot] != tick_ - 1 || wpn_code_[slot] != code) {
            wpn_[slot].valid = false;
        }
        wpn_stamp_[slot] = tick_;
        wpn_code_[slot] = code;
        push(wpn_[slot], ys_to_godot_transform(w->pos, w->att));
    }
}

void MotionInterp::reset(FsSimulation *sim) {
    air_.clear();
    gnd_.clear();
    wpn_.clear();
    wpn_code_.clear();
    wpn_stamp_.clear();
    capture(sim);
}

void MotionInterp::begin_frame(double physics_fraction) {
    alpha_ = enabled_ ? YsBound(physics_fraction, 0.0, 1.0) : 1.0;
}

Transform3D MotionInterp::air(const FsAirplane *a) const {
    auto it = air_.find(a->SearchKey());
    if (it != air_.end() && it->second.valid) {
        return blend(it->second, alpha_);
    }
    return ys_to_godot_transform(a->GetPosition(), a->GetAttitude());
}

Transform3D MotionInterp::gnd(const FsGround *g) const {
    auto it = gnd_.find(g->SearchKey());
    if (it != gnd_.end() && it->second.valid) {
        return blend(it->second, alpha_);
    }
    return ys_to_godot_transform(g->GetPosition(), g->GetAttitude());
}

Transform3D MotionInterp::wpn(const FsWeapon *w) const {
    const size_t slot = (size_t)(w - wpn_base_);
    if (wpn_base_ != nullptr && slot < wpn_.size() && wpn_[slot].valid && wpn_stamp_[slot] == tick_) {
        return blend(wpn_[slot], alpha_);
    }
    return ys_to_godot_transform(w->pos, w->att);
}

} // namespace ysgd
