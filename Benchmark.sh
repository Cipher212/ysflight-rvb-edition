#!/usr/bin/env bash
# 2-minute performance benchmark (muted). Results: crashlog/bench/. Report needs Python.

ROOT="$(cd "$(dirname "$0")" && pwd)"

if ! GODOT_BIN="$( "$ROOT/tools/get_godot.sh" )"; then
    read -r -p "Press Enter to continue..."
    exit 1
fi

"$GODOT_BIN" --path "$ROOT/godot_project" -- --benchmark "$@"

if command -v python3 >/dev/null 2>&1; then
    python3 "$ROOT/tools/bench_report.py"
elif command -v python >/dev/null 2>&1; then
    python "$ROOT/tools/bench_report.py"
fi

read -r -p "Press Enter to continue..."
