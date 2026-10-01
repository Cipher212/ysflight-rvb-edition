#!/usr/bin/env bash
# Watch the 16v16 with the AI flying your jet. F1-F8 switch cameras.

ROOT="$(cd "$(dirname "$0")" && pwd)"

if ! GODOT_BIN="$( "$ROOT/tools/get_godot.sh" )"; then
    read -r -p "Press Enter to continue..."
    exit 1
fi

"$GODOT_BIN" --path "$ROOT/godot_project" -- --ai-player
