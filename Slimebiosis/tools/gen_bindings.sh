#!/usr/bin/env bash
# Regenerate res://spacetime_bindings from the published module (no editor needed).
# Usage: tools/gen_bindings.sh [server_url] [database]
set -euo pipefail
cd "$(dirname "$0")/.."
URL="${1:-http://127.0.0.1:3000}"
DB="${2:-slimecrime}"
TMP="$(mktemp --suffix=.json)"
trap 'rm -f "$TMP"' EXIT
curl -sf "$URL/v1/database/$DB/schema?version=10" -o "$TMP"
LOG="$(mktemp)"
trap 'rm -f "$TMP" "$LOG"' EXIT
# The existing autoload may fail to compile here when the schema gained new
# classes (the class cache is stale until the import below), so this run's
# script errors are only shown if generation itself fails.
if ! godot --headless --path . -s tools/gen_bindings.gd -- "$TMP" >"$LOG" 2>&1; then
	cat "$LOG"
	exit 1
fi
grep "gen_bindings:" "$LOG"
# Refresh the global class cache so new generated classes resolve.
godot --headless --path . --import >/dev/null 2>&1 || true
# Verify the project now loads cleanly with the new bindings.
if godot --headless --path . -s tools/check_load.gd 2>&1 | grep -E "SCRIPT ERROR|Parse Error|Compile Error"; then
	echo "gen_bindings: project has script errors after regeneration" >&2
	exit 1
fi
echo "gen_bindings: project loads cleanly"
