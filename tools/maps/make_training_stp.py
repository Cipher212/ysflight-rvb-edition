# Training start positions for recording AI approach replays on Luavi (stock YSCE install).
# For each base (runway direction facing away from the enemy, or a carrier) four directions 10 km out - final
# (straight in), left, right, beyond (from the far side, for an overhead) - each LOW and HIGH, flying fast,
# gear up, heading at the threshold. All IFF 0, because the training map has every ground unit set to IFF 0.
# Usage: python make_training_stp.py <items.json from parse_fld.py> <out.stp> [ground_heights.json]
# YS: x east, z north, heading h (deg) -> forward (-sin h, cos h); an ILS faces the traffic landing on it.
import json, math, sys

OUT_KM = 10.0
LOW_AGL_M = 200.0
HIGH_M = 3000.0
SPEED_MS = 220.0  # ~430 kt
BASES = [  # name, ILS tag (landing threshold + direction), or carrier tag
    ("COLE_29", "ils", "COLE_29"),
    ("BALUUT_33", "ils", "BALUUT_33"),
    ("SAKHET_08", "ils", "SAKHET_08"),
    ("MANTURUUN_09", "ils", "MANTURUUN"),
    ("NIMITZ", "carrier", "IFF1_CARRIER"),  # no "CARRIER" in names: the game's spawn code treats those as decks
    ("SHANDONG", "carrier", "IFF4_CARRIER"),
]
DIRS = [("FINAL", 180.0), ("LEFT", -90.0), ("RIGHT", 90.0), ("BEYOND", 0.0)]  # bearing from the threshold vs landing heading

items = json.load(open(sys.argv[1]))
ground = json.load(open(sys.argv[3])) if len(sys.argv) > 3 else {}
def ys_hdg(compass):  # compass bearing (deg, clockwise from north) -> YS heading in -180..180
    return (-compass + 180.0) % 360.0 - 180.0
def compass_of_ys(h):
    return (-h) % 360.0

out = []
for name, kind, tag in BASES:
    obj = next(x for x in items if x["kind"] == "GOB" and x["tag"] == tag and (kind != "ils" or x["name"] == "[GOP]ILS"))
    h = obj["pos"][3] * 360.0 / 65536.0
    if kind == "ils":
        landing = (compass_of_ys(h) + 180.0) % 360.0  # the antenna faces the approaching traffic
    else:
        landing = compass_of_ys(h)                     # carriers: land along the ship's heading, from astern
    tx, tz = obj["pos"][0], obj["pos"][2]
    for dname, rel in DIRS:
        b = math.radians(landing + rel)
        sx, sz = tx + OUT_KM * 1000.0 * math.sin(b), tz + OUT_KM * 1000.0 * math.cos(b)
        towards = math.degrees(math.atan2(tx - sx, tz - sz)) % 360.0
        for level in ("LOW", "HIGH"):
            key = f"TRAIN_{name}_{dname}_{level}"
            alt = HIGH_M if level == "HIGH" else ground.get(key, 0.0) + LOW_AGL_M
            out += [f"N {key}", "P IFF 0",
                    f"C POSITION {sx:.2f}m {alt:.2f}m {sz:.2f}m",
                    f"C ATTITUDE {ys_hdg(towards):.2f}deg 0.00deg 0.00deg",
                    f"C INITSPED {SPEED_MS:.2f}m/s", "C CTLTHROT 0.80", "C CTLLDGEA FALSE", ""]
    print(f"{name:14} landing heading {landing:6.1f}  threshold ({tx:.0f}, {tz:.0f})")
open(sys.argv[2], "w", newline="\r\n").write("\n".join(out))
