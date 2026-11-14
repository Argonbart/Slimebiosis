#!/usr/bin/env bash
# Runs the connection-loss test against a private, throwaway server on port 3111.
# Does not touch the development server or its data.
cd "$(dirname "$0")/.."
DATA="$(mktemp -d)"
cleanup() {
	[ -f "$DATA/spacetime.pid" ] && kill "$(cat "$DATA/spacetime.pid")" 2>/dev/null
	rm -rf "$DATA"
}
trap cleanup EXIT
out="$(timeout 300 godot --headless --path . res://tests/reconnect_test.tscn -- --data-dir="$DATA" 2>&1 | grep -v "Unicode parsing error")"
if echo "$out" | grep -q "reconnect_test: PASSED"; then
	echo "PASS reconnect"
else
	echo "FAIL reconnect"
	echo "$out" | tail -25
	exit 1
fi
