# Turn the user's arrival replays at one runway into the AI's arrival plan (approach lines, touchdown zone, taxi
# routes to each rearm spot, take-off) - read by ysce/src/autopilot/fsrvbairfieldplan.cpp.
# Not machine learning: the user's runs are measured and averaged (planning/AI_rebuild_plan.md). The AI's safety
# margins (corner speeds, early braking) are applied by the C++ follower, so this file keeps the user's own numbers.
# Usage: python build_arrival_plan.py <items.json from parse_fld.py> <replay folder> <runway tag, e.g. COLE_29>
#        <out .txt> [<out .svg>]
# Replays: the TRAIN_<RUNWAY>_<FINAL|LEFT|RIGHT|BEYOND>_<LOW|HIGH> starts from make_training_stp.py, each flown
# through landing, taxi, rearm (WPNCFG event) and take-off.
import glob, json, math, os, statistics, sys

import draw_airfield
import pavement
import yfs_replay

GATE_M = 7000.0          # approach gate: straight-line distance from the touchdown (user, 2026-10-01)
APPROACH_STEP_M = 100.0  # spacing of approach line points
ROUTE_STEP_M = 4.0       # spacing of taxi route points
ROUTE_SMOOTH = 3         # +- points of moving average on the merged taxi routes (removes the user's wobble)
SAME_ROUTE_M = 20.0      # a track whose mean distance from the others' medoid is larger took another way
EDGE_MARGIN_M = 5.0      # taxi route points are nudged at least this far inside the pavement (the user cuts corners)
CLIMB_POINTS_M = (0.0, 500.0, 1000.0, 2000.0, 3000.0)  # past lift-off


def unit(deg):
    b = math.radians(deg)
    return math.sin(b), math.cos(b)


def runway_from_map(items, tag):
    """The longest pavement rectangle near the ILS and aligned with its landing heading."""
    ils = next(x for x in items if x["kind"] == "GOB" and x["tag"] == tag and x["name"] == "[GOP]ILS")
    landing = ((-ils["pos"][3] * 360.0 / 65536.0) + 180.0) % 360.0
    ux, uz = unit(landing)
    best = None
    for r in items:
        if r["kind"] != "RGN" or r["id"] != 1 or math.hypot(r["pos"][0] - ils["pos"][0], r["pos"][2] - ils["pos"][2]) > 2500:
            continue
        c = draw_airfield.rgn_corners(r)
        e1 = (c[1][0] - c[0][0], c[1][1] - c[0][1])
        e2 = (c[3][0] - c[0][0], c[3][1] - c[0][1])
        long_e, short_e = (e1, e2) if math.hypot(*e1) > math.hypot(*e2) else (e2, e1)
        L = math.hypot(*long_e)
        if abs(long_e[0] * ux + long_e[1] * uz) / L < math.cos(math.radians(5.0)):
            continue
        if best is None or L > best[1]:
            cx = sum(p[0] for p in c) / 4.0
            cz = sum(p[1] for p in c) / 4.0
            best = ((cx, cz), L, math.hypot(*short_e))
    return landing, best


class Frame:
    """Runway frame: along = m past the threshold (pavement start), cross = m right of the centre line."""
    def __init__(self, ox, oz, ux, uz):
        self.ox, self.oz, self.ux, self.uz = ox, oz, ux, uz

    def to(self, x, z):
        dx, dz = x - self.ox, z - self.oz
        return dx * self.ux + dz * self.uz, dx * self.uz - dz * self.ux

    def back(self, al, cr):
        return self.ox + al * self.ux + cr * self.uz, self.oz + al * self.uz - cr * self.ux


def fit_centre_line(frame, recs_list):
    """Re-anchor the runway on the user's fast ground runs (roll-outs and take-off rolls): mean cross offset and
    the angle of the best-fit line in the map rectangle's frame."""
    pts = []
    for recs in recs_list:
        for r in recs:
            if r["ground"] and r["kt"] > 80.0:
                al, cr = frame.to(r["x"], r["z"])
                if 0.0 < al < 1500.0 and abs(cr) < 20.0:
                    pts.append((al, cr))
    n = len(pts)
    ma = sum(p[0] for p in pts) / n
    mc = sum(p[1] for p in pts) / n
    slope = sum((a - ma) * (c - mc) for a, c in pts) / sum((a - ma) ** 2 for a, _ in pts)
    return mc - slope * ma, math.degrees(math.atan(slope)), n


