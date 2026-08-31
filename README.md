# HC3 MQTT Discovery Bridge

Current release: **0.3.0**. The canonical release number is stored in [`VERSION`](VERSION), mirrored by `Constants.VERSION`, checked by the test suite and exposed as HC3 device metadata at runtime.

> **License:** Noncommercial use only under [PolyForm Noncommercial 1.0.0](LICENSE.md). Commercial use requires a separate written license from the licensor.

Native FIBARO Home Center 3 QuickApp that consumes Home Assistant-compatible MQTT Discovery from an external broker and creates HC3 child devices. Home Assistant itself is not required; its MQTT Discovery protocol is the compatibility layer.

```text
MQTT devices
     │
     ▼
External MQTT broker
     │
     ▼
HC3 MQTT Discovery Bridge
     ├── discovery parser and normalizer
     ├── safe MQTT-template interpreter
     ├── shared subscription registry
     ├── entity adapters
     └── native HC3 child devices
```

## Current scope

Version 0.3.0 implements a production-oriented bridge with scalable approval and durable storage:

- MQTT connect, reconnect with bounded exponential backoff and jitter, disconnect, subscribe, unsubscribe and publish;
- component discovery and Device Discovery, both legal discovery topic shapes;
- the full Home Assistant Core discovery abbreviation table as of 2026-08-31;
- `~` base-topic expansion, shared state topics, availability, discovery updates and empty-payload removal;
- unique-ID-first reconciliation and compact, chunked, integrity-checked persistence across QuickApp restarts;
- safe parsed templates: expressions, JSON paths, filters, operators, tests, inline conditionals and `if/elif/else` blocks;
- HC3 children for `sensor`, `binary_sensor`, `switch`, `light`, `cover`, `button`, `number`, `select`, `device_tracker`, `siren` and `fan`;
- compact parent UI, scene-callable API, metrics and log suppression for repeated template errors.
- optional approval mode with device/entity filters, pagination, bulk approval, reversible disable and guarded child/orphan cleanup;
- automatic upload and stable reuse of the bundled 128 × 128 parent icon.

An external MQTT broker such as Mosquitto, EMQX or HiveMQ is required. The QuickApp is an MQTT client, not a broker.

## Install with PLua

Use PLua 1.3.16 on Python 3.13. The scripts first use `PLUA_BIN`, then a `plua` command on `PATH`, and finally the known local `.venv313` installation. Do not commit `.env`, `.project` or broker/HC3 credentials.

```bash
PLUA_BIN=/Users/dkcsn/Documents/PLUA/.venv313/bin/plua PLUA_HOME=/Users/dkcsn scripts/package.sh
PLUA_BIN=/Users/dkcsn/Documents/PLUA/.venv313/bin/plua PLUA_HOME=/Users/dkcsn scripts/deploy.sh upload
```

After the initial upload, copy `.project.example` to `.project` and enter the returned HC3 device ID. Use `scripts/deploy.sh update` for later full updates. Its `nq` safeguard preserves live QuickApp variables such as broker credentials and approval settings.

The parent uses `com.fibaro.deviceController`. Do not replace it with the abstract
`com.fibaro.device` base type: HC3 accepts and runs such an upload, but does not
list it as a normal device in the web GUI.

## QuickApp variables

| Variable | Default | Purpose |
|---|---:|---|
| `brokerHost` | empty | Broker hostname or IP. Required. |
| `brokerPort` | `1883` | Broker TCP port. |
| `username` | empty | MQTT username. Never logged. |
| `password` | empty | MQTT password. Never logged. |
| `tls` | `false` | Use `mqtts://`. |
| `clientId` | `hc3-mqtt-discovery` | Must be unique on the broker. |
| `discoveryPrefix` | `homeassistant` | HA discovery prefix. |
| `discoveryQoS` | `0` | QoS for discovery subscriptions. |
| `publishHABirth` | `true` | Publish `<prefix>/status = online` after subscribing. |
| `logLevel` | `INFO` | `ERROR`, `WARNING`, `INFO`, `DEBUG` or `TRACE`. |
| `discoveryMode` | `automatic` | `automatic` creates supported children immediately; `approval` keeps new entities pending. |
| `approvalPageSize` | `40` | Entities per second-level dropdown page; clamped to 10–100. |
| `birthDelayMax` | `5` | Random maximum delay in seconds before publishing HA Birth, reducing reconnect storms. |

