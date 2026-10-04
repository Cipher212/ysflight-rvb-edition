"""Arrival test for the new RvB AI: jets start where the user's training replays started, the arrival follower lands
them, taxis to a rearm spot, rearms and takes off again; this script judges each jet.

Usage:  python tools/ai_arrival_test.py [--runway COLE_29] [--entries FINAL_LOW,LEFT_HIGH,...] [--jets N]
                                        [--spacing-km 4] [--aircraft "MIG-27(RED/ATTACKER)"] [--window] [--speed 4]
Default: every entry the plan has replays for (FINAL/LEFT/RIGHT/BEYOND x LOW/HIGH), one jet per run.
--jets N: one run with N jets on the listed entries, each next one --spacing-km further out (traffic test).
--window: a visible window (screenshots of the first jet at each phase); otherwise headless.
Pass/fail per jet: touchdown in the zone (from the pavement start to TOUCHDOWN_ZONE_M past it, near the centre
line), never off the pavement on the ground, stopped at the rearm spot (YS gave fuel/ammo), airborne again.
Multi-jet runs also: never two jets on the runway at once, never closer than MIN_GROUND_GAP_M on the ground.
Output: crashlog/arrival_test/<time>/<run>/ (mission, trace.json, result.json, map .svg/.png, screenshots).
"""
import argparse
import datetime
import json
import math
import os
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
GODOT = os.path.join(ROOT, "engine", "Godot_v4.7.2-stable_win64_console.exe")
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
TRAIN_STP = os.path.join(ROOT, "ysce", "build", "main", "Release", "user", "RvB", "ww3", "Luavi.stp")
sys.path.insert(0, os.path.join(ROOT, "tools", "maps"))
import draw_airfield  # noqa: E402
from arrival_checks import (get_column_map, judge, verify_kill_event, verify_roster, sustained_orbit_keys)

MIN_GROUND_GAP_M = 25.0    # m between two jets on the ground (centre to centre)
# The user's loadout in the Cole replays (MiG-27, loaded attacker)
LOADOUT = ["UNLOADWP", "LOADWEPN IFLR 20", "LOADWEPN AIM9 2", "LOADWEPN B500 4", "LOADWEPN FUEL 800",
           "LOADWEPN FUEL 800"]


def training_starts(runway):
    """TRAIN_<RUNWAY>_<DIR>_<LEVEL> -> (x, y, z, heading deg, speed m/s) from the stock install's Luavi.stp."""
    starts, name = {}, None
    for line in open(TRAIN_STP, encoding="latin-1").read().splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "N":
            name = p[1] if p[1].startswith(f"TRAIN_{runway}_") else None
            if name:
                starts[name] = {}
        elif name and p[0] == "C" and p[1] == "POSITION":
            starts[name]["pos"] = [float(v.rstrip("m")) for v in p[2:5]]
        elif name and p[0] == "C" and p[1] == "ATTITUDE":
            starts[name]["hdg"] = float(p[2].rstrip("deg"))
        elif name and p[0] == "C" and p[1] == "INITSPED":
            starts[name]["speed"] = float(p[2].rstrip("m/s"))
    return starts


def write_mission(path, aircraft, jets):
    """jets: [(x, y, z, ys heading deg, speed)]; the first is the player (the camera follows it)."""
    out = ["YFSVERSI 20141101", 'SIMTITLE "RvB AI arrival test"', "FIELDNAM [RVB]LUAVI 0 0 0 0 0 0 TRUE",
           "ALLOWAAM TRUE", "ALLOWGUN TRUE", "ALLOWAGM TRUE", "ALLOWBOM TRUE", "ALLOWRKT TRUE", ""]
    for i, (x, y, z, h, v) in enumerate(jets):
        out += [f'AIRPLANE "{aircraft}" {"TRUE" if i == 0 else "FALSE"}', "IDENTIFY 0",
                f"AIRPCMND POSITION {x:.1f}m {y:.1f}m {z:.1f}m", f"AIRPCMND ATTITUDE {h:.2f}deg 0.0deg 0.0deg",
                f"AIRPCMND INITSPED {v:.1f}m/s", "AIRPCMND CTLTHROT 0.8", "AIRPCMND CTLLDGEA FALSE"]
        out += [f"AIRPCMND {c}" for c in LOADOUT] + ["AIRPCMND INITFUEL 100%", ""]
    open(path, "w", newline="\r\n").write("\n".join(out))


