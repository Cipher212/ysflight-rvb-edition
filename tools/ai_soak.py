"""AI soak run: plays a mission with every aircraft on AI and prints what the RvB AI did.

Usage:  python tools/ai_soak.py [--mission res://mission/luavi_rvb_16v16.yfs] [--seconds 600] [--speed 4]
                                [--headless] [--stock-ai]
--seconds is sim time; --speed runs that many sim steps per physics tick (faster than real time).
Output: crashlog/ai_soak/<time>/samples.json (every 10 s) and summary.json.
"""
import argparse
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
GODOT = os.path.join(ROOT, "engine", "Godot_v4.7.2-stable_win64_console.exe")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mission", default="res://mission/luavi_rvb_16v16.yfs")
    ap.add_argument("--seconds", type=float, default=600.0)
    ap.add_argument("--speed", type=int, default=4)
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--stock-ai", action="store_true")
    ap.add_argument("--ground-ops", action="store_true", help="archived RTB / landing / taxi")
    ap.add_argument("--sample", type=float, default=10.0, help="sim seconds between samples")
    ap.add_argument("--trace", default="", help="print every sample of aircraft whose name contains this")
    a = ap.parse_args()
    if not os.path.exists(GODOT):
        print("Godot not found at", GODOT, "- run Play.bat once (it downloads the engine).")
        return 2

    cmd = [GODOT, "--path", os.path.join(ROOT, "godot_project")]
    if a.headless:
        cmd.append("--headless")
    cmd += ["--", "--mission", a.mission, "--ai-soak", str(a.seconds), "--sim-speed", str(a.speed),
            "--soak-sample", str(a.sample)]
    if a.stock_ai:
        cmd.append("--stock-ai")
    if a.ground_ops:
        cmd.append("--ai-ground-ops")
    before = set(glob.glob(os.path.join(ROOT, "crashlog", "ai_soak", "*")))
    timeout = max(120.0, a.seconds / max(1, a.speed) * 3.0 + 120.0)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, errors="replace")
    except subprocess.TimeoutExpired:
        print("FAIL: the soak run did not finish within", int(timeout), "s")
        return 3
    for line in (proc.stdout + proc.stderr).splitlines():
        if line.startswith("AI soak") or "SCRIPT ERROR" in line or "ERROR" in line:
            print(line)
    runs = sorted(set(glob.glob(os.path.join(ROOT, "crashlog", "ai_soak", "*"))) - before)
    path = os.path.join(runs[-1], "summary.json") if runs else ""
    if not path or not os.path.exists(path):
        print("FAIL: no summary.json (the game probably crashed). Last output lines:")
        print("\n".join((proc.stdout + proc.stderr).splitlines()[-30:]))
        return 4
    with open(path, encoding="utf-8") as f:
        s = json.load(f)
    fin = s["final"]
    print(f"\n{s['sim_seconds']:.0f} s of sim in {s['real_seconds']:.0f} s ({s['speed']:.1f}x)")
    print("alive by IFF:", fin.get("alive_by_iff"), "  RvB AIs:", fin.get("rvb_ai"), "  roles:", fin.get("roles"))
    print("landings", fin.get("landings"), " refuels", fin.get("refuels"), " take-offs", fin.get("takeoffs"),
          " respawned", fin.get("respawned"), " wrecks removed", fin.get("wrecks_removed"))
    print("most aircraft in each task at once:", s["max_tasks_at_once"])
    print("most aircraft in each recovery stage at once:", s["max_stages_at_once"])
    print("picture refreshes", fin.get("picture_refreshes"), " known contacts now", fin.get("known_contacts"),
          " calls heard now", fin.get("calls_heard"))
    print("RTBs by reason:", fin.get("rtb_by_reason"))
    print("deaths by cause:", fin.get("deaths_by_cause"))
    print("deaths by task:", fin.get("deaths_by_task"))
    busy = [x for x in fin.get("aircraft", []) if x["task"] in ("LAUNCH", "RTB")]
    for x in sorted(busy, key=lambda x: -x["stage_s"])[:12]:
        print(f"  {x['id']:28s} {x['task']:7s} {x['stage']:15s} {x['stage_s']:6.0f}s  alt {x['alt']:6.0f}  "
              f"speed {x['speed']:5.1f}  ground {x['ground']}  phase {x.get('phase', -1)}  x {x['x']:8.0f} z {x['z']:8.0f}")
    if a.trace:
        with open(os.path.join(runs[-1], "samples.json"), encoding="utf-8") as f:
            for smp in json.load(f):
                for x in smp.get("aircraft", []):
                    if a.trace in x["id"]:
                        print(f"  t={smp['sim_time']:6.1f} {x['id']:24s} {x['task']:7s} {x['stage']:15s} "
                              f"{x['stage_s']:5.0f}s alt {x['alt']:6.0f} agl {x['agl']:6.0f} spd {x['speed']:5.1f} "
                              f"gnd {int(x['ground'])} ph {x.get('phase', -1)} x {x['x']:8.0f} z {x['z']:8.0f} fuel {x['fuel']:6.0f}")
    print("Details:", runs[-1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
