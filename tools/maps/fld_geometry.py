"""Read-only Luavi geometry with packed-file/source-line provenance.

PC2 is geometry, RGN is simulator semantics: keep both independent. World
coordinates follow parse_fld.py and the heading-only placements in this map.
Tilted geometry is rejected rather than silently producing wrong measurements.
"""
import math
import re
from pathlib import Path


BLOCKS = {'RGN', 'GOB', 'FLD', 'PST', 'PC2', 'TER', 'SRF', 'AIR', 'PLT'}
DRAWINGS = {'PLG', 'TRI', 'QDR', 'QST', 'GQS', 'PLL', 'LSQ', 'PST', 'APL'}


def values(lines, key, default=None):
    for _, line in lines:
        parts = line.split()
        if parts and parts[0] == key:
            return parts[1:]
    return default


def text_value(lines, key, default=''):
    return ' '.join(values(lines, key, [default])).strip('"')


def transform(pos, x, z):
    h = pos[3] * math.tau / 65536
    c, s = math.cos(h), math.sin(h)
    return [pos[0] + c*x - s*z, pos[2] + s*x + c*z]


def compose(parent, local):
    x, z = transform(parent, local[0], local[2])
    return [x, parent[1]+local[1], z, parent[3]+local[3]]


def blocks(lines):
    current = None
    for number, line in lines:
        parts = line.split()
        if not parts:
            continue
        key = parts[0]
        if current is None and key in BLOCKS:
            current = [key, number, []]
        elif current is not None:
            if key == 'END':
                yield current
                current = None
            else:
                current[2].append((number, line))
    if current is not None:
        raise ValueError(f'Unclosed field block at {current[1]}')


class FieldGeometry:
    def __init__(self, path):
        self.path = Path(path)
        self.packs = {}
        self.pack_ranges = {}
        self.primitives, self.regions, self.objects = [], [], []
        self.terrain, self.shells, self.instances = [], [], []
        self.tilted_objects, self.areas = [], []
        raw = list(enumerate(self.path.read_text(encoding='latin-1').splitlines(), 1))
        self.line_count = len(raw)
        root = self.unpack(raw)
        self.walk(root, [0, 0, 0, 0], 'main', [])

    def unpack(self, lines):
        own, i = [], 0
        while i < len(lines):
            number, line = lines[i]
            match = re.fullmatch(r'PCK\s+"([^"]+)"\s+(\d+)\s*', line)
            if match:
                name, count = match[1], int(match[2])
                if name in self.packs or i+count >= len(lines):
                    raise ValueError(f'Duplicate/truncated pack {name} at {number}')
                content = lines[i+1:i+1+count]
                self.pack_ranges[name] = [number, content[-1][0], count]
                self.packs[name] = self.unpack(content)
                i += count+1
            else:
                own.append((number, line))
                i += 1
        return own

    def walk(self, lines, parent, source, chain):
        for kind, number, body in blocks(lines):
            local = list(map(float, values(body, 'POS', ['0']*6)))
            if any(abs(v) > .001 for v in local[4:]):
                if kind in {'GOB', 'AIR'}:
                    self.tilted_objects.append(number)
                else:
                    raise ValueError(f'Tilted {kind} geometry at {number}')
            pos = compose(parent, local)
            entry = dict(kind=kind, line=number, source=source, pos=pos,
                         chain=chain, tag=text_value(body, 'TAG'))
            if kind in {'FLD', 'PC2', 'TER', 'SRF', 'PLT'}:
                name = text_value(body, 'FIL')
                entry['file'] = name
                self.instances.append(entry)
                content = self.packs[name]
                if kind == 'FLD':
                    self.walk(content, pos, name, chain+[number])
                elif kind == 'PC2':
                    self.drawing(content, entry)
                elif kind == 'TER':
                    self.grid(content, entry)
                elif kind == 'SRF':
                    pts = [list(map(float, l.split()[1:4])) for _, l in content
                           if l.startswith('V ')]
                    self.shells.append(dict(entry, vertices=pts,
                        points=[transform(pos, p[0], p[2]) for p in pts]))
            elif kind == 'RGN':
                a = list(map(float, values(body, 'ARE')))
                self.regions.append(dict(entry, id=int(values(body, 'ID')[0]),
                    are=a, points=[transform(pos, x, z) for x, z in
                        [(a[0], a[1]), (a[2], a[1]), (a[2], a[3]), (a[0], a[3])]]))
            elif kind == 'GOB':
                self.objects.append(dict(entry, name=text_value(body, 'NAM'),
                                         iff=int(values(body, 'IFF', ['0'])[0])))
            elif kind == 'PST':
                area = text_value(body, 'AREA', 'NOAREA')
                pts = [list(map(float, l.split()[1:4])) for _, l in body
                       if l.startswith(('VER ', 'PNT '))]
                self.areas.append(dict(entry, area=area,
                    points=[transform(pos, p[0], p[2]) for p in pts]))

    def drawing(self, lines, instance):
        current = None
        for number, line in lines:
            parts = line.split()
            if not parts:
                continue
            key = parts[0]
            if key in DRAWINGS:
                current = dict(instance, primitive=key, draw_line=number,
                               color=[255]*3, color2=[255]*3, local=[])
            elif current is not None:
                if key == 'COL':
                    current['color'] = list(map(int, parts[1:4]))
                elif key == 'CL2':
                    current['color2'] = list(map(int, parts[1:4]))
                elif key == 'VER':
                    current['local'].append(list(map(float, parts[1:3])))
                elif key == 'ENDO':
                    current['draw_end'] = number
                    current['points'] = [transform(instance['pos'], *p)
                                         for p in current['local']]
                    self.primitives.append(current)
                    current = None

    def grid(self, lines, instance):
        nx, nz = map(int, values(lines, 'NBL'))
        dx, dz = map(float, values(lines, 'TMS'))
        nodes = [l.split()[1:] for _, l in lines if l.startswith('BLO ')]
        if len(nodes) != (nx+1)*(nz+1):
            raise ValueError(f'Grid node count {instance["file"]}')
        heights = [float(p[0]) for p in nodes]
        self.terrain.append(dict(instance, nx=nx, nz=nz, dx=dx, dz=dz,
            heights=heights, nodes=nodes,
            points=[transform(instance['pos'], x*dx, z*dz)
                    for z in range(nz+1) for x in range(nx+1)]))


def polygons(primitive):
    """Yield filled drawing faces using the bridge's primitive assembly order."""
    pts, kind = primitive['points'], primitive['primitive']
    if kind == 'PLG' and len(pts) >= 3:
        yield pts
    elif kind in {'QST', 'GQS'}:
        for i in range(0, len(pts)-3, 2):
            yield [pts[i], pts[i+1], pts[i+3], pts[i+2]]
    elif kind in {'TRI', 'QDR'}:
        step = 3 if kind == 'TRI' else 4
        for i in range(0, len(pts)-step+1, step):
            yield pts[i:i+step]
