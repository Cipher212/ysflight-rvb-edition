"""Runs the automated game test (godot_project/tests/test_runner.gd) and prints the result.

Usage:  python tools/run_tests.py            (from the game folder; needs engine/ from Play.bat's first run)
Exit code 0 = every check passed. Screenshots of each step: crashlog/tests/<time>/.
Run it before every commit/push that touches game code.
"""
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
GODOT = os.path.join(ROOT, "engine", "Godot_v4.7.2-stable_win64_console.exe")
TIMEOUT_S = 300


def main():
    if not os.path.exists(GODOT):
        print("Godot not found at", GODOT, "- run Play.bat once (it downloads the engine).")
        return 2
    started = sorted(glob.glob(os.path.join(ROOT, "crashlog", "tests", "*")))
    try:
        proc = subprocess.run([GODOT, "--path", os.path.join(ROOT, "godot_project"), "--", "--run-tests"],
                              capture_output=True, text=True, timeout=TIMEOUT_S, errors="replace")
    except subprocess.TimeoutExpired:
        print("FAIL: the test run did not finish within", TIMEOUT_S, "s")
        return 3
    runs = [d for d in sorted(glob.glob(os.path.join(ROOT, "crashlog", "tests", "*"))) if d not in started]
    result_path = os.path.join(runs[-1], "results.json") if runs else ""
    if not result_path or not os.path.exists(result_path):
        print("FAIL: no results.json (the game probably crashed). Last output lines:")
        print("\n".join((proc.stdout + proc.stderr).splitlines()[-30:]))
        return 4
    with open(result_path, encoding="utf-8") as f:
        res = json.load(f)
    for r in res["results"]:
        detail = f"  ({r['detail']})" if r["detail"] else ""
        print(f"{'PASS' if r['ok'] else 'FAIL'}  {r['name']}{detail}")
    script_errors = [l for l in (proc.stdout + proc.stderr).splitlines() if "SCRIPT ERROR" in l]
    for l in script_errors[:10]:
        print("SCRIPT ERROR:", l)
    print(f"\n{res['total'] - res['failed']}/{res['total']} passed, {len(script_errors)} script errors. Screenshots: {res['dir']}")
    return 1 if res["failed"] or script_errors else 0


if __name__ == "__main__":
    sys.exit(main())