`mqttEntityRegistry` is a legacy migration variable. Version 0.3 stores a compact schema-3 registry in hidden HC3 internal-storage chunks with an integrity manifest and alternating generations. Do not edit either storage form manually.

## First connection

1. Import the generated `.fqa` or upload `main.lua` with PLua.
2. Set broker host, port and optional credentials in QuickApp variables.
3. Enable TLS only when the broker listener supports it.
4. Restart or press **Reconnect**.
5. Wait for retained discovery configurations.
6. In approval mode, choose an MQTT device and entity, then press **Create selected** or **Create all from device**.
7. Press **Request Discovery** if publishers listen for the HA Birth topic.
8. Verify that children appear and update.

The approval controls distinguish reversible disable from cleanup. **Disable selected** keeps the HC3 child but stops MQTT updates. **Delete from HC3** requires two clicks within ten seconds, removes the child and keeps the discovery record disabled so retained MQTT discovery cannot recreate it immediately. **Clean orphans** removes only HC3 children whose discovery identity no longer exists and also requires confirmation.

Publishing the HA Birth message on a broker shared with Home Assistant may cause publishers to resend discovery configurations. This is expected.

## Parent API

Scenes and other QuickApps can call `getEntity(externalId)`, `getEntities()`, `getStatus()`, `setEntityApproval(externalId, state)`, `approveDevice(deviceKey)`, `deleteEntityChild(externalId)`, `requestDiscovery()`, `reconnect()`, `publish(topic, payload, retain, qos)` and `sendCommand(externalId, action, value)`. Returned registry data is copied so callers cannot mutate live state accidentally.

## Icon

`assets/mqtt-discovery-source.png` preserves the supplied 1254 × 1254 source. `assets/mqtt-discovery-128.png` is the verified 128 × 128 HC3 upload asset. `IconData.lua` embeds the same PNG bytes in the FQA; `IconInstaller.lua` uploads them once and `IconRegistry.lua` stores HC3's assigned numeric ID in the shared `IconQaRegistry` global variable.

## Troubleshooting

**Connected but no devices:** verify `discoveryPrefix`, retained config messages, broker ACLs and whether publishers respond to `<prefix>/status`. Subscribe externally to `<prefix>/#` to confirm the broker actually has discovery traffic.

**Children but no state:** check `state_topic`, actual payload, `value_template` and the active-subscription count in **Debug Summary**. Set `logLevel=DEBUG` temporarily.

**Commands do not work:** verify `command_topic`, custom on/off payloads, command template, QoS, retain flag and broker write ACL.

**Template warning:** compare the template with [docs/TEMPLATE_ENGINE.md](docs/TEMPLATE_ENGINE.md). Home Assistant registry functions such as `states()` are intentionally unavailable.

New to templates? Start with [Jinja templates for beginners](docs/JINJA_FOR_BEGINNERS.md). See also [architecture](docs/ARCHITECTURE.md), [discovery semantics](docs/MQTT_DISCOVERY.md), the exact [template compatibility table](docs/TEMPLATE_ENGINE.md) and the [component compatibility matrix](docs/COMPATIBILITY.md).

## Tests

```bash
env HOME=/Users/dkcsn /Users/dkcsn/Documents/PLUA/.venv313/bin/plua tests/run_all.lua
```

When an MQTT broker is available, install the Mosquitto client tools and run the deferred end-to-end smoke test:

```bash
MQTT_HOST=192.168.1.10 scripts/smoke_mqtt.sh
```

Optional `MQTT_PORT`, `MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_TLS`, `DISCOVERY_PREFIX` and `SMOKE_ID` environment variables are supported. The script removes its retained discovery record on exit.

The production QuickApp has no dependency on Python, PLua, Docker or external Lua libraries after it is installed on HC3.

## Release workflow

1. Update `VERSION`, `Constants.VERSION`, the `main.lua` description and `CHANGELOG.md`.
2. Run `tests/run_all.lua`; its first test rejects inconsistent versions.
3. Run `scripts/package.sh` to create the versioned FQA in `dist/`.
4. Generate `SHA256SUMS`, then commit source, documentation, icon assets and the matching FQA together.
5. Tag and publish a GitHub release with the `.fqa` and checksum file.
