"""Writes godot_project/mission/luavi_rvb_16v16.yfs: a mixed-class 16v16 over Luavi for the RvB tactical AI.
Every role on both sides, with each aircraft's own DAT default loadout (bombs, AGMs, missiles).
All air starts (ground operations are archived).
Slot 1 (Blue F-16) is the player; --ai-player hands it to the AI as well.
Also writes luavi_rvb_landing_test.yfs: three jets low on fuel near their bases, no fight (RTB tests),
and luavi_rvb_departure_test.yfs: nine jets on the ground at every airfield start spot (taxi / take-off tests)."""
import os

OUT = os.path.join(os.path.dirname(__file__), '..', 'godot_project', 'mission', 'luavi_rvb_16v16.yfs')

HEADER = """YFSVERSI 20141101
SIMTITLE "RvB AI test: 16v16 mixed classes over Luavi"
FIELDNAM [RVB]LUAVI 0 0 0 0 0 0 TRUE
ALLOWAAM TRUE
ALLOWGUN TRUE
ALLOWAGM TRUE
ALLOWBOM TRUE
ALLOWRKT TRUE
"""

BLUE = [  # (aircraft, ground start position or None)
    ("F-16(BLUE/MULTIROLE)", None),
    ("F-15(BLUE/MULTIROLE)", None),
    ("F-18(BLUE/MULTIROLE)", None),
    ("RAFALE(BLUE/MULTIROLE)", None),
    ("TYPHOON(BLUE/MULTIROLE)", None),
    ("F-14(BLUE/BVR)", None),
    ("F-22(BLUE/STEALTH)", None),
    ("F-35(BLUE/STEALTH)", None),
    ("F-5(BLUE/GUNNER)", None),
    ("F-8(BLUE/GUNNER)", None),
    ("TORNADO(BLUE/ATTACKER)", None),
    ("JAGUAR(BLUE/ATTACKER)", None),
    ("MIRAGE_III(BLUE/ATTACKER)", None),
    ("A-10(BLUE/CAS)", None),
    ("[BLUE]UCAV", None),
    ("B-1(BLUE/HEAVY)", None),
]
RED = [
    ("MIG-29(RED/MULTIROLE)", None),
    ("SU-27(RED/MULTIROLE)", None),
    ("SU-30(RED/MULTIROLE)", None),
    ("J-10(RED/MULTIROLE)", None),
    ("SU-35(RED/MULTIROLE)", None),
    ("MIG-25(RED/BVR)", None),
    ("J-20(RED/STEALTH)", None),
    ("SU-75(RED/STEALTH)", None),
    ("MIG-17(RED/GUNNER)", None),
    ("MIG-19(RED/GUNNER)", None),
    ("SU-22(RED/ATTACKER)", None),
    ("MIG-27(RED/ATTACKER)", None),
    ("JH-7(RED/ATTACKER)", None),
    ("SU-25(RED/CAS)", None),
    ("[RED]UCAV", None),
    ("TU-22(RED/HEAVY)", None),
]

AI_TAIL = """INTENTIO
MINIALTI 400
DOGFIGHT G7.00 B15.00
ENDINTEN
LANDLWFL 0.00
"""


def plane(name, iff, index, start, player):
    lines = ['', 'AIRPLANE "%s" %s' % (name, 'TRUE' if player else 'FALSE'), 'IDENTIFY %d' % iff]
    if start:
        lines.append('STARTPOS 0 %s' % start)
    else:
        side = -1.0 if iff == 0 else 1.0
        row, col = divmod(index, 4)
        x = side * (4000.0 + row * 900.0)
        z = 6000.0 + (col - 1.5) * 1200.0
        y = 1500.0 + (index % 3) * 600.0
        lines += [
            'AIRPCMND POSITION %.1fm %.1fm %.1fm' % (x, y, z),
            'AIRPCMND ATTITUDE %.1fdeg 0.0deg 0.0deg' % (-90.0 if iff == 0 else 90.0),
            'AIRPCMND INITSPED 200.0m/s',
            'AIRPCMND CTLTHROT 0.85',
            'AIRPCMND CTLLDGEA FALSE',
        ]
    lines.append('AIRPCMND INITFUEL 100%')
    text = '\n'.join(lines) + '\n'
    return text if player else text + AI_TAIL


