# YSFlight RvB Edition - v0.1.0-pre-alpha

YSFlight's flight simulation (YSFlight Community Edition) running inside the Godot 4 engine, built for
the RvB (Red vs Blue) community events. **This is a pre-alpha test build**: expect bugs and missing
features. Right now it starts a 16 vs 16 AI dogfight on the Luavi map with you in an F-16.

## How to play (Windows 10/11, 64-bit)

1. Click the green **Code** button on this page, then **Download ZIP**.
2. Unzip it anywhere (for example your Desktop). Any folder works.
3. Double-click **`Play.bat`**.
   - The first start downloads the free Godot 4.7.2 engine (about 86 MB, from the official Godot
     GitHub page) and prepares the game files. This takes a minute or two and only happens once.
   - If Windows shows "Windows protected your PC", click **More info**, then **Run anyway**.
4. You spawn in the air in an F-16. Have fun.

Other launchers:
- **`Spectate_AI.bat`**: the AI flies your jet; press F1 to F8 to watch from different cameras.
- **`Benchmark.bat`**: a 2-minute performance test (silent). Please send us the numbers.

If the download fails (no internet, firewall), download `Godot_v4.7.2-stable_win64.exe.zip` from
https://godotengine.org/download/archive/ yourself and unzip it into a folder called `engine` next to
`Play.bat`.

## Controls (YSFlight defaults)

| | |
|---|---|
| Stick | Mouse (default) or arrow keys; gamepad left stick; joystick |
| Throttle | Q / A, W = full, S = idle, mouse wheel |
| Afterburner | Tab |
| Rudder | Z / X (centre) / C |
| Fire weapon / gun | Space or right mouse / Ctrl or left mouse |
| Change weapon / flare | 2 or middle mouse / 4 |
| Direct weapon select | 5 gun, 6 short-range, 7 medium-range, 8 air-to-ground, 9 bombs |
| Gear / flaps / brake / spoiler | G / F and R / B / D |
| Views | F1 cockpit, F2 outside |
| Look around | U H K M J N |
| Radar range | 3 |
| Recentre mouse stick | O |
| Settings (controls, curves, graphics) | Esc |
| Flight setup / respawn | F10 |
| Pause | P |

You respawn automatically 5 seconds after being shot down.

## Reporting problems

Tell us what you did and what happened. The file `crashlog\latest_run.txt` (created next to
`Play.bat`) helps us a lot.

## Credits

- **YSFlight** by **Soji Yamakawa (CaptainYS)** - http://www.ysflight.com, https://github.com/captainys
- **YSFlight Community Edition (YSCE)** by the **YSCE Development Committee** - https://github.com/YSCEDC/YSCE
  (the simulation code in `ysce/` and `ysce_public/`, BSD licence: see `ysce/LICENSE`)
- **YS WW3 / Luavi**: map and ground objects by **UltraViolet (Waspe414)**, ground objects by
  **CrazyPilot**, and the **2ch** ground-object pack by the 2ch YSFlight creators. Used with permission;
  their original credit and permission notes are kept next to the files in `godot_project/user/`.
- **Godot Engine** and **godot-cpp** (MIT licence) - https://godotengine.org
- Stock YSFlight sound effects from YSFlight / YSCE.

Full licence texts: `THIRD_PARTY_LICENSES.txt`.

## For developers

The game code is in `godot_project/` (GDScript) and `gdextension/ysflight/src/` (the C++ bridge to the
YSFlight simulation). A pre-built bridge (`godot_project/bin/*.dll`) is included, so you only need to
rebuild it if you change the C++: install Python + SCons + Visual Studio 2022 C++ tools, then run
`python -m SCons platform=windows target=template_debug` in `gdextension/ysflight`.
