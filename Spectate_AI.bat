@echo off
rem Watch the 16v16 with the AI flying your jet. F1-F8 switch cameras.
call "%~dp0tools\get_godot.bat" || (pause & exit /b 1)
start "" "%~dp0engine\Godot_v4.7.2-stable_win64.exe" --path "%~dp0godot_project" -- --ai-player
