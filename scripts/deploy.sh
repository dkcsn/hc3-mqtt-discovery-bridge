#!/usr/bin/env bash
set -euo pipefail

# Safe deployment wrapper. updateQA uses PLua's `nq` flag so the source
# headers cannot overwrite broker credentials or operator configuration.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_PLUA=/Users/dkcsn/Documents/PLUA/.venv313/bin/plua
ACTION=${1:-update}
if [[ -z ${PLUA_BIN:-} ]]; then
  if command -v plua >/dev/null 2>&1; then PLUA_BIN=$(command -v plua)
  elif [[ -x $LOCAL_PLUA ]]; then PLUA_BIN=$LOCAL_PLUA
  else printf '%s\n' "PLua not found. Set PLUA_BIN or install plua 1.3.16." >&2; exit 1
  fi
fi
PLUA_HOME=${PLUA_HOME:-${HOME}}
cd "$PROJECT_DIR"

case "$ACTION" in
  update) env HOME="$PLUA_HOME" "$PLUA_BIN" --tool updateQA main.lua nq ;;
  upload) env HOME="$PLUA_HOME" "$PLUA_BIN" --tool uploadQA main.lua ;;
  diagnostic) env HOME="$PLUA_HOME" "$PLUA_BIN" --diagnostic ;;
  *) printf '%s\n' "Usage: scripts/deploy.sh {update|upload|diagnostic}" >&2; exit 2 ;;
esac
