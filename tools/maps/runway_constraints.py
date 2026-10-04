"""Offline runway-corridor screening; never an in-game collision guarantee."""
import re
import shlex
from pathlib import Path

from shapely.geometry import MultiPoint, Point, Polygon
from shapely.ops import unary_union

from fld_geometry import transform


def polygon(points):
    p = Polygon(points)
    return p if p.is_valid else p.buffer(0)


def land_geometry(field):
    # Engine: children in forward order, then own point sets in reverse order.
    groups = {}
    for area in field.areas:
        groups.setdefault(tuple(area['chain']), []).append(area)

    def ordered(chain):
        children = sorted({k[:len(chain)+1] for k in groups
                           if len(k)>len(chain) and k[:len(chain)]==chain})
        for child in children:
            yield from ordered(child)
        yield from reversed(groups.get(chain, []))

    land = Polygon()
    for area in reversed(list(ordered(()))):
        if len(area['points']) < 3:
            continue
        p = polygon(area['points'])
        if area['area'] == 'LAND':
            land = land.union(p)
        elif area['area'] == 'WATER':
            land = land.difference(p)
    return land


def ground_footprints(field, game):
    """Convex SRF envelope; DNM uses a flagged HTRADIUS screening disk."""
    catalog = {}
    for listing in sorted(game.rglob('gro*.lst')):
        for line in listing.read_text(encoding='latin-1').splitlines():
            parts = shlex.split(line, posix=True)
            if len(parts)<3 or not parts[0].lower().endswith('.dat'):
                continue
            dat, collision = game/parts[0], game/parts[2]
            if not dat.exists():
                continue
            content = dat.read_text(encoding='latin-1')
            ident = re.search(r'^IDENTIFY\s+(.+)', content, re.M)
            radius = re.search(r'^HTRADIUS\s+([\d.]+)(\w*)', content, re.M)
            if not ident:
                continue
            r = float(radius[1]) if radius else None
            if radius and radius[2].lower() == 'ft':
                r *= .3048
            vertices = None
            if collision.exists() and collision.suffix.lower()=='.srf':
                vertices = [list(map(float, l.split()[1:4]))
                            for l in collision.read_text(encoding='latin-1').splitlines()
                            if l.startswith('V ')]
            catalog[ident[1].strip().strip('"').upper()] = (vertices, r, str(collision))
    entries, missing = [], []
    for obj in field.objects:
        item = catalog.get(obj['name'].upper())
        if item is None:
            missing.append(obj['line'])
            continue
        verts, radius, path = item
        if verts:
            shape = MultiPoint([transform(obj['pos'], v[0], v[2]) for v in verts]).convex_hull
            method = 'SRF convex envelope'
            if shape.area < .01:
                continue  # Null collision model is not a runway obstruction.
        elif radius is not None and radius > 0:
            shape = Point(obj['pos'][0], obj['pos'][2]).buffer(radius)
            method = 'HTRADIUS disk (approximate DNM envelope)'
        else:
            missing.append(obj['line'])
            continue
        entries.append(dict(object=obj, shape=shape, method=method, collision=path))
    return entries, missing


def terrain_faces(field):
    faces = []
    for grid in field.terrain:
        stride = grid['nx']+1
        for z in range(grid['nz']):
            for x in range(grid['nx']):
                i = z*stride+x
                nodes = [i, i+stride, i+1, i+stride+1]
                flags = grid['nodes'][i]
                tris = [(3, 1, 2), (0, 2, 1)] if flags[1]=='L' else [(1, 0, 3), (2, 3, 0)]
                for n, indices in enumerate(tris):
                    ids = [nodes[j] for j in indices]
                    heights = [grid['heights'][j]+grid['pos'][1] for j in ids]
                    if max(heights)-grid['pos'][1] < .5 or int(flags[3+4*n])&1 == 0:
                        continue
                    faces.append(dict(shape=polygon([grid['points'][j] for j in ids]),
                        heights=heights, points=[grid['points'][j] for j in ids],
                        file=grid['file'], line=grid['line']))
    return faces


def first_distance(shape, center, direction):
    pts = []
    if hasattr(shape, 'geoms'):
        return min(first_distance(g, center, direction) for g in shape.geoms)
    coords = shape.exterior.coords if shape.geom_type=='Polygon' else shape.coords
    for p in coords:
        pts.append((p[0]-center[0])*direction[0]+(p[1]-center[1])*direction[1])
    return max(0, min(pts))


def screen(corridor, center, direction, regions, ground, terrain, land):
    hits = []
    for r in regions:
        p = polygon(r['points']).intersection(corridor)
        if not p.is_empty and p.area>.01:
            hits.append(dict(type='road/safe region', line=r['line'],
                             distance=first_distance(p, center, direction)))
    for g in ground:
        p = g['shape'].intersection(corridor)
        if not p.is_empty:
            hits.append(dict(type='ground object', line=g['object']['line'],
                name=g['object']['name'], method=g['method'],
                distance=first_distance(p, center, direction)))
    for t in terrain:
        p = t['shape'].intersection(corridor)
        if not p.is_empty and p.area>.01:
            hits.append(dict(type='raised terrain face (needs height inspection)',
                line=t['line'], file=t['file'], max_height=max(t['heights']),
                distance=first_distance(p, center, direction)))
    water = corridor.difference(land)
    if not water.is_empty and water.area>.01:
        hits.append(dict(type='semantic water', distance=first_distance(water, center, direction)))
    return sorted(hits, key=lambda h:h['distance'])