def resample(pts, step):
    """Polyline [(x, z, ...)] -> points every `step` m along it; extra fields are linearly interpolated."""
    out = [pts[0]]
    carry = 0.0
    for a, b in zip(pts, pts[1:]):
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        d = step - carry
        while d <= seg:
            t = d / seg
            out.append(tuple(a[k] + (b[k] - a[k]) * t for k in range(len(a))))
            d += step
        carry = seg - (d - step)
    if math.hypot(out[-1][0] - pts[-1][0], out[-1][1] - pts[-1][1]) > step * 0.3:
        out.append(pts[-1])
    return out


def path_len(pts):
    return sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:]))


def at_fraction(pts, cum, f):
    """Point at fraction f of the polyline length (cum = cumulative lengths)."""
    s = f * cum[-1]
    lo, hi = 0, len(cum) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if cum[mid] <= s:
            lo = mid
        else:
            hi = mid
    t = 0.0 if cum[hi] == cum[lo] else (s - cum[lo]) / (cum[hi] - cum[lo])
    return tuple(pts[lo][k] + (pts[hi][k] - pts[lo][k]) * t for k in range(len(pts[0])))


def cumulative(pts):
    cum = [0.0]
    for a, b in zip(pts, pts[1:]):
        cum.append(cum[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    return cum


def mean_nearest(a, b):
    """Mean distance from each point of a to the nearest point of b."""
    return sum(min(math.hypot(p[0] - q[0], p[1] - q[1]) for q in b) for p in a) / len(a)


def merge_routes(tracks):
    """Average several taxi tracks [(x, z, kt)] that follow the same way: the medoid track is the reference; each
    reference point moves to the mean of the other tracks' nearest points (searched forward only, so loops and
    turnarounds keep their order); repeated twice, then smoothed. Speed = median of the tracks' speeds there."""
    thin = [resample(t, ROUTE_STEP_M * 3) for t in tracks]
    if len(tracks) > 2:
        score = [sum(mean_nearest(thin[i], thin[j]) for j in range(len(thin)) if j != i) for i in range(len(thin))]
        med = min(range(len(thin)), key=lambda i: score[i])
        keep = [i for i in range(len(thin)) if i == med or mean_nearest(thin[i], thin[med]) < SAME_ROUTE_M]
    else:
        med, keep = 0, list(range(len(thin)))
    tr = [resample(tracks[i], ROUTE_STEP_M) for i in keep]
    ref = resample(tracks[med], ROUTE_STEP_M)
    window = 40
    for _ in range(2):
        idx = [0] * len(tr)
        new = []
        for p in ref:
            xs, zs, vs = [], [], []
            for k, t in enumerate(tr):
                lo = idx[k]
                j = min(range(lo, min(len(t), lo + window)), key=lambda j: math.hypot(t[j][0] - p[0], t[j][1] - p[1]))
                idx[k] = j
                xs.append(t[j][0]); zs.append(t[j][1]); vs.append(t[j][2])
            new.append((sum(xs) / len(xs), sum(zs) / len(zs), statistics.median(vs)))
        ref = resample(new, ROUTE_STEP_M)
    return smooth(ref), keep


def smooth(pts):
    sm = []
    for i in range(len(pts)):
        w = pts[max(0, i - ROUTE_SMOOTH):i + ROUTE_SMOOTH + 1]
        sm.append((sum(p[0] for p in w) / len(w), sum(p[1] for p in w) / len(w)) + tuple(pts[i][2:]))
    sm[0], sm[-1] = pts[0], pts[-1]  # keep the exact start / stop spot
    return sm


def onto_pavement(pave, route, name):
    """Nudge the merged route away from the pavement edges. The nudges are smoothed along the route (so the line
    bends gently instead of getting kinks) and repeated; a last unsmoothed pass guarantees the margin."""
    moved = 0
    for _ in range(6):
        nudged, n = pave.keep_inside(route, EDGE_MARGIN_M)
        moved += n
        if n == 0:
            break
        d = [(b[0] - a[0], b[1] - a[1]) for a, b in zip(route, nudged)]
        k = ROUTE_SMOOTH * 2
        ds = []
        for i in range(len(d)):
            w = d[max(0, i - k):i + k + 1]
            # strongest nudge in the window, eased: keeps the full push at the worst point
            big = max(w, key=lambda v: v[0] * v[0] + v[1] * v[1])
            ds.append(big)
        route = [(p[0] + v[0], p[1] + v[1]) + tuple(p[2:]) for p, v in zip(route, ds)]
        route = smooth(route)
    route, n = pave.keep_inside(route, EDGE_MARGIN_M)
    moved += n
    margins = [pave.margin(p[0], p[1], EDGE_MARGIN_M) for p in route]
    worst = min(range(len(route)), key=lambda i: margins[i])
    print(f"    {name}: {moved} point moves, smallest margin to the pavement edge now {margins[worst]:.1f} m"
          f" (point {worst} of {len(route)})")
    return route


def analyse(path, frame, supply):
    d = yfs_replay.read(path)
    R = d["recs"]
    name = d["start"]
    stay = [r for r in R if r["gear"] > 200 and r["kt"] < 20.0]
    ground_y = statistics.median(r["y"] for r in stay) if stay else 2.0
    for r in R:
        r["ground"] = r["gear"] > 200 and r["y"] < ground_y + 0.3
        r["al"], r["cr"] = frame.to(r["x"], r["z"])
    # touchdown: first sample on the ground after descending (YS rests the aircraft at ground_y)
    i_td = next(i for i, r in enumerate(R) if r["ground"] and i > 0 and r["t"] > 5.0)
    td = R[i_td]
    # the weapon load after touchdown made while standing still (a run can log more than one load event)
    def speed_at(t):
        return min(R, key=lambda r: abs(r["t"] - t))["kt"]
    rearm_t = min((t for t in d["rearm_t"] if t > td["t"]), key=speed_at, default=None)
    i_stop0 = max(i for i in range(i_td, len(R)) if R[i]["t"] <= rearm_t and R[i]["kt"] > 1.0) + 1
    i_stop1 = next(i for i in range(i_stop0, len(R)) if R[i]["t"] > rearm_t and R[i]["kt"] > 1.0) - 1
    stop = R[i_stop0]
    near = min(supply, key=lambda s: math.hypot(s["pos"][0] - stop["x"], s["pos"][2] - stop["z"]))
    i_lift = next(i for i in range(i_stop1, len(R)) if R[i]["y"] > ground_y + 3.0)
    # take-off roll start: lined up on the centre line, slow, before the lift-off
    i_roll = next(i for i in range(i_stop1, i_lift) if abs(R[i]["cr"]) < 8.0 and
                  abs(((-math.degrees(R[i]["h"]) - frame.landing + 180.0) % 360.0) - 180.0) < 8.0)
    i_rot = next((i for i in range(i_roll, i_lift) if math.degrees(R[i]["p"]) > R[i_roll]["p"] * 57.3 + 2.0), i_lift)
    return dict(name=name, craft=d["craft"], recs=R, ground_y=ground_y, td=td, i_td=i_td, i_stop0=i_stop0,
                i_stop1=i_stop1, stop=stop, supply=near, i_lift=i_lift, i_roll=i_roll, i_rot=i_rot,
                stop_s=R[i_stop1]["t"] - R[i_stop0]["t"])


def approach_line(a):
    """The replay from the 7 km gate to the touchdown as [(x, z, y, kt, gear, flap, spoiler)] by arc length."""
    R = a["recs"]
    td = a["td"]
    i_gate = max(i for i in range(a["i_td"]) if math.hypot(R[i]["x"] - td["x"], R[i]["z"] - td["z"]) >= GATE_M)
    return [(r["x"], r["z"], r["y"], r["kt"], r["gear"] > 128, r["flap"] > 128, r["spoiler"] > 128)
            for r in R[i_gate:a["i_td"] + 1]]


def merge_approach(lines):
    """One horizontal line per direction (LOW and HIGH averaged by fraction of their length); heights, speeds and
    config per level at each point. Returns points every APPROACH_STEP_M from the gate."""
    cums = [cumulative(l) for l in lines]
    L = statistics.mean(c[-1] for c in cums)
    n = max(2, int(L / APPROACH_STEP_M) + 1)
    out = []
    for k in range(n):
        f = k / (n - 1)
        ps = [at_fraction(l, c, f) for l, c in zip(lines, cums)]
        out.append(dict(x=sum(p[0] for p in ps) / len(ps), z=sum(p[1] for p in ps) / len(ps), lv=ps))
    return out


def main():
    items = json.load(open(sys.argv[1]))
    folder, tag, out_txt = sys.argv[2], sys.argv[3], sys.argv[4]
    out_svg = sys.argv[5] if len(sys.argv) > 5 else ""
    landing, (rc, rlen, rwid) = runway_from_map(items, tag)
    ux, uz = unit(landing)
    thr = (rc[0] - ux * rlen / 2.0, rc[1] - uz * rlen / 2.0)  # pavement start on the map rectangle's axis
    frame = Frame(thr[0], thr[1], ux, uz)
    frame.landing = landing
    supply = [x for x in items if x["kind"] == "GOB" and any(k in x["name"] for k in ("SUPPLY", "TRUCK", "FUELTANK"))]

    paths = sorted(glob.glob(os.path.join(folder, f"TRAIN_{tag}_*.yfs")))
    runs = [analyse(p, frame, supply) for p in paths]
    # Re-anchor: the user's own centre line through the roll-outs and take-off rolls
    off, ang, n_fit = fit_centre_line(frame, [a["recs"] for a in runs])
    landing += ang  # cross (to the right) grows with along: the user's line is turned clockwise by ang
    ux, uz = unit(landing)
    thr = frame.back(0.0, off)
    frame = Frame(thr[0], thr[1], ux, uz)
    frame.landing = landing
    runs = [analyse(p, frame, supply) for p in paths]

    print(f"{tag}: map runway {rlen:.0f} x {rwid:.0f} m; user centre line {off:+.1f} m right of the map axis, "
          f"{ang:+.2f} deg (from {n_fit} samples); landing heading {landing:.1f}")
    for a in runs:
        td = a["td"]
        print(f"  {a['name']:30} {a['craft']:24} touchdown {td['al']:5.0f} m cross {td['cr']:+5.1f} at {td['kt']:3.0f} kt"
              f" | stop {a['stop_s']:4.1f} s at {a['supply']['name'].replace('[GOP]', '')} | roll from {a['recs'][a['i_roll']]['al']:4.0f} m,"
              f" rotate {a['recs'][a['i_rot']]['kt']:3.0f} kt, lift-off {a['recs'][a['i_lift']]['al']:5.0f} m"
              f" {a['recs'][a['i_lift']]['kt']:3.0f} kt")

    lines = []
    td_al = [a["td"]["al"] for a in runs]
    lines.append(f"# {tag} arrival plan - built by tools/maps/build_arrival_plan.py from {len(runs)} replays; do not edit.")
    lines.append("# Units: metres, m/s, compass degrees. YS axes: x east, z north, y up.")
    lines.append(f"RUNWAY {thr[0]:.2f} {thr[1]:.2f} {landing:.3f} {rlen:.1f} {rwid:.1f}  # pavement start x z, landing heading, length, width")
    lines.append(f"TOUCHDOWN {statistics.median(td_al):.0f} {min(td_al):.0f} {max(td_al):.0f}  # user's touchdowns: median min max m past the pavement start")
    lines.append(f"TOUCHDOWN_SPEED {statistics.median(a['td']['ms'] for a in runs):.1f}")

    # Approach lines per direction
    plan_tracks = []
    for dname in ("FINAL", "LEFT", "RIGHT", "BEYOND"):
        group = {lv: next((a for a in runs if a["name"].endswith(f"_{dname}_{lv}")), None) for lv in ("LOW", "HIGH")}
        if None in group.values():
            continue
        pts = merge_approach([approach_line(group["LOW"]), approach_line(group["HIGH"])])
        lines.append(f"APPROACH {dname} {len(pts)}  # x z | low: y m/s gear flap spoiler | high: y m/s gear flap spoiler")
        for p in pts:
            lo, hi = p["lv"]
            lines.append(f"A {p['x']:.1f} {p['z']:.1f} {lo[2]:.1f} {lo[3] / yfs_replay.KT:.1f} {int(lo[4])} {int(lo[5])} {int(lo[6])}"
                         f" {hi[2]:.1f} {hi[3] / yfs_replay.KT:.1f} {int(hi[4])} {int(hi[5])} {int(hi[6])}")
        plan_tracks.append(([(p["x"], p["z"]) for p in pts], "#ffffff", 3))

    # Taxi routes per rearm spot: in = touchdown -> stop, out = stop -> take-off roll start
    spots = {}
    for a in runs:
        spots.setdefault(a["supply"]["name"] + f"@{a['supply']['pos'][0]:.0f},{a['supply']['pos'][2]:.0f}", []).append(a)
    marks = []
    pave = pavement.Pavement(items, rc, 2500.0)
    for i, (key, group) in enumerate(sorted(spots.items(), key=lambda kv: -len(kv[1]))):
        sname = key.split("@")[0].replace("[GOP]", "") + f"_{i + 1}"
        R_in = [[(r["x"], r["z"], r["ms"]) for r in a["recs"][a["i_td"]:a["i_stop0"] + 1]] for a in group]
        R_out = [[(r["x"], r["z"], r["ms"]) for r in a["recs"][a["i_stop1"]:a["i_roll"] + 1]] for a in group]
        r_in, kept_in = merge_routes(R_in)
        r_out, kept_out = merge_routes(R_out)
        r_in = onto_pavement(pave, r_in, f"{key.split('@')[0]} in")
        r_out = onto_pavement(pave, r_out, f"{key.split('@')[0]} out")
        sx, sz = r_in[-1][0], r_in[-1][1]
        hdg = statistics.median((-math.degrees(a["stop"]["h"])) % 360.0 for a in group)
        sup = group[0]["supply"]
        print(f"  spot {sname}: {len(group)} runs, in-route from {len(kept_in)}, out-route from {len(kept_out)}; "
              f"stop {math.hypot(sup['pos'][0] - sx, sup['pos'][2] - sz):.0f} m from the {sup['name'].replace('[GOP]', '')}")
        lines.append(f"REARM {sname} {sx:.1f} {sz:.1f} {hdg:.1f} {sup['pos'][0]:.1f} {sup['pos'][2]:.1f}  # stop x z heading, supply object x z")
        for rname, route in (("IN", r_in), ("OUT", r_out)):
            lines.append(f"ROUTE {sname} {rname} {len(route)}  # x z user m/s")
            lines += [f"R {x:.1f} {z:.1f} {v:.1f}" for x, z, v in route]
            plan_tracks.append(([(x, z) for x, z, _ in route], "#ffd400" if rname == "IN" else "#00e5ff", 2))
        marks.append((sx, sz, "#ffd400", sname))

    # Take-off: roll start on the centre line, rotate and lift-off speeds, climb-out heights / speeds
    roll_al = statistics.median(a["recs"][a["i_roll"]]["al"] for a in runs)
    rot = statistics.median(a["recs"][a["i_rot"]]["ms"] for a in runs)
    lift = statistics.median(a["recs"][a["i_lift"]]["ms"] for a in runs)
    lift_al = statistics.median(a["recs"][a["i_lift"]]["al"] for a in runs)
    pitch = statistics.median(math.degrees(a["recs"][a["i_lift"]]["p"]) for a in runs)
    rx, rz = frame.back(roll_al, 0.0)
    lines.append(f"TAKEOFF {rx:.1f} {rz:.1f} {rot:.1f} {lift:.1f} {pitch:.1f}  # roll start x z (on the centre line), rotate m/s, lift-off m/s, lift-off pitch deg")
    for d in CLIMB_POINTS_M:
        hs, vs, gs, fs = [], [], [], []
        for a in runs:
            R, i0 = a["recs"], a["i_lift"]
            r = next((r for r in R[i0:] if r["al"] >= R[i0]["al"] + d), R[-1])
            hs.append(r["y"] - a["ground_y"]); vs.append(r["ms"]); gs.append(r["gear"] > 128); fs.append(r["flap"] > 128)
        lines.append(f"CLIMB {d:.0f} {statistics.median(hs):.1f} {statistics.median(vs):.1f} {int(sum(gs) * 2 > len(gs))} {int(sum(fs) * 2 > len(fs))}"
                     f"  # m past lift-off, height above the runway, m/s, gear, flaps")
    print(f"  take-off: roll from {roll_al:.0f} m, rotate {rot * yfs_replay.KT:.0f} kt, lift-off {lift * yfs_replay.KT:.0f} kt at {lift_al:.0f} m, pitch {pitch:.1f} deg")
    open(out_txt, "w", newline="\n").write("\n".join(lines) + "\n")
    print("wrote", out_txt)

    if out_svg:
        user = [([(r["x"], r["z"]) for r in a["recs"] if r["ground"]], "#7a1f1f", 1) for a in runs]
        cx, cz = frame.back(rlen / 2.0, 120.0)
        draw_airfield.svg(items, (cx, cz), 900, 420, out_svg, user + plan_tracks, marks,
                          title=f"{tag}: taxi plan (yellow in, cyan out) over the user's tracks (dark red)", px_per_m=1.0)
        a_svg = out_svg.replace(".svg", "_approach.svg")
        user_air = [([(r["x"], r["z"]) for r in a["recs"][:a["i_td"]]], "#7a1f1f", 1) for a in runs]
        draw_airfield.svg(items, frame.back(-2500.0, 0.0), 8000, 8000, a_svg, user_air + plan_tracks[:4], [],
                          title=f"{tag}: approach lines (white) over the user's runs", px_per_m=0.06)
        print("wrote", out_svg, a_svg)


if __name__ == "__main__":
    main()
