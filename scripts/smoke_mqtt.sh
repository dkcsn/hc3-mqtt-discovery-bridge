#!/usr/bin/env bash
set -euo pipefail

# Run after a broker and the mosquitto client tools are installed. The test
# publishes a retained discovery record plus state and always removes the
# retained record on exit. It never reads HC3 or broker credentials from Git.
: ${MQTT_HOST:?Set MQTT_HOST to the broker hostname or IP}
MQTT_PORT=${MQTT_PORT:-1883}
DISCOVERY_PREFIX=${DISCOVERY_PREFIX:-homeassistant}
SMOKE_ID=${SMOKE_ID:-hc3_bridge_smoke}

for tool in mosquitto_pub mosquitto_sub; do
  command -v "$tool" >/dev/null 2>&1 || { printf '%s\n' "$tool is required" >&2; exit 1; }
done

MQTT_ARGS=(-h "$MQTT_HOST" -p "$MQTT_PORT")
[[ -n ${MQTT_USERNAME:-} ]] && MQTT_ARGS+=(-u "$MQTT_USERNAME")
[[ -n ${MQTT_PASSWORD:-} ]] && MQTT_ARGS+=(-P "$MQTT_PASSWORD")
[[ ${MQTT_TLS:-false} == true ]] && MQTT_ARGS+=(--capath /etc/ssl/certs)

CONFIG_TOPIC="$DISCOVERY_PREFIX/switch/$SMOKE_ID/config"
STATE_TOPIC="codex-smoke/$SMOKE_ID/state"
COMMAND_TOPIC="codex-smoke/$SMOKE_ID/set"
PAYLOAD='{"name":"HC3 MQTT Bridge Smoke Test","unique_id":"'"$SMOKE_ID"'","state_topic":"'"$STATE_TOPIC"'","command_topic":"'"$COMMAND_TOPIC"'","payload_on":"ON","payload_off":"OFF","device":{"identifiers":["'"$SMOKE_ID"'"],"name":"Bridge Smoke Test"},"origin":{"name":"HC3 bridge smoke script","sw_version":"0.3.0"}}'

cleanup() { mosquitto_pub "${MQTT_ARGS[@]}" -r -t "$CONFIG_TOPIC" -n >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

mosquitto_pub "${MQTT_ARGS[@]}" -r -t "$CONFIG_TOPIC" -m "$PAYLOAD"
mosquitto_pub "${MQTT_ARGS[@]}" -r -t "$STATE_TOPIC" -m "OFF"
printf 'Published retained smoke entity: %s\n' "$SMOKE_ID"
printf '%s\n' "Approve it in the QA if discoveryMode=approval, toggle its HC3 child, then verify the command below."
printf '%s\n' "Listening for one command for 60 seconds..."
if command_payload=$(mosquitto_sub "${MQTT_ARGS[@]}" -C 1 -W 60 -t "$COMMAND_TOPIC"); then
  printf 'Received command: %s\n' "$command_payload"
else
  printf '%s\n' "No command received within 60 seconds. Discovery/state publication still completed." >&2
  exit 1
fi
