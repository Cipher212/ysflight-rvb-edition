#include "sim/airplane_state.h"

#include "core/ys_headers.h"

namespace ysgd {

bool is_dying(const FsAirplane *air) {
    const FSFLIGHTSTATE s = air->Prop().GetFlightState();
    return s == FSDEADSPIN || s == FSDEADFLATSPIN;
}

float damage_fraction(const FsAirplane *air) {
    const int def_tol = air->GetDefaultDamageTolerance();
    if (def_tol <= 0) {
        return 0.0f;
    }
    return (float)YsBound(1.0 - (double)air->Prop().GetDamageTolerance() / (double)def_tol, 0.0, 1.0);
}

} // namespace ysgd
