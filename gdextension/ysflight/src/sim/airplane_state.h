#ifndef YSGD_AIRPLANE_STATE_H
#define YSGD_AIRPLANE_STATE_H

class FsAirplane;

namespace ysgd {

// YS keeps a shot-down aircraft IsAlive() == true while it spins down (FSDEADSPIN / FSDEADFLATSPIN) and sets
// FSDEAD only at impact; 1 kill in 7 is FSDEAD instantly in the air (explodes, no falling wreck).
bool is_dying(const FsAirplane *air);

// 0 = undamaged, 1 = no damage tolerance left.
float damage_fraction(const FsAirplane *air);

} // namespace ysgd

#endif // YSGD_AIRPLANE_STATE_H
