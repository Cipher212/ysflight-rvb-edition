@echo off
rem Current unified RvB AI: 8 km head-on, guns only.
rem Human Mirage 2000 vs AI F-16; 15-minute limit; one recording per fight.
call "%~dp0tools\start_ai_duel.bat" HIGH guns
exit /b %errorlevel%
