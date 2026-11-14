#!/usr/bin/env bash
# Runs all headless tests. The network tests need a local server
# (`spacetime start`) with the module published (`tools/publish.sh`).
cd "$(dirname "$0")/.."
fail=0
for t in movement roundtrip sync grab; do
	out="$(timeout 300 godot --headless --path . --fixed-fps 60 "res://tests/${t}_test.tscn" 2>&1 | grep -v "Unicode parsing error")"
	if echo "$out" | grep -q "${t}_test: PASSED"; then
		echo "PASS ${t}"
	else
		echo "FAIL ${t}"
		echo "$out" | tail -20
		fail=1
	fi
done
tools/test_reconnect.sh || fail=1
exit $fail
