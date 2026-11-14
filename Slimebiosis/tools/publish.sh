#!/usr/bin/env bash
# Build and publish the server module, then regenerate the Godot bindings.
# Usage: tools/publish.sh [server_nickname] [server_url] [database]
#   tools/publish.sh                          local dev server
#   tools/publish.sh maincloud "" <db-name>   SpacetimeDB Maincloud (needs `spacetime login`)
# Data is cleared only when the schema change is breaking.
set -euo pipefail
cd "$(dirname "$0")/.."
SERVER="${1:-local}"
URL="${2:-http://127.0.0.1:3000}"
DB="${3:-slimecrime}"
# The round-trip test fixture (type_probe table, probe reducer) is only built
# into local publishes; it must not exist on a public server.
if [ "$SERVER" = "local" ]; then
	export RUSTFLAGS="${RUSTFLAGS:-} --cfg test_fixture"
fi
spacetime publish -s "$SERVER" -p server --yes --delete-data=on-conflict "$DB"
# Bindings are always generated from the local schema (a superset that includes
# the test fixture), so publishing elsewhere leaves them untouched.
if [ "$SERVER" = "local" ]; then
	tools/gen_bindings.sh "$URL" "$DB"
fi
