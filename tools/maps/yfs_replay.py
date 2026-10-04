# Read a YSFlight flight record (.yfs) of the player's aircraft: header facts and the per-sample records.
# Record (YS fssimulationfileio.cpp, NUMRECOR version 4): t / x y z h p b g / state vgw spoiler gear flap brake
# smoke vapor flags dmg thr elv ail rud trim thrvec rev bombbay / turret line. Controls are 0..255, thr 0..99;
# flags bit 0 = afterburner, bit 3 = on the ground off the pavement (YS runway regions).
# YS axes: x east, z north, y up; heading h in radians, compass bearing = -h.
import math

KT = 1.94384


def read(path):
    """Returns dict(start, craft, rearm_t, recs). recs: t x y z h p b g spoiler gear flap brake thr ab offpave, plus
    ms (3D speed from neighbouring samples) and kt."""
    lines = open(path, encoding="latin-1").read().splitlines()
    i = next(k for k, l in enumerate(lines) if l.startswith("NUMRECOR"))
    n = int(lines[i].split()[1])
    head = lines[:i]
    start = next((l.split()[2] for l in head if l.startswith("STARTPOS")), "?")
    craft = next((l.split(None, 1)[1].rsplit(" ", 1)[0] for l in head if l.startswith("AIRPLANE")), "?")
    # Weapon reloads are WPNCFG events (the first one is the initial load at t=0 or the spawn time)
    rearm = [float(l.split()[1]) for l in head if l.startswith("WPNCFG")]
    recs, k = [], i + 1
    for _ in range(n):
        t = float(lines[k])
        p = [float(v) for v in lines[k + 1].split()]
        c = [int(v) for v in lines[k + 2].split()]
        k += 4
        recs.append(dict(t=t, x=p[0], y=p[1], z=p[2], h=p[3], p=p[4], b=p[5], g=p[6], spoiler=c[2], gear=c[3],
                         flap=c[4], brake=c[5], thr=c[10], ab=c[8] & 1, offpave=(c[8] >> 3) & 1))
    for a, b in zip(recs, recs[1:]):
        dt = max(b["t"] - a["t"], 1e-3)
        b["ms"] = math.dist((a["x"], a["y"], a["z"]), (b["x"], b["y"], b["z"])) / dt
    recs[0]["ms"] = recs[1]["ms"] if len(recs) > 1 else 0.0
    # Smooth the speed over +-2 samples (positions are rounded to cm, samples ~15 Hz)
    ms = [r["ms"] for r in recs]
    for j, r in enumerate(recs):
        w = ms[max(0, j - 2):j + 3]
        r["ms"] = sum(w) / len(w)
        r["kt"] = r["ms"] * KT
    return dict(start=start, craft=craft, rearm_t=rearm, recs=recs)
