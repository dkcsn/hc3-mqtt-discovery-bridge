#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
PLUA_BIN=/Users/dkcsn/Documents/PLUA/.venv313/bin/plua
RELEASE_VERSION=$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")
OUTPUT_FILE="$PROJECT_DIR/dist/HC3-MQTT-Discovery-Bridge-$RELEASE_VERSION.fqa"

mkdir -p "$PROJECT_DIR/dist"
cd "$PROJECT_DIR"
env HOME=/Users/dkcsn "$PLUA_BIN" --fibaro --offline --tool pack main.lua "$OUTPUT_FILE"
print "Created $OUTPUT_FILE"
