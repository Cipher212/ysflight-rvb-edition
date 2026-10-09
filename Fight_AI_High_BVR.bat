@echo off
rem Current unified RvB AI: 30 km head-on, missiles and guns.
rem Human Mirage 2000 vs AI F-16; 15-minute limit; one recording per fight.
call "%~dp0tools\start_ai_duel.bat" HIGH bvr
exit /b %errorlevel%