LANDING_TEST = [  # (aircraft, iff, x, y, z): low on fuel near their bases, no fight -> RTB, land, refuel, go
    ("F-16(BLUE/MULTIROLE)", 0, -14000.0, 1500.0, 16000.0),
    ("TORNADO(BLUE/ATTACKER)", 0, -30000.0, 1200.0, -8000.0),
    ("MIG-29(RED/MULTIROLE)", 3, 12000.0, 1500.0, 16000.0),
]


def landing_test():
    out = os.path.join(os.path.dirname(OUT), 'luavi_rvb_landing_test.yfs')
    parts = [HEADER.replace('RvB AI test: 16v16 mixed classes', 'RvB AI landing test')]
    for i, (name, iff, x, y, z) in enumerate(LANDING_TEST):
        lines = ['', 'AIRPLANE "%s" %s' % (name, 'TRUE' if i == 0 else 'FALSE'), 'IDENTIFY %d' % iff,
                 'AIRPCMND POSITION %.1fm %.1fm %.1fm' % (x, y, z),
                 'AIRPCMND ATTITUDE 0.0deg 0.0deg 0.0deg', 'AIRPCMND INITSPED 180.0m/s',
                 'AIRPCMND CTLTHROT 0.8', 'AIRPCMND CTLLDGEA FALSE', 'AIRPCMND INITFUEL 4%']
        parts.append('\n'.join(lines) + '\n')
        if i:
            parts.append(AI_TAIL)
    with open(out, 'w', newline='\n') as f:
        f.write(''.join(parts))
    print('Wrote', os.path.normpath(out))


DEPARTURE_TEST = [  # (aircraft, iff, start spot): all on the ground at the airfields, no fight -> taxi, take-off, climb-out
    ("F-16(BLUE/MULTIROLE)", 0, "[IFF1]COLE_AFB_HOLD_SHORT"),
    ("F-15(BLUE/MULTIROLE)", 0, "[IFF1]COLE_AFB_RUNWAY"),
    ("TORNADO(BLUE/ATTACKER)", 0, "[IFF1]BALUUT_HOLD_SHORT"),
    ("A-10(BLUE/CAS)", 0, "[IFF1]BALUUT_RUNWAY"),
    ("F-5(BLUE/GUNNER)", 0, "[IFF1]HIGHWAY_STRIP"),
    ("MIG-29(RED/MULTIROLE)", 3, "[IFF4]SAKHET"),
    ("SU-27(RED/MULTIROLE)", 3, "[IFF4]SAKHET_RUNWAY"),
    ("SU-25(RED/CAS)", 3, "[IFF4]MANTARUUN_HOLD_SHORT"),
    ("MIG-17(RED/GUNNER)", 3, "[IFF4]DIRT_STRIP"),
]


def departure_test():
    out = os.path.join(os.path.dirname(OUT), 'luavi_rvb_departure_test.yfs')
    parts = [HEADER.replace('RvB AI test: 16v16 mixed classes', 'RvB AI departure test')]
    for i, (name, iff, stp) in enumerate(DEPARTURE_TEST):
        lines = ['', 'AIRPLANE "%s" %s' % (name, 'TRUE' if i == 0 else 'FALSE'), 'IDENTIFY %d' % iff,
                 'STARTPOS 0 %s' % stp, 'AIRPCMND INITFUEL 100%']
        parts.append('\n'.join(lines) + '\n')
        if i:
            parts.append(AI_TAIL)
    with open(out, 'w', newline='\n') as f:
        f.write(''.join(parts))
    print('Wrote', os.path.normpath(out))


def main():
    parts = [HEADER]
    for i, (name, start) in enumerate(BLUE):
        parts.append(plane(name, 0, i, start, i == 0))
    for i, (name, start) in enumerate(RED):
        parts.append(plane(name, 3, i, start, False))
    with open(OUT, 'w', newline='\n') as f:
        f.write(''.join(parts))
    print('Wrote', os.path.normpath(OUT))


if __name__ == '__main__':
    main()
    landing_test()
    departure_test()