def traffic(trace, rwy, col):
    """Multi-jet runs: the most jets on the runway at once (rolling, taking off or landing below 30 m),
    closest on ground, and closest in the air."""
    tx, tz, hdg, length = rwy
    ux, uz = math.sin(math.radians(hdg)), math.cos(math.radians(hdg))
    most, closest_gnd, closest_air = 0, 1e9, 1e9
    x_idx = col.get("x", 0)
    y_idx = col.get("y", 1)
    z_idx = col.get("z", 2)
    alive_idx = col["alive"]
    ground_idx = col["ground"]

    for t, sample in trace["samples"]:
        on_rwy, ground, air = 0, [], []
        for s in sample:
            if not s[alive_idx]:
                continue
            sx, sy, sz = s[x_idx], s[y_idx], s[z_idx]
            al = (sx - tx) * ux + (sz - tz) * uz
            cr = (sx - tx) * uz - (sz - tz) * ux
            if -300.0 < al < length + 100.0 and abs(cr) < 20.0 and sy < 30.0:
                on_rwy += 1
            if s[ground_idx]:
                ground.append((sx, sz))
            else:
                air.append((sx, sy, sz))
        most = max(most, on_rwy)
        for i in range(len(ground)):
            for j in range(i + 1, len(ground)):
                closest_gnd = min(closest_gnd, math.dist(ground[i], ground[j]))
        for i in range(len(air)):
            for j in range(i + 1, len(air)):
                d3 = math.sqrt((air[i][0] - air[j][0]) ** 2 + (air[i][1] - air[j][1]) ** 2 + (air[i][2] - air[j][2]) ** 2)
                closest_air = min(closest_air, d3)
    return most, closest_gnd, closest_air


def runway_line(runway):
    rwy = next(l for l in open(os.path.join(ROOT, "godot_project", "ai", runway.lower() + ".txt")) if l.startswith("RUNWAY")).split()
    return float(rwy[1]), float(rwy[2]), float(rwy[3]), float(rwy[4])


def draw(run_dir, items, plan_lines, trace, n_jets, rwy, col):
    cols = ["#ff3030", "#30a0ff", "#ffd400", "#30ff60"]
    ground = [[] for _ in range(n_jets)]
    air = [[] for _ in range(n_jets)]
    x_i = col.get("x", 0)
    z_i = col.get("z", 2)
    g_i = col.get("ground", 5)

    keys = [s[col["search_key"]] for s in trace["samples"][0][1]]
    key_index = {key: i for i, key in enumerate(keys)}
    for t, sample in trace["samples"]:
        for s in sample:
            k = key_index[s[col["search_key"]]]
            (ground if s[g_i] else air)[k].append((s[x_i], s[z_i]))
    plan_tracks = [(pts, "#ffffff", 1, "4,3") for pts in plan_lines]
    tracks = plan_tracks + [(g, cols[k % 4], 2) for k, g in enumerate(ground) if g]
    tx, tz, hdg, length = rwy
    ux, uz = math.sin(math.radians(hdg)), math.cos(math.radians(hdg))
    centre = (tx + ux * length / 2 + uz * 120, tz + uz * length / 2 - ux * 120)
    svg = os.path.join(run_dir, "ground.svg")
    draw_airfield.svg(items, centre, 900, 420, svg, tracks, [], title="AI ground tracks (colour) over the plan (white dashes)", px_per_m=1.0)
    svg2 = os.path.join(run_dir, "approach.svg")
    draw_airfield.svg(items, (tx - ux * 2500, tz - uz * 2500), 8000, 8000, svg2,
                      plan_tracks + [(a, cols[k % 4], 2) for k, a in enumerate(air) if a], [],
                      title="AI flight paths (colour) over the plan (white dashes)", px_per_m=0.06)
    if os.path.exists(EDGE):
        for s, size in ((svg, "1800,840"), (svg2, "960,960")):
            subprocess.run([EDGE, "--headless=new", "--disable-gpu", f"--screenshot={s[:-4]}.png", f"--window-size={size}",
                            "file:///" + s.replace("\\", "/")], capture_output=True, timeout=60)


