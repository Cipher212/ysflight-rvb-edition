"""Plot Cole 29 runway, replay approach paths, and candidate holding footprints
against the airfield terrain and pavement.
"""
import json
import math
import os
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.."))
sys.path.insert(0, os.path.join(ROOT, "tools", "maps"))
import draw_airfield

EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

def make_circle(cx, cz, r, n_pts=48):
    pts = []
    for i in range(n_pts + 1):
        ang = 2.0 * math.pi * i / n_pts
        pts.append((cx + r * math.sin(ang), cz + r * math.cos(ang)))
    return pts

def main():
    out_dir = os.path.join(ROOT, "crashlog", "holding_plot")
    os.makedirs(out_dir, exist_ok=True)
    items_path = os.path.join(out_dir, "items.json")
    if not os.path.exists(items_path):
        # Generate items.json
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "maps", "parse_fld.py"),
                        os.path.join(ROOT, "godot_project", "user", "RvB", "ww3", "Luavi.fld"), items_path], check=True)
    items = json.load(open(items_path))

    # Read plan lines from cole_29.txt
    plan_path = os.path.join(ROOT, "godot_project", "ai", "cole_29.txt")
    approach_lines = {}
    cur_name = None
    for line in open(plan_path):
        if line.startswith("APPROACH"):
            cur_name = line.split()[1]
            approach_lines[cur_name] = []
        elif line.startswith("A ") and cur_name:
            p = line.split()
            approach_lines[cur_name].append((float(p[1]), float(p[2])))

    # Cole runway parameters
    thr = (-16979.67, 8578.12)
    hdg = 291.386
    rlen = 1440.5
    ux = math.sin(math.radians(hdg))
    uz = math.cos(math.radians(hdg))
    rx = uz
    rz = -ux

    # Candidate 1: South / Left Downwind (outside corridors, away from map center)
    al1, cr1 = -2000.0, -4500.0
    c1 = (thr[0] + al1 * ux + cr1 * rx, thr[1] + al1 * uz + cr1 * rz)
    r_hold = 2000.0

    # Candidate 2: North / Right Downwind
    al2, cr2 = -2000.0, 4500.0
    c2 = (thr[0] + al2 * ux + cr2 * rx, thr[1] + al2 * uz + cr2 * rz)

    # Corridors:
    # Final Approach corridor: along -8000 to 0, cross +-1000
    corr_pts = [
        (thr[0] - 8000 * ux - 1000 * rx, thr[1] - 8000 * uz - 1000 * rz),
        (thr[0] - 8000 * ux + 1000 * rx, thr[1] - 8000 * uz + 1000 * rz),
        (thr[0] + 0 * ux + 1000 * rx, thr[1] + 0 * uz + 1000 * rz),
        (thr[0] + 0 * ux - 1000 * rx, thr[1] + 0 * uz - 1000 * rz),
        (thr[0] - 8000 * ux - 1000 * rx, thr[1] - 8000 * uz - 1000 * rz)
    ]
    # Departure corridor: along 1440 to 6000, cross +-1000
    dep_pts = [
        (thr[0] + 1440 * ux - 1000 * rx, thr[1] + 1440 * uz - 1000 * rz),
        (thr[0] + 1440 * ux + 1000 * rx, thr[1] + 1440 * uz + 1000 * rz),
        (thr[0] + 6000 * ux + 1000 * rx, thr[1] + 6000 * uz + 1000 * rz),
        (thr[0] + 6000 * ux - 1000 * rx, thr[1] + 6000 * uz - 1000 * rz),
        (thr[0] + 1440 * ux - 1000 * rx, thr[1] + 1440 * uz - 1000 * rz)
    ]

    tracks = []
    # Approach corridors in dashed red
    tracks.append((corr_pts, "#ff5555", 1.5, "6,4"))
    tracks.append((dep_pts, "#ff5555", 1.5, "6,4"))

    # Approach lines in white
    for name, pts in approach_lines.items():
        tracks.append((pts, "#ffffff", 2))

    # Candidate 1: South / Left (Yellow dashed circle)
    tracks.append((make_circle(c1[0], c1[1], r_hold), "#ffd400", 2.5))
    # Candidate 2: North / Right (Cyan dashed circle)
    tracks.append((make_circle(c2[0], c2[1], r_hold), "#00e5ff", 2, "4,3"))

    # Marks for gates and candidate centers
    marks = [
        (c1[0], c1[1], "#ffd400", "Candidate 1 (South / Left Downwind)"),
        (c2[0], c2[1], "#00e5ff", "Candidate 2 (North / Right)"),
        (thr[0], thr[1], "#ff3030", "RWY 29 Thr"),
    ]
    for name, pts in approach_lines.items():
        marks.append((pts[0][0], pts[0][1], "#ffffff", f"Gate {name}"))

    # Airfield centre
    cx = thr[0] - ux * 2500
    cz = thr[1] - uz * 2500

    out_svg = os.path.join(out_dir, "cole29_holding_geometry.svg")
    draw_airfield.svg(items, (cx, cz), 9000, 9000, out_svg, tracks, marks,
                      title="Cole 29: Approach Lines (white), Corridors (red dashes) &amp; Candidate Holding Areas (yellow=South, cyan=North)",
                      px_per_m=0.055)
    print("Wrote SVG:", out_svg)

    if os.path.exists(EDGE):
        out_png = os.path.join(out_dir, "cole29_holding_geometry.png")
        subprocess.run([EDGE, "--headless=new", "--disable-gpu", f"--screenshot={out_png}",
                        "--window-size=1080,1080", "file:///" + out_svg.replace("\\", "/")],
                       capture_output=True, timeout=30)
        print("Rendered PNG:", out_png)

if __name__ == "__main__":
    main()
