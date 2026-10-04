# Read the player's approach replays (.yfs flight records) and summarise each arrival relative to its runway:
# where the approach really starts, height / speed / bank / G on the way in, when spoilers, gear, flaps and brakes
# come out, touchdown, roll-out, taxi speeds, stops next to supply units (rearm / refuel) and the take-off.
# Usage: python analyze_replays.py <items.json from parse_fld.py> <replay folder> [base_name ILS tag ...]
# Record line (YS fssimulationfileio.cpp): t / x y z h p b g / state vgw spoiler gear flap brake smoke vapor
# flags dmg thr elv ail rud trim thrvec rev bombbay / turrets. Controls are 0..255 (elv/ail/rud signed).
import glob, json, math, os, re, sys

KT = 1.94384
items = json.load(open(sys.argv[1]))
RUNWAYS = {"COLE_29": "COLE_29", "BALUUT_33": "BALUUT_33", "SAKHET_08": "SAKHET_08", "MANTURUUN_09": "MANTURUUN"}
SUPPLY = {"[GOP]SUPPLY_CLASS", "[GOP]ADMIRAL-GORSHKOV", "[GOP]WASP_CLASS", "[GOP]FUELTANK1", "[GOP]FUELTANK2",
          "[GOP]HANGER_WEAPON", "[GOP]SUPPLY_CONTAINER", "[GOP]TRUCK", "[GOP]PORT_CRANE", "[GOP]NIMITZ_CLASS",
          "[GOP]HYUGA_CLASS", "RVB3_SHANDONG"}
supply = [x for x in items if x["kind"] == "GOB" and x["name"] in SUPPLY]

def runway(tag):
    ils = next(x for x in items if x["kind"] == "GOB" and x["tag"] == tag and x["name"] == "[GOP]ILS")
    landing = ((-ils["pos"][3] * 360.0 / 65536.0) + 180.0) % 360.0
    b = math.radians(landing)
    return (ils["pos"][0], ils["pos"][2]), (math.sin(b), math.cos(b)), landing

def read(path):
    lines = open(path, encoding="latin-1").read().splitlines()
    i = next(k for k, l in enumerate(lines) if l.startswith("NUMRECOR"))
    n = int(lines[i].split()[1])
    start = next((l.split()[2] for l in lines[:i] if l.startswith("STARTPOS")), "?")
    craft = next((l.split()[1] for l in lines[:i] if l.startswith("AIRPLANE")), "?")
    recs, k = [], i + 1
    for _ in range(n):
        t = float(lines[k]); p = [float(v) for v in lines[k + 1].split()]; c = [int(v) for v in lines[k + 2].split()]
        nt = int(lines[k + 3].split()[0]); k += 4 + (1 if nt > 0 else 0) * 0
        recs.append(dict(t=t, x=p[0], y=p[1], z=p[2], h=p[3], p=p[4], b=p[5], g=p[6], spoiler=c[2], gear=c[3],
                         flap=c[4], brake=c[5], thr=c[10]))
    for a, b in zip(recs, recs[1:]):
        dt = max(b["t"] - a["t"], 1e-3)
        b["kt"] = math.dist((a["x"], a["y"], a["z"]), (b["x"], b["y"], b["z"])) / dt * KT
    recs[0]["kt"] = recs[1]["kt"] if len(recs) > 1 else 0.0
    return start, craft, recs

def first(recs, cond, after=0.0):
    return next((r for r in recs if r["t"] >= after and cond(r)), None)

for path in sorted(glob.glob(os.path.join(sys.argv[2], "*.yfs"))):
    start, craft, recs = read(path)
    base = next((b for b in RUNWAYS if b in start.replace("-", "_")), None)
    print(f"\n=== {os.path.basename(path)}  ({craft}, start {start}, {len(recs)} samples, {recs[-1]['t']:.0f} s)")
    if base is None:
        print("   no runway match"); continue
    (tx, tz), (ux, uz), landing = runway(RUNWAYS[base])
    for r in recs:
        dx, dz = r["x"] - tx, r["z"] - tz
        r["along"] = dx * ux + dz * uz          # + = past the threshold (down the runway)
        r["cross"] = dx * uz - dz * ux          # + = right of the centre line
        r["dist"] = math.hypot(dx, dz)
    ground = first(recs, lambda r: r["y"] < 4.0 and r["gear"] > 200)
    if ground is None:
        print("   never touched down"); continue
    td = ground
    def at_dist(km):
        r = first(recs, lambda r: r["dist"] < km * 1000.0)
        return f"{km:>3.0f} km: {r['y']:5.0f} m {r['kt']:4.0f} kt bank {abs(math.degrees(r['b'])):3.0f} cross {r['cross']:5.0f} m" if r and r["t"] < td["t"] else f"{km:>3.0f} km: -"
    for km in (10, 7, 5, 3, 2, 1):
        print("   " + at_dist(km))
    air = [r for r in recs if r["t"] < td["t"]]
    print(f"   lowest on the way in: {min(r['y'] for r in air[:max(1, len(air) - 60)]):.0f} m   max G {max(r['g'] for r in air):.1f}")
    for name, key in (("spoilers", "spoiler"), ("gear", "gear"), ("flaps", "flap")):
        r = first(recs, lambda r, k=key: r[k] > 100)
        print(f"   {name:9} out at {r['dist'] / 1000:.1f} km, {r['y']:.0f} m, {r['kt']:.0f} kt" if r and r["t"] <= td["t"] else f"   {name:9} -")
    print(f"   touchdown {td['along']:6.0f} m past the threshold, cross {td['cross']:4.0f} m, {td['kt']:.0f} kt, sink pitch {math.degrees(td['p']):.1f} deg")
    stop = first(recs, lambda r: r["kt"] < 40.0, td["t"])
    if stop:
        print(f"   slowed to 40 kt after {stop['along'] - td['along']:.0f} m, {stop['t'] - td['t']:.0f} s")
    gnd = [r for r in recs if r["t"] > td["t"] and r["y"] < 4.0]
    taxi = [r["kt"] for r in gnd if 5.0 < r["kt"] < 120.0]
    if taxi:
        taxi.sort()
        print(f"   taxi speed median {taxi[len(taxi) // 2]:.0f} kt, top {taxi[int(len(taxi) * 0.95)]:.0f} kt")
    # stops: runs of < 2 kt for > 5 s, with the nearest supply unit
    run = []
    for r in gnd + [dict(kt=99, t=1e9)]:
        if r["kt"] < 2.0:
            run.append(r)
        else:
            if run and run[-1]["t"] - run[0]["t"] > 5.0:
                m = run[len(run) // 2]
                near = min(supply, key=lambda s: math.hypot(s["pos"][0] - m["x"], s["pos"][2] - m["z"]))
                d = math.hypot(near["pos"][0] - m["x"], near["pos"][2] - m["z"])
                print(f"   stop {run[-1]['t'] - run[0]['t']:4.0f} s at ({m['x']:.0f}, {m['z']:.0f}), nearest supply {near['name']} {d:.0f} m")
            run = []
    lift = first(recs, lambda r: r["y"] > 10.0, td["t"] + 20.0)
    if lift:
        roll = first(reversed([r for r in recs if r["t"] < lift["t"]]), lambda r: r["kt"] < 30.0)
        print(f"   take-off: lift-off {lift['kt']:.0f} kt, heading {(-math.degrees(lift['h'])) % 360:.0f}, roll from 30 kt {lift['t'] - roll['t']:.0f} s" if roll else f"   take-off at {lift['kt']:.0f} kt")
    else:
        print("   no take-off in this recording")
