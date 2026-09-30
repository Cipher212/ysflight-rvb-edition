"""Writes godot_project/mission/luavi_stresstest_32v32.yfs: 32 F-16s (Blue, IFF 1) vs
32 MiG-29s (Red, IFF 4), all AI. Run by stresstest.bat with --ai-player, so the one
player-slot F-16 is flown by the dogfight AI too (the camera needs a player to follow)."""
import os

OUT = os.path.join(os.path.dirname(__file__), '..', 'godot_project', 'mission', 'luavi_stresstest_32v32.yfs')
COUNT = 32
COLS = 8
LATERAL = 1500.0  # m between jets side by side (16v16: 200-800 m)
DEPTH = 1500.0    # m between rows
START = 9000.0    # each side starts this far from the centre (18 km apart)
BASE_ALT = 2000.0
ALT_STEP = 400.0

HEADER = """YFSVERSI 20141101
SIMTITLE "Stress Test: 32v32 RvB F-16 (Blue, IFF 1) vs MiG-29 (Red, IFF 4) over Luavi"
FIELDNAM [RVB]LUAVI 0 0 0 0 0 0 TRUE
ALLOWAAM TRUE
ALLOWGUN TRUE
ALLOWAGM FALSE
ALLOWBOM FALSE
ALLOWRKT FALSE
"""

# IDENTIFY is 0-based: 0 = IFF 1, 3 = IFF 4.
PLANE = """
AIRPLANE "{name}" {player}
IDENTIFY {iff}
AIRPCMND POSITION {x:.1f}m {y:.1f}m {z:.1f}m
AIRPCMND ATTITUDE {hdg:.1f}deg 0.0deg 0.0deg
AIRPCMND INITSPED 220.0m/s
AIRPCMND CTLTHROT 0.85
AIRPCMND CTLLDGEA FALSE
AIRPCMND INITFUEL 100%
AIRPCMND UNLOADWP
{weapons}AIRPCMND LOADWEPN FLR 40
AIRPCMND INITIGUN 500
{tail}"""

AI_TAIL = """INTENTIO
MINIALTI 400
DOGFIGHT G7.00 B15.00
ENDINTEN
LANDLWFL 0.00
"""
BLUE_WEAPONS = "AIRPCMND LOADWEPN FUEL 1\nAIRPCMND LOADWEPN AIM120 2\nAIRPCMND LOADWEPN AIM9 4\n"


def side(name, iff, x0, direction, hdg, weapons, first_is_player):
    out = []
    for i in range(COUNT):
        row, col = divmod(i, COLS)
        player = first_is_player and i == 0
        out.append(PLANE.format(
            name=name, player='TRUE' if player else 'FALSE', iff=iff,
            x=x0 - row * DEPTH * direction,
            y=BASE_ALT + (i % 4) * ALT_STEP,
            z=6000.0 + (col - (COLS - 1) / 2) * LATERAL,
            hdg=hdg, weapons=weapons,
            tail='AIRPCMND WEAPONCH AAM\n' if player else AI_TAIL))
    return ''.join(out)


with open(OUT, 'w', newline='\n') as f:
    f.write(HEADER)
    f.write(side('F-16(BLUE/MULTIROLE)', 0, -START, 1, -90.0, BLUE_WEAPONS, True))
    f.write(side('MIG-29(RED/MULTIROLE)', 3, START, -1, 90.0, '', False))
print('wrote', os.path.normpath(OUT))
