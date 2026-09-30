"""Runs the UI smoke test (godot_project/tests/ui_smoke.gd): every menu screen is instantiated headless.
Exit code 0 = all screens loaded without script / shader errors."""
import os
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
GODOT = os.path.join(ROOT, "engine", "Godot_v4.7.2-stable_win64_console.exe")


def main():
    proc = subprocess.run([GODOT, "--headless", "--path", os.path.join(ROOT, "godot_project"), "-s",
                           "res://tests/ui_smoke.gd"], capture_output=True, text=True, timeout=180)
    out = proc.stdout + proc.stderr
    errors = [l for l in out.splitlines() if "SCRIPT ERROR" in l or "SHADER ERROR" in l or "Parse Error" in l
              or "UI SMOKE FAIL" in l]
    for l in out.splitlines():
        if l.startswith("UI SMOKE"):
            print(l)
    for l in errors[:15]:
        print("ERROR:", l)
    ok = "UI SMOKE OK" in out and not errors
    print("UI smoke:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
