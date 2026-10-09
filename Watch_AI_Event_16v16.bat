@echo off
rem RvB AI event: 16v16 over Luavi, 8 multirole + 8 attackers per team (air start over their islands), 30 minutes.
rem The rebuilt AI flies every jet; you spectate (F1-F8 switch cameras).  Regenerate the mission with
rem   python tools\make_rvb_event_mission.py
call "%~dp0tools\get_godot.bat" || (pause & exit /b 1)
start "" "%~dp0engine\Godot_v4.7.2-stable_win64.exe" --path "%~dp0godot_project" -- --ai-player --rebuilt-ai --mission res://mission/rvb_event_16v16.yfs
