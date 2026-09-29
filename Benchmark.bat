@echo off
rem 2-minute performance benchmark (muted). Results: crashlog\bench\. Report needs Python.
call "%~dp0tools\get_godot.bat" || (pause & exit /b 1)
"%~dp0engine\Godot_v4.7.2-stable_win64_console.exe" --path "%~dp0godot_project" -- --benchmark %*
where python >nul 2>nul && python "%~dp0tools\bench_report.py"
pause
