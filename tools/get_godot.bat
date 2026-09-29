@echo off
rem First-start setup, called by Play.bat / Spectate_AI.bat / Benchmark.bat:
rem 1) downloads the official Godot 4.7.2 runtime (~86 MB, godotengine GitHub releases) into .\engine
rem 2) runs Godot's one-time asset import for the game folder
setlocal
set "ROOT=%~dp0.."
set "ENGINE=%ROOT%\engine"
if exist "%ENGINE%\Godot_v4.7.2-stable_win64.exe" goto :import
echo First start: downloading the Godot 4.7.2 engine (about 86 MB). This happens only once...
if not exist "%ENGINE%" mkdir "%ENGINE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri 'https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip' -OutFile '%ENGINE%\godot.zip'; Expand-Archive -Path '%ENGINE%\godot.zip' -DestinationPath '%ENGINE%' -Force; Remove-Item '%ENGINE%\godot.zip'"
if not exist "%ENGINE%\Godot_v4.7.2-stable_win64.exe" (
  echo Download failed. Get Godot_v4.7.2-stable_win64.exe.zip from https://godotengine.org/download/archive/
  echo and unzip it into the "engine" folder next to Play.bat, then run Play.bat again.
  exit /b 1
)
:import
if exist "%ROOT%\godot_project\.godot\imported" exit /b 0
echo Preparing game files (one time, about a minute)...
"%ENGINE%\Godot_v4.7.2-stable_win64_console.exe" --headless --path "%ROOT%\godot_project" --import >nul 2>nul
exit /b 0
