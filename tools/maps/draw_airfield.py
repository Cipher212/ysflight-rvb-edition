# Draw an airfield as an SVG (north up): pavement rectangles (RGN), ground objects, and any tracks / marks.
# Used by build_arrival_plan.py (the plan over the user's replays) and tools/ai_arrival_test.py (AI runs).
import math

SUPPLY_NAMES = ("SUPPLY", "TRUCK", "FUEL", "HANGER_WEAPON")


def rgn_corners(r):
    """World x/z corners of a RGN rectangle (parse_fld.py item)."""
    x0, z0, x1, z1 = r["are"]
    h = r["pos"][3] * 2.0 * math.pi / 65536.0
    c, s = math.cos(h), math.sin(h)
    return [(r["pos"][0] + c * x - s * z, r["pos"][2] + s * x + c * z) for x, z in ((x0, z0), (x1, z0), (x1, z1), (x0, z1))]


def svg(items, centre, half_w, half_h, out, tracks=(), marks=(), title="", px_per_m=0.5):
    """tracks: (points [(x, z)], colour, width_px[, dash]); marks: (x, z, colour, label)."""
    cx, cz = centre
    W, H = 2 * half_w * px_per_m, 2 * half_h * px_per_m

    def p(x, z):
        return f"{(x - cx + half_w) * px_per_m:.1f},{(half_h - (z - cz)) * px_per_m:.1f}"

    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H:.0f}" viewBox="0 0 {W:.0f} {H:.0f}" '
         f'font-family="sans-serif" font-size="11">', f'<rect width="100%" height="100%" fill="#5d6b45"/>']
    for r in items:
        if r["kind"] == "RGN" and r["id"] == 1 and abs(r["pos"][0] - cx) < half_w + 2000 and abs(r["pos"][2] - cz) < half_h + 2000:
            o.append(f'<polygon points="{" ".join(p(x, z) for x, z in rgn_corners(r))}" fill="#9a9a96" stroke="#7a7a76" stroke-width="0.5"/>')
    for g in items:
        if g["kind"] != "GOB" or abs(g["pos"][0] - cx) > half_w or abs(g["pos"][2] - cz) > half_h:
            continue
        sup = any(k in g["name"] for k in SUPPLY_NAMES)
        col = "#1f6fd1" if sup else "#333"
        o.append(f'<circle cx="{p(g["pos"][0], g["pos"][2]).split(",")[0]}" cy="{p(g["pos"][0], g["pos"][2]).split(",")[1]}" '
                 f'r="{4 if sup else 2}" fill="{col}"/>')
        if sup:
            x, y = p(g["pos"][0], g["pos"][2]).split(",")
            o.append(f'<text x="{float(x) + 6:.0f}" y="{float(y) - 4:.0f}" fill="#0b3d82">{g["name"].replace("[GOP]", "")}</text>')
    for t in tracks:
        pts, col, w = t[0], t[1], t[2]
        dash = f' stroke-dasharray="{t[3]}"' if len(t) > 3 else ""
        o.append(f'<polyline points="{" ".join(p(x, z) for x, z in pts)}" fill="none" stroke="{col}" stroke-width="{w}"{dash} stroke-linejoin="round"/>')
    for x, z, col, label in marks:
        sx, sy = p(x, z).split(",")
        o.append(f'<circle cx="{sx}" cy="{sy}" r="4" fill="none" stroke="{col}" stroke-width="2"/>')
        if label:
            o.append(f'<text x="{float(sx) + 6:.0f}" y="{float(sy) + 12:.0f}" fill="{col}">{label}</text>')
    if title:
        o.append(f'<text x="8" y="16" font-size="14" fill="#fff">{title}</text>')
    bar = 100 * px_per_m
    o.append(f'<line x1="8" y1="{H - 10:.0f}" x2="{8 + bar:.0f}" y2="{H - 10:.0f}" stroke="#fff" stroke-width="2"/>'
             f'<text x="{12 + bar:.0f}" y="{H - 6:.0f}" fill="#fff">100 m</text>')
    o.append("</svg>")
    open(out, "w", encoding="utf-8").write("\n".join(o))
