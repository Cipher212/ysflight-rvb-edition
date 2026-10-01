#!/usr/bin/env bash
# First-start setup, called by Play.sh / Spectate_AI.sh / Benchmark.sh:
# 1) downloads the official Godot 4.7.2 runtime (~60 MB, godotengine GitHub releases) into ./engine
# 2) runs Godot's one-time asset import for the game folder
#
# Prints the engine binary path to stdout on success (status messages go to stderr).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine"

# Prefer a Godot already on PATH, otherwise use (or fetch) the pinned build.
if command -v godot >/dev/null 2>&1; then
    GODOT_BIN="$(command -v godot)"
else
    GODOT_BIN="$ENGINE/Godot_v4.7.2-stable_linux.x86_64"
    if [ ! -x "$GODOT_BIN" ]; then
        echo "First start: downloading the Godot 4.7.2 engine (about 60 MB). This happens only once..." >&2
        mkdir -p "$ENGINE"
        if ! curl -L --fail -o "$ENGINE/godot.zip" \
            "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip"; then
            echo "Download failed. Get Godot_v4.7.2-stable_linux.x86_64.zip from https://godotengine.org/download/archive/" >&2
            echo "and unzip it into the \"engine\" folder next to Play.sh, then run Play.sh again." >&2
            exit 1
        fi
        unzip -o "$ENGINE/godot.zip" -d "$ENGINE" >/dev/null
        rm -f "$ENGINE/godot.zip"
    fi
    if [ ! -x "$GODOT_BIN" ]; then
        echo "Download failed. Get Godot_v4.7.2-stable_linux.x86_64.zip from https://godotengine.org/download/archive/" >&2
        echo "and unzip it into the \"engine\" folder next to Play.sh, then run Play.sh again." >&2
        exit 1
    fi
fi

# One-time asset import.
if [ ! -d "$ROOT/godot_project/.godot/imported" ]; then
    echo "Preparing game files (one time, about a minute)..." >&2
    "$GODOT_BIN" --headless --path "$ROOT/godot_project" --import >/dev/null 2>&1
fi

printf '%s\n' "$GODOT_BIN"
