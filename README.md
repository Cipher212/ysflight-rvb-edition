# YSFlight RvB Edition - v0.5.0-pre-alpha

YSFlight's flight simulation (YSFlight Community Edition) running inside the Godot 4 engine, built for
the RvB (Red vs Blue) community events. **This is a pre-alpha test build**: expect bugs and missing
features. You can set up and fly offline RvB events against the AI on the Luavi map, or use Free Flight.

**New in v0.5.0 — 9 October 2026:**
- Pre-flight lobby for offline events and Free Flight: choose your team, view the roster, use local chat,
  enter the hangar or spectate your team. Team choice locks when you enter the hangar or spectate.
- Offline 8v8 / 16v16 setup: you replace one AI pilot on your chosen team. A 30-second countdown begins
  on first entering the hangar or spectating; aircraft can be placed before combat starts.
- Separate 3D hangar using Luavi scenery, parked aircraft and a slowly orbiting camera. The world keeps
  the same size for fighters and heavies; only the camera framing changes.
- Per-hardpoint weapon selection with symmetric loading, adjustable fuel, team-specific starts and saved
  loadout presets. Selecting a station or weapon smoothly brings the camera to that hardpoint.
- Aircraft selection grouped into Gunner, Multirole, Attacker, Stealth, Heavy and CAS. Defunct BVR-tagged
  aircraft and UCAVs are hidden from player selection.
- Throttle now takes 2.4 seconds to move between idle and full power; engine audio follows actual power.
- Updated F-16 cockpit model, physical glass HUD and working MFD placement on the tilted instrument panel.
- Unified combat AI with shared radar detections, threat assessment, revised ground-attack survival and recovery.
- Close-combat turns use available aircraft lift up to a 10.9 G command, manoeuvre flaps and speed management.
  Turning is tighter in scripted checks; overall combat effectiveness remains under playtesting.
- Added HIGH guns, short-range and BVR 1v1 launchers (`Fight_AI_High_*.bat`) for testing against the AI.
- Floating render origin for distant-flight precision, spectator camera updates and display/control improvements.
- GitHub downloads contain the playable runtime and assets; development/build folders and private research are omitted.

