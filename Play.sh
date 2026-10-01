#!/usr/bin/env bash
# YSFlight RvB Edition - start the game (16v16 on Luavi, you fly the F-16).

ROOT="$(cd "$(dirname "$0")" && pwd)"

if ! GODOT_BIN="$( "$ROOT/tools/get_godot.sh" )"; then
    read -r -p "Press Enter to continue..."
    exit 1
fi

"$GODOT_BIN" --path "$ROOT/godot_project"
