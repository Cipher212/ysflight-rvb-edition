@echo off
rem YSFlight RvB Edition - start the game (16v16 on Luavi, you fly the F-16).
call "%~dp0tools\get_godot.bat" || (pause & exit /b 1)
start "" "%~dp0engine\Godot_v4.7.2-stable_win64.exe" --path "%~dp0godot_project"
