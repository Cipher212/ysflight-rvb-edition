@echo off
setlocal
rem All owner duels load the current project DLL and the unified RvB controller.
set "ROOT=%~dp0.."
set "PRESET=%~1"
set "MODE=%~2"
set "HIGH="
if /I "%PRESET%"=="HIGH" set "HIGH=--combat-high"
if /I not "%PRESET%"=="HIGH" if /I not "%PRESET%"=="MEDIUM" exit /b 2
set "MISSION="
if /I "%MODE%"=="guns" set "MISSION=combat_human_rebuilt"
if /I "%MODE%"=="short" set "MISSION=combat_human_short"
if /I "%MODE%"=="bvr" set "MISSION=combat_human_bvr"
if not defined MISSION exit /b 2
if not exist "%ROOT%\godot_project\bin\ysflight_godot.windows.template_debug.x86_64.dll" (
  echo The current AI DLL is missing. Restore or rebuild the game before launching.
  pause
  exit /b 1
)
call "%~dp0get_godot.bat" || (pause & exit /b 1)
echo Starting 1v1 %MODE% against the current RvB AI, %PRESET% preset.
echo You fly the Mirage 2000; the bot flies an F-16. Respawns are disabled.
echo Fight recordings: %ROOT%\crashlog\combat_fight\%PRESET%_%MODE%
start "RvB 1v1 %PRESET% %MODE%" "%ROOT%\engine\Godot_v4.7.2-stable_win64.exe" --path "%ROOT%\godot_project" -- --mission res://mission/%MISSION%.yfs --ai-combat-human %HIGH% --combat-out "%ROOT%\crashlog\combat_fight\%PRESET%_%MODE%" --combat-out-stamp --combat-limit 900 --no-ai-respawn
exit /b 0
