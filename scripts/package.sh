#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_PLUA=/Users/dkcsn/Documents/PLUA/.venv313/bin/plua
if [[ -z ${PLUA_BIN:-} ]]; then
  if command -v plua >/dev/null 2>&1; then PLUA_BIN=$(command -v plua)
  elif [[ -x $LOCAL_PLUA ]]; then PLUA_BIN=$LOCAL_PLUA
  else printf '%s\n' "PLua not found. Set PLUA_BIN or install plua 1.3.16." >&2; exit 1
  fi
fi
PLUA_HOME=${PLUA_HOME:-${HOME}}
RELEASE_VERSION=$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")
OUTPUT_FILE="$PROJECT_DIR/dist/HC3-MQTT-Discovery-Bridge-$RELEASE_VERSION.fqa"

mkdir -p "$PROJECT_DIR/dist"
cd "$PROJECT_DIR"
env HOME="$PLUA_HOME" "$PLUA_BIN" --fibaro --offline --tool pack main.lua "$OUTPUT_FILE"
printf 'Created %s\n' "$OUTPUT_FILE"
