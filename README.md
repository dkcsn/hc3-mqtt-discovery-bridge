# HC3 MQTT Discovery Bridge

Current release: **0.2.0**. The canonical release number is stored in [`VERSION`](VERSION), mirrored by `Constants.VERSION`, checked by the test suite and exposed as HC3 device metadata at runtime.

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

Version 0.2.0 implements the first production-oriented vertical slice plus all Tier 1 adapters:

- MQTT connect, reconnect with bounded exponential backoff and jitter, disconnect, subscribe, unsubscribe and publish;
- component discovery and Device Discovery, both legal discovery topic shapes;
- the full Home Assistant Core discovery abbreviation table as of 2026-08-31;
- `~` base-topic expansion, shared state topics, availability, discovery updates and empty-payload removal;
- unique-ID-first reconciliation and versioned persistence across QuickApp restarts;
- safe parsed templates: expressions, JSON paths, filters, operators, tests, inline conditionals and `if/elif/else` blocks;
- HC3 children for `sensor`, `binary_sensor`, `switch`, `light`, `cover`, `button`, `number` and `select`;
- compact parent UI, scene-callable API, metrics and log suppression for repeated template errors.
- optional approval mode with device/entity filters, bulk approval, reversible disable and guarded child cleanup;
- automatic upload and stable reuse of the bundled 128 × 128 parent icon.

An external MQTT broker such as Mosquitto, EMQX or HiveMQ is required. The QuickApp is an MQTT client, not a broker.

## Install with PLua

This repository is configured for the existing PLua Python 3.13 environment. Do not commit `.env`, `.project` or broker/HC3 credentials.

```bash
env HOME=/Users/dkcsn /Users/dkcsn/Documents/PLUA/.venv313/bin/plua --fibaro --offline --run-for 10 main.lua
env HOME=/Users/dkcsn /Users/dkcsn/Documents/PLUA/.venv313/bin/plua --fibaro --offline --tool pack main.lua HC3-MQTT-Discovery-Bridge.fqa
env HOME=/Users/dkcsn /Users/dkcsn/Documents/PLUA/.venv313/bin/plua --tool uploadQA main.lua
```

After the initial upload, copy `.project.example` to `.project`, enter the HC3 device ID returned by the upload, and use `updateQA` for later full updates. `updateFile` is useful for a single source file.

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

`mqttEntityRegistry` is managed internally. Editing it manually can prevent restoration.

## First connection

1. Import the generated `.fqa` or upload `main.lua` with PLua.
2. Set broker host, port and optional credentials in QuickApp variables.
3. Enable TLS only when the broker listener supports it.
4. Restart or press **Reconnect**.
5. Wait for retained discovery configurations.
6. In approval mode, choose an MQTT device and entity, then press **Create selected** or **Create all from device**.
7. Press **Request Discovery** if publishers listen for the HA Birth topic.
8. Verify that children appear and update.

The approval controls distinguish reversible disable from cleanup. **Disable selected** keeps the HC3 child but stops MQTT updates. **Delete from HC3** requires two clicks within ten seconds, removes the child and keeps the discovery record disabled so retained MQTT discovery cannot recreate it immediately.

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

The production QuickApp has no dependency on Python, PLua, Docker or external Lua libraries after it is installed on HC3.

## Release workflow

1. Update `VERSION`, `Constants.VERSION`, the `main.lua` description and `CHANGELOG.md`.
2. Run `tests/run_all.lua`; its first test rejects inconsistent versions.
3. Run `scripts/package.sh` to create the versioned FQA in `dist/`.
4. Commit source, documentation, icon assets and the matching FQA together.