def plan_polylines(path):
    lines, cur = [], None
    for l in open(path):
        p = l.split()
        if not p:
            continue
        if p[0] in ("APPROACH", "ROUTE"):
            cur = []
            lines.append(cur)
        elif p[0] in ("A", "R") and cur is not None:
            cur.append((float(p[1]), float(p[2])))
        else:
            cur = None
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runway", default="COLE_29")
    ap.add_argument("--entries", default="")
    ap.add_argument("--jets", type=int, default=0)
    ap.add_argument("--spacing-km", type=float, default=4.0)
    ap.add_argument("--aircraft", default="MIG-27(RED/ATTACKER)")
    ap.add_argument("--window", action="store_true")
    ap.add_argument("--speed", type=int, default=4)
    ap.add_argument("--limit", type=float, default=900.0, help="sim seconds per run")
    ap.add_argument("--kill-at-sec", type=float, default=-1.0, help="test hook: kill jet at sim second")
    ap.add_argument("--kill-jet-idx", type=int, default=-1, help="test hook: index of jet to kill")
    ap.add_argument("--kill-approach-at-sec", type=float, default=-1.0, help="test hook: kill jet holding approach clearance at sim second")
    ap.add_argument("--kill-first-waiting", action="store_true", help="test hook: kill first waiting jet in hold")
    ap.add_argument("--kill-approach-holder", action="store_true", help="test hook: kill jet holding approach clearance")
    ap.add_argument("--require-sustained-orbit", type=float, default=0.0, help="assert hold orbit duration >= S and radial error <= 350m")
    a = ap.parse_args()

    starts = training_starts(a.runway)
    names = [f"TRAIN_{a.runway}_{e}" for e in a.entries.split(",")] if a.entries else sorted(starts)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    base = os.path.join(ROOT, "crashlog", "arrival_test", stamp)
    items_path = os.path.join(base, "items.json")
    os.makedirs(base, exist_ok=True)
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "maps", "parse_fld.py"),
                    os.path.join(ROOT, "godot_project", "user", "RvB", "ww3", "Luavi.fld"), items_path], check=True)
    items = json.load(open(items_path))
    plan_lines = plan_polylines(os.path.join(ROOT, "godot_project", "ai", a.runway.lower() + ".txt"))

    runs = []
    if a.jets > 0:
        jets = []
        for k in range(a.jets):
            s = starts[names[k % len(names)]]
            x, y, z = s["pos"]
            # further out along the same bearing from the field
            fx, fz = -math.sin(math.radians(s["hdg"])), math.cos(math.radians(s["hdg"]))  # YS heading -> forward
            back = k * a.spacing_km * 1000.0
            # further out: high enough for the hills (the training starts are 200 m above the first 2 km only)
            jets.append((x - fx * back, max(y, 600.0) if k else y, z - fz * back, s["hdg"], s["speed"]))
        runs.append((f"traffic_{a.jets}", jets))
    else:
        for n in names:
            s = starts[n]
            runs.append((n.replace(f"TRAIN_{a.runway}_", ""), [(*s["pos"], s["hdg"], s["speed"])]))

    all_ok = True
    print(f"{'run':16} {'jet':3} {'line':7} {'td m':>6} {'cross':>6} {'td kt':>6} {'sink':>5} {'offpave s':>9} "
          f"{'spot':20} {'stop err':>8} {'lift kt':>7} {'wait s':>6} {'GA':>3} {'total s':>7}  result")
    for run_name, jets in runs:
        run_dir = os.path.join(base, run_name)
        os.makedirs(run_dir, exist_ok=True)
        mission = os.path.join(run_dir, "mission.yfs")
        write_mission(mission, a.aircraft, jets)
        cmd = [GODOT, "--path", os.path.join(ROOT, "godot_project"), "--audio-driver", "Dummy"]
        if not a.window:
            cmd.append("--headless")
        else:
            cmd += ["--resolution", "1280x720"]
        cmd += ["--", "--mission", mission, "--ai-arrival", a.runway, "--arrival-out", run_dir,
                "--arrival-limit", str(a.limit), "--sim-speed", str(a.speed), "--no-ai-respawn"]
        if a.kill_at_sec >= 0.0:
            cmd += ["--kill-at-sec", str(a.kill_at_sec), "--kill-jet-idx", str(a.kill_jet_idx)]
        if a.kill_approach_at_sec >= 0.0:
            cmd += ["--kill-approach-at-sec", str(a.kill_approach_at_sec)]
        if a.kill_first_waiting:
            cmd += ["--kill-first-waiting"]
        if a.kill_approach_holder:
            cmd += ["--kill-approach-holder"]

        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, errors="replace",
                                  timeout=a.limit / max(1, a.speed) * 4 + 180)
        except subprocess.TimeoutExpired:
            print(f"{run_name:16} FAIL: the run did not finish in time")
            all_ok = False
            continue
        res_path = os.path.join(run_dir, "result.json")
        if not os.path.exists(res_path):
            print(f"{run_name:16} FAIL: no result.json; last output:")
            print("\n".join((proc.stdout + proc.stderr).splitlines()[-25:]))
            all_ok = False
            continue
        res = json.load(open(res_path))
        trace = json.load(open(os.path.join(run_dir, "trace.json")))
        try:
            col = get_column_map(trace)
        except ValueError as error:
            print(f"{run_name:16} FAIL: {error}")
            all_ok = False
            continue
        rwy = runway_line(a.runway)
        roster_ok = verify_roster(res, trace, col, len(jets))
        all_ok = all_ok and roster_ok
        if not roster_ok:
            print(f"{run_name:16} FAIL: incomplete/mismatched aircraft roster or timeout")
        for name, output in (("stdout.txt", proc.stdout), ("stderr.txt", proc.stderr)):
            with open(os.path.join(run_dir, name), "w", encoding="utf-8") as stream:
                stream.write(output)
        with open(os.path.join(run_dir, "run.json"), "w", encoding="utf-8") as stream:
            json.dump({"command": cmd, "exit_code": proc.returncode}, stream, indent=2)
        runtime_ok = proc.returncode == 0 and not any(token in proc.stdout + proc.stderr for token in ("SCRIPT ERROR", "SHADER ERROR"))
        all_ok = all_ok and runtime_ok
        if not runtime_ok:
            print(f"{run_name:16} FAIL: runtime error; see stdout.txt, stderr.txt and run.json")

        kill_active = (a.kill_first_waiting or a.kill_approach_holder or a.kill_at_sec >= 0.0 or a.kill_approach_at_sec >= 0.0)
        ke = res.get("kill_event", None)
        target_key = ke.get("target_key", -1) if ke else -1

        for k, jet in enumerate(res["aircraft"]):
            key = jet.get("search_key", 0)
            r = jet["report"]
            if kill_active and key == target_key:
                print(f"{run_name:16} {k:3} (killed target key={key}) - judged by structured kill verification")
                continue

            checks = judge(jet, trace=trace, col=col, runway=rwy)
            failed = [c for c, v in checks.items() if v is False]
            ok = (len(failed) == 0)
            all_ok = all_ok and ok
            total = r["airborne_time"] if r["airborne"] else res["sim_time"]
            print(f"{run_name:16} {k:3} {jet['line']:7} {r['td_along']:6.0f} {r['td_cross']:6.1f} {r['td_speed'] * 1.94384:6.0f} "
                  f"{r['td_sink']:5.1f} {r['off_pavement_s']:9.1f} {r['rearm_spot']:20} {r['rearm_stop_error']:8.1f} "
                  f"{r['liftoff_speed'] * 1.94384:7.0f} {r['wait_s']:6.0f} {r['go_arounds']:3} {total:7.0f}  "
                  f"{'PASS' if ok else 'FAIL: ' + ', '.join(failed)} {jet['phase']} {r['fail']} {jet.get('died_of', '')}")
            if checks.get("gate fixed") != "N/A":
                print(f"      holding: gates_changed={r.get('gate_changes', 0)} max_dist={r.get('hold_max_dist', 0):.0f}m "
                      f"radial_err_max={r.get('hold_radial_err_max', 0):.0f}m min_agl={r.get('min_terrain_clearance', 0):.0f}m "
                      f"orbit_dur={r.get('hold_orbit_duration', 0):.0f}s est_err_max={r.get('hold_established_radial_err_max', 0):.0f}m")

        if kill_active:
            hook_name = "approach_holder" if (a.kill_approach_holder or a.kill_approach_at_sec >= 0.0) else ("first_waiting" if a.kill_first_waiting else "timed")
            kill_ok, kill_reasons = verify_kill_event(res, hook_name, trace, col)
            all_ok = all_ok and kill_ok
            print(f"{run_name:16} structured kill verification: {'PASS' if kill_ok else 'FAIL: ' + '; '.join(kill_reasons)}")
        if a.require_sustained_orbit > 0.0:
            sustained_jets = sustained_orbit_keys(res, trace, a.require_sustained_orbit, col)
            sustained_ok = bool(sustained_jets)
            all_ok = all_ok and sustained_ok
            print(f"{run_name:16} sustained orbit check (>={a.require_sustained_orbit:.0f}s): "
                  f"{'PASS' if sustained_ok else 'FAIL'} (found {len(sustained_jets)} jet(s) with orbit >={a.require_sustained_orbit:.0f}s)")

        rwy = runway_line(a.runway)
        if len(res["aircraft"]) > 1:
            most, closest, closest_air = traffic(trace, rwy, col)
            sep_ok = most <= 1 and closest >= MIN_GROUND_GAP_M and closest_air >= 250.0
            all_ok = all_ok and sep_ok
            print(f"{run_name:16} traffic: runway {most}, ground {closest:.0f} m, air {closest_air:.0f} m"
                  f"  {'PASS' if sep_ok else 'FAIL'}")
        draw(run_dir, items, plan_lines, trace, len(jets), rwy, col)
    print("ALL PASS" if all_ok else "SOME FAILED", "-", base)
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
