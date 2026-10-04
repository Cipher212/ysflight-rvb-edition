# Parse a YSFlight .fld (with packed sub-files) into world-space items. YS angles: 65536 = 360 deg.
import math, re, sys, json
from collections import Counter, defaultdict
lines = open(sys.argv[1], encoding="latin-1").read().splitlines()
packs = {}
def unpack(ls):
    """Split a field's lines into its own lines and its packed sub-files (packs can be nested: an airfield
    sub-field is packed inside a side's sub-field)."""
    own = []
    i = 0
    while i < len(ls):
        m = re.match(r'PCK\s+"([^"]+)"\s+(\d+)', ls[i])
        if m:
            n = int(m.group(2))
            packs[m.group(1)] = unpack(ls[i+1:i+1+n])
            i += 1 + n
            continue
        own.append(ls[i])
        i += 1
    return own
top = unpack(lines)
def blocks(ls):
    """Yield (keyword, [lines]) for the FIELD-level object blocks: RGN, GOB, FLD, PST, PC2, TER ... up to END/ENDO."""
    out = []; cur = None
    for l in ls:
        k = l.split()[:1]
        if not k: continue
        k = k[0]
        if cur is None and k in ("RGN", "GOB", "FLD", "PST", "PC2", "TER", "SRF", "AIR", "PLT"):
            cur = [k, []]; continue
        if cur is not None:
            if k == "END":
                out.append(cur); cur = None
            else:
                cur[1].append(l)
    return out
def kv(bl, key):
    for l in bl:
        p = l.split()
        if p and p[0] == key: return p[1:]
    return None
def xf(pos, x, z):
    px, py, pz, h = float(pos[0]), float(pos[1]), float(pos[2]), float(pos[3]) * math.pi * 2 / 65536
    c, s = math.cos(h), math.sin(h)
    return (px + c * x - s * z, pz + s * x + c * z), h
items = []
def walk(ls, pos, depth, src):
    for k, bl in blocks(ls):
        p = kv(bl, "POS"); p = [float(v) for v in p] if p else [0, 0, 0, 0, 0, 0]
        # compose transform (heading only; pitch/bank are 0 on this map)
        (wx, wz), _ = xf(pos, p[0], p[2])
        wh = pos[3] + p[3]
        wp = [wx, pos[1] + p[1], wz, wh]
        if k == "FLD":
            f = kv(bl, "FIL")[0].strip('"')
            items.append(dict(kind="FLD", file=f, pos=wp, src=src))
            walk(packs.get(f, []), wp, depth + 1, f)
        elif k == "RGN":
            a = [float(v) for v in kv(bl, "ARE")]
            tag = kv(bl, "TAG")
            items.append(dict(kind="RGN", id=int(kv(bl, "ID")[0]), are=a, pos=wp, tag=" ".join(tag).strip('"') if tag else "", src=src))
        elif k == "GOB":
            tag = kv(bl, "TAG")
            items.append(dict(kind="GOB", name=kv(bl, "NAM")[0], iff=int(kv(bl, "IFF")[0]), tag=" ".join(tag).strip('"') if tag else "", pos=wp, src=src))
        elif k == "PST":
            items.append(dict(kind="PST", n=sum(1 for l in bl if l.startswith("VER")), pos=wp, src=src,
                              area=(kv(bl, "AREA") or [""])[0], loop=(kv(bl, "ISLOOP") or [""])[0], id=(kv(bl,"ID") or ["?"])[0]))
walk(top, [0, 0, 0, 0], 0, "main")
json.dump(items, open(sys.argv[2], "w"))
