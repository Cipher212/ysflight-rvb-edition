# YSFlight RvB Edition - v0.3.0-pre-alpha

YSFlight's flight simulation (YSFlight Community Edition) running inside the Godot 4 engine, built for
the RvB (Red vs Blue) community events. **This is a pre-alpha test build**: expect bugs and missing
features. Right now you can set up and fly an offline RvB event against the AI on the Luavi map
(up to 18 vs 18).

**New in v0.3.0:**
- **Smarter AI:** enemies and wingmen now fly by role (fighters, attackers, bombers, close air support,
  stealth jets, gun fighters and drones). They dodge missiles with flares and hard turns, help nearby
  teammates, and are slower to notice you sneaking up from behind. Shot-down AI jets return after 5
  seconds.
- **Afterburners:** bright flames with shock diamonds, plus heat shimmer behind them.
- **New look:** the sun and distant hills in the sky, sea all the way to the horizon, a grittier Ace
  Combat-style colour grade, drifting cloud shadows, sparkling water, shading on aircraft and buildings,
  YSFlight-style aircraft shadows and sun and explosion glare.
- **Spectator cameras** (F5 / F6) stay locked on the aircraft you picked.
- **New Graphics options** to switch each of the new effects off on slower PCs.
- **Main menu and offline events** (in the RvB website's style): pick your team and callsign, the event
  length (5 minutes to 2 hours), rules (mid-air collisions, friendly fire) and up to 18 AI pilots per
  side. Quick buttons fill a side with random aircraft of a chosen role or copy one side to the other.
  AI pilots keep their names across respawns so their scores add up.
- **Spawn menu during the event:** choose your aircraft, start position and loadout (Default,
  Air-to-Air, Strike, Guns Only). The clock and the AI keep running while you choose.
- **RvB leave rule:** press **Esc twice** to leave your jet. It is free when you have landed and stopped;
  in the air or while rolling it counts as a death.
- **Debrief** when the time runs out: winner, kills and losses per team, every pilot's air and ground
  kills, deaths and missile hit rate, and a kill log. **Export CSV** saves it to the `results` folder.

(v0.2.0 brought more FPS, YSFlight-style wingtip lines, missile smoke trails, fire and smoke when a jet is
shot down, and the FPS readout.)

---

## How to play: step-by-step guide (no computer skills needed)

### What you need
- A **Windows 10 or Windows 11** PC (64-bit; almost every PC from the last 10 years).
- About **500 MB** of free disk space.
- An **internet connection** for the first start only (it downloads the free game engine, about 86 MB).
- Graphics: laptops with built-in Intel graphics run it fine. Mac and Linux are not supported yet.

### Step 1 - Download the game
1. On this page, click the green **`<> Code`** button (near the top right of the file list).
2. In the menu that opens, click **Download ZIP**.
3. Your browser saves a file called `ysflight-rvb-edition-main.zip`, usually in your **Downloads**
   folder.

### Step 2 - Unzip it (important: do not play from inside the ZIP)
1. Open your **Downloads** folder and find `ysflight-rvb-edition-main.zip`.
2. **Right-click** it and choose **Extract All...**, then click **Extract**.
   (On Windows 11 you may need **Show more options** first.)
3. A new folder called `ysflight-rvb-edition-main` opens. Tip: move this folder to your Desktop or
   Documents so it is easy to find. Any folder works.

> If you double-click the ZIP instead of extracting it, Windows only *shows* the files inside and the
> game cannot start. Always use **Extract All** first.

### Step 3 - Start the game
1. Open the extracted folder. Inside you will see files such as `Play.bat`, `README.md` and folders
   like `godot_project`.
2. Double-click **`Play`** (it may be shown as `Play.bat`, with a gear or window icon).
3. **"Windows protected your PC"?** This blue box appears for any new program that isn't from a big
   company. Click **More info**, then **Run anyway**. The game does not install anything on your PC.
4. **First start only:** a black window opens and says it is downloading the Godot engine and
   preparing the game files. **Wait 1-3 minutes** and do not close it. Next time the game starts in
   a few seconds.
5. The game window opens on the **main menu**. Click **LOCAL**, set up your event (or keep the last
   one) and click **FLY**. In the spawn menu pick your aircraft and click **FLY** again.

Keep the black window open while you play (it closes by itself when you quit the game).
To **quit**, close the game window (or press Alt+F4).

### Step 4 - Your first flight
- **Steer with the mouse:** the mouse works like a control stick. The centre of the screen is
  "stick centred"; move the mouse away from the centre to pitch and roll. Press **O** to re-centre.
- **Speed:** **Q** / **A** for more / less throttle, **Tab** for afterburner (extra speed).
- **Shoot:** **Left mouse** = gun, **Right mouse** (or **Space**) = missile. **2** switches weapons,
  **4** drops flares to fool enemy missiles.
- **Views:** **F1** = cockpit (with the HUD), **F2** = outside view. Hold **U H K M J N** to look around.
- **Shot down?** The spawn menu opens after 3 seconds; pick a jet and fly again.
- **Leave your jet:** press **Esc** twice (costs a death unless you have landed and stopped).
- **Settings** (controls, sensitivity, graphics): **SETTINGS** on the main menu or in the spawn menu.
  Events never pause.
- **End early:** **END EVENT** in the spawn menu (click twice to confirm).

Prefer a gamepad or joystick? Just plug it in before starting; it is detected when you move it.
Full key list: see [Controls](#controls-ysflight-defaults) below.

### If the game runs slowly
- The number in the **top-right corner** is your frame rate (FPS). 60 or more is smooth.
- Open **Settings** and in the **Graphics** section set **Graphics Preset** to **Low**. This lowers the
  3D resolution a little and switches the heavier effects off.
- Or keep **Medium** and untick single effects in the same section: **Aircraft Shadows**, **Cloud
  Shadows**, **Water Shine**, **Afterburner Heat Haze**, **Sun & Explosion Glare**.
- On laptops: plug in the charger and set Windows to **Best performance** (battery icon).
- The FPS readout can be hidden in **Settings > HUD > Show FPS / Latency**.

### Other ways to start
- **`Spectate_AI`**: the computer flies your jet while you watch. **F1-F8** switch cameras, drag with
  the mouse to look around, mouse wheel to zoom. **F6** follows other aircraft: **Tab** or **[ ]** picks
  the next one.
- **`Benchmark`**: a 2-minute automatic performance test (silent, don't touch anything). At the end
  a window shows the results; please send us a screenshot of it.

### Updating to a new version
Download the new ZIP and extract it into a **new** folder (you can delete the old folder). Your control
settings are kept, because they are stored in Windows, not in the game folder.

### Uninstalling
Just delete the game folder. Nothing else was installed. (Your settings file is in
`%APPDATA%\Godot\app_userdata\YSFlight Godot Port`, which you can delete too.)

### Troubleshooting
| Problem | What to do |
|---|---|
| "Windows protected your PC" | Click **More info**, then **Run anyway**. |
| The black window closes immediately / "Download failed" | Your internet or firewall blocked the engine download. Download `Godot_v4.7.2-stable_win64.exe.zip` from https://godotengine.org/download/archive/ (4.7.2-stable, Windows 64-bit), right-click > **Extract All** into a folder named **`engine`** inside the game folder, then start `Play` again. |
| Antivirus deletes or blocks `Play.bat` | It is a plain text script (right-click > Edit to read it). Allow it in your antivirus, or add the game folder as an exception. |
| Nothing happens / the game can't find files | Make sure you used **Extract All** (Step 2) and are not running it from inside the ZIP. Very long folder paths can also cause trouble: move the folder to e.g. `C:\Games\`. |
| No sound | Check that Windows sound isn't muted and the right output device is selected, then restart the game. |
| The mouse stick drifts | Press **O** to re-centre, or change the stick device / dead zone in **Settings > Stick Device / Mouse**. |
| Low FPS | See [If the game runs slowly](#if-the-game-runs-slowly). |
| The game crashed | Please report it (below) and include `crashlog\latest_run.txt` from the game folder. |

---

## Controls (YSFlight defaults)

| | |
|---|---|
| Stick | Mouse (default) or arrow keys; gamepad left stick; joystick |
| Throttle | Q / A, W = full, S = idle, mouse wheel |
| Afterburner | Tab |
| Rudder | Z / X (centre) / C |
| Fire weapon / gun | Space or right mouse / Ctrl or left mouse |
| Change weapon / flare | 2 or middle mouse / 4 |
| Direct weapon select | 5 gun, 6 short-range, 7 medium-range, 8 air-to-ground, 0 bombs / rockets |
| HUD colour | 9 |
| Gear / flaps / brake / spoiler | G / F and R / B / D |
| Views | F1 cockpit, F2 outside |
| Look around | U H K M J N |
| Radar range | 3 |
| Recentre mouse stick | O |
| Settings (controls, curves, graphics) | Esc |
| Flight setup / respawn | F10 |
| Debug text | F11 |
| Pause | P |

You respawn automatically 5 seconds after being shot down. All keys can be changed in **Esc**.

## Reporting problems

Tell us what you did and what happened, what PC you have (laptop/desktop, graphics), and attach the file
`crashlog\latest_run.txt` (created in the game folder, next to `Play.bat`). It helps us a lot.

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

The game code is in `godot_project/` (GDScript, organised in `camera/`, `controls/`, `fx/`, `audio/`,
`ui/`, `core/`, `tests/`, shaders in `shaders/`) and `gdextension/ysflight/src/` (the C++ bridge to the
YSFlight simulation, organised in `core/`, `render/`, `sim/`, `bridge/`). A pre-built bridge
(`godot_project/bin/*.dll`) is included, so you only need to rebuild it if you change the C++: install
Python + SCons + Visual Studio 2022 C++ tools, then run
`python -m SCons platform=windows target=template_debug` in `gdextension/ysflight`. The build also needs
the full YSCE sources (https://github.com/YSCEDC/YSCE) and godot-cpp; `ysce/` here holds only the files
changed for the RvB Edition (including the tactical AI in `ysce/src/autopilot/fsrvb*`).

Automated test (plays the mission with scripted inputs and checks every system, with screenshots):
`python tools/run_tests.py`. Please run it before sending changes.
