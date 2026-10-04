# The map's pavement (RGN ID 1 rectangles = YS's "on the runway" test, which decides IsOutOfRunway) near an
# airfield: inside tests, the distance to the pavement edge, and nudging a line away from the edge.
import math

import draw_airfield


class Pavement:
    def __init__(self, items, centre, radius):
        self.rects = []
        for r in items:
            if r["kind"] == "RGN" and r["id"] == 1:
                c = draw_airfield.rgn_corners(r)
                if min(math.dist(p, centre) for p in c) < radius:
                    xs, zs = [p[0] for p in c], [p[1] for p in c]
                    self.rects.append((c, min(xs), max(xs), min(zs), max(zs)))

    def inside(self, x, z):
        for c, x0, x1, z0, z1 in self.rects:
            if x0 <= x <= x1 and z0 <= z <= z1:
                sign = None
                for i in range(4):
                    ax, az = c[i]
                    bx, bz = c[(i + 1) % 4]
                    cr = (bx - ax) * (z - az) - (bz - az) * (x - ax)
                    if sign is None:
                        sign = cr > 0
                    elif (cr > 0) != sign and abs(cr) > 1e-9:
                        break
                else:
                    return True
        return False

    def margin(self, x, z, limit=10.0, step=0.5):
        """Distance from (x, z) to the pavement edge (0 if outside), up to limit: the largest radius whose
        circle of 16 samples is all on the pavement."""
        if not self.inside(x, z):
            return 0.0
        r = step
        while r <= limit:
            for k in range(16):
                a = k * math.pi / 8.0
                if not self.inside(x + r * math.cos(a), z + r * math.sin(a)):
                    return r - step
            r += step
        return limit

    def keep_inside(self, pts, want, reach=10.0):
        """Move points of a line [(x, z, ...)] that are closer than `want` to the edge to the nearest spot
        (within `reach`) that has the margin, else to the best spot found. Returns (new points, moved count)."""
        out, moved = [], 0
        for p in pts:
            if self.margin(p[0], p[1], want) >= want:
                out.append(p)
                continue
            best, best_m = (p[0], p[1]), self.margin(p[0], p[1], want)
            found = False
            d = 1.0
            while d <= reach and not found:
                for k in range(16):
                    a = k * math.pi / 8.0
                    x, z = p[0] + d * math.cos(a), p[1] + d * math.sin(a)
                    m = self.margin(x, z, want)
                    if m > best_m:
                        best, best_m = (x, z), m
                        found = m >= want
                d += 1.0
            moved += 1
            out.append((best[0], best[1]) + tuple(p[2:]))
        return out, moved