**New in v0.4.0:**
- **Home Screen Atmosphere:** Procedural wireframe terrain flyby, authentic 2D vector jet passes, dogfights, afterburner trails, intro merge with sonic boom shockwave, and tactical HUD heading tape inspired by the RvB website.
- **Dynamic Low-Poly Clouds:** Atmospheric cumulus cloud banks drifting across the sky between 3500–5400 ft with wind shear, distance fading, and active camera immersion fog.
- **Restrained Gradient Sky & Day/Night Atmosphere:** Realistic time-of-day sky transitions coordinated with lighting, shadows, and environment colors.
- **PS2-Style Incident Explosions & Water Splashes:** Classified explosion sprites and dynamic low-poly water-splash crowns for crashes and ordnance impacts.
- **Luavi Runway Extensions & AI Arrivals:** Extended six Luavi runways by 200 m with refined holding patterns, approach glide slopes, and landing rollouts for smooth AI operations.
- **Unique Aircraft Catalog:** Fixed duplicate aircraft template listings across menus and roster builder.
- **Free Flight** (main menu): just you on the map, no enemies (the map's SAM sites and ships hold fire). Pick
  any aircraft and start; **Esc** pauses and opens the menu.
- **Every menu in the RvB style:** a new Settings window with tabs, a loading screen, an Online page
  (placeholder), and all menus scale to any window size.
- **Shot-down jets** burn with a fireball over the airframe and leave one continuous plume of fire turning
  into thick black smoke; flat debris shards tumble off at the kill (the old "string of pearls" smoke and
  spark streaks are gone).
- **Ground Detail:** fine flecks on grass and fields give a sense of speed and height when flying low
  (Settings > Graphics > Ground Detail).
- **Water sparkle** now covers the sea around you with no hard edge or streaks at a distance.
- **All Camera Views** option (Settings > Display): F3-F8 cameras in normal play. Off by default, as RvB is
  flown with F1 / F2.
- Speed lines removed.

**v0.3.0 brought:** offline RvB events (event builder, up to 18 vs 18 AI with role-based tactics, spawn menu,
the RvB leave rule, debrief with CSV export), afterburner flames and the new look (sky, sea, colour grade,
cloud shadows, aircraft shadows, glare). v0.2.0 brought more FPS, wingtip lines, missile smoke trails and
the FPS readout.

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
5. The game opens on the **main menu**. Click **LOCAL**, choose **8 vs 8** or **16 vs 16**, set up your
   event (or keep the last one), then click **FLY**. Choose your team in the lobby and select
   **ENTER HANGAR**. Pick an aircraft, weapons, fuel and start position, then select **FLY NOW**.
   **FREE FLIGHT** uses the same lobby and hangar without enemy aircraft.

In the hangar, drag to orbit, use the mouse wheel to zoom, and hold Shift while dragging to change
camera height. Double-click the preview to return to the overview. Select a hardpoint in the list
to inspect its weapon choices. Your team locks when you first enter the hangar or spectate.

Keep the black window open while you play (it closes by itself when you quit the game).
To **quit**, close the game window (or press Alt+F4).

### Step 4 - Your first flight
- **Steer with the mouse:** the mouse works like a control stick. The centre of the screen is
  "stick centred"; move the mouse away from the centre to pitch and roll. Press **O** to re-centre.
- **Speed:** **Q** / **A** for more / less throttle, **Tab** for afterburner (extra speed).
- **Shoot:** **Left mouse** = gun, **Right mouse** (or **Space**) = missile. **2** switches weapons,
  **4** drops flares to fool enemy missiles.
- **Views:** **F1** = cockpit (with the HUD), **F2** = outside view. Hold **U H K M J N** to look around.
  RvB is flown with these two; for the other cameras (**F3-F8**, **[ ]** picks the aircraft in F6), turn on
  **Settings > Display > All Camera Views**.
- **Shot down?** Aircraft selection opens after 3 seconds; pick a jet and fly again.
- **Leave your jet:** press **Esc** twice (costs a death unless you have landed and stopped).
- **Settings** (controls, sensitivity, graphics): **SETTINGS** on the main menu or in the lobby/hangar.
  Events never pause.
- **End early:** **END EVENT** in the lobby (click twice to confirm).

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
  - **F1** after picking an aircraft with **Tab** puts you in *its* cockpit (**Tab** / **[ ]** jump to the
    next aircraft's cockpit, **F2** goes back to your own jet, **F6** back to orbiting it).
  - **F11** is the free **ghost camera**: fly it like a plane with the mouse (or joystick / arrow keys,
    **Q** / **E** to yaw). Hold **Space** to move forward, **Backspace** to move back, **+** / **-** (or
    Page Up / Page Down) for faster / slower. **Settings > Display > Ghost Cam Smoothing** sets how gently
    it speeds up, slows down and turns (0 = instant).
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
| Views | F1 cockpit, F2 outside (F3-F8 with Settings > Display > All Camera Views) |
| Look around | U H K M J N |
| Radar range | 3 |
| Recentre mouse stick | O |
| Settings (controls, curves, graphics) | Esc |
| Flight setup / respawn | F10 |
| Debug text | F11 |
| Pause | P |

Offline events and Free Flight return to aircraft selection after a loss. The standalone classic
test/spectator modes retain automatic respawn. All keys can be changed in **SETTINGS**.

## Reporting problems

Tell us what you did and what happened, what PC you have (laptop/desktop, graphics), and attach the file
`crashlog\latest_run.txt` (created in the game folder, next to `Play.bat`). It helps us a lot.

## Credits

- **YSFlight** by **Soji Yamakawa (CaptainYS)** - http://www.ysflight.com, https://github.com/captainys
- **YSFlight Community Edition (YSCE)** by the **YSCE Development Committee** - https://github.com/YSCEDC/YSCE
  (simulation engine; BSD licence text included in `THIRD_PARTY_LICENSES.txt`)
- **YS WW3 / Luavi**: map and ground objects by **UltraViolet (Waspe414)**, ground objects by
  **CrazyPilot**, and the **2ch** ground-object pack by the 2ch YSFlight creators. Used with permission;
  their original credit and permission notes are kept next to the files in `godot_project/user/`.
- **Godot Engine** and **godot-cpp** (MIT licence) - https://godotengine.org
- Stock YSFlight sound effects from YSFlight / YSCE.

Full licence texts: `THIRD_PARTY_LICENSES.txt`.

## For developers

GitHub downloads contain the playable Godot project, assets and pre-built simulation bridge
(`godot_project/bin/*.dll`). Native source/build trees, private research and development tools are
kept outside this runtime distribution. The GDScript is in `godot_project/`, organised in `camera/`,
`controls/`, `fx/`, `audio/`, `ui/` and `core/`; shaders are in `shaders/`.
