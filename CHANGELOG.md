# Changelog

## 0.3.1 — 2026-08-31

- Fixed a live HC3 crash by using the native MQTT client's `closed` event
  instead of the unsupported `disconnected` socket event.
- Made MQTT event registration guarded and fail cleanly if firmware rejects an event.
- Read optional QuickApp variables without generating HC3 "Variable not found" warnings.

## 0.3.0 — 2026-08-31

- Replaced the single large registry variable with compact, integrity-checked,
  A/B-generated internal-storage chunks and automatic schema 1/2 migration.
- Batched Device Discovery persistence to one durable write per transaction.
- Added paginated approval controls and guarded orphan-child cleanup for large installations.
- Added native `device_tracker`, `siren` and `fan` adapters and improved JSON/separate-topic light brightness handling.
- Added unique default MQTT client IDs and a configurable randomized HA Birth delay.
- Added portable PLua scripts, a deferred Mosquitto smoke test, CI and release checksums.
- Licensed the public project under PolyForm Noncommercial 1.0.0.

## 0.2.0 — 2026-08-31

- Added `automatic` and `approval` discovery modes with persistent pending,
  active, disabled and unsupported states.
- Added dependent status/device and entity dropdowns, selected-entity details,
  individual and per-device approval, reversible disable and two-click cleanup.
- Added schema-1 registry migration that preserves existing active children.
- Embedded, uploaded and persistently registered the verified 128 × 128 parent icon.
- Added a beginner-oriented MQTT/Jinja guide with practical state and command examples.

## 0.1.1 — 2026-08-31

- Fixed the parent QuickApp type to `com.fibaro.deviceController`, ensuring that
  HC3 gives it a valid device category and displays it in the Devices GUI.
- Documented why the abstract `com.fibaro.device` base type must not be used for
  direct QuickApp installation.

## 0.1.0 — 2026-08-31

- Added native HC3 MQTT connection lifecycle with reconnect backoff and jitter.
- Added component and Device Discovery parsing, current abbreviations and base-topic expansion.
- Added versioned entity persistence, unique-ID reconciliation and shared subscriptions.
- Added safe cached MQTT template parser/evaluator with lazy shared JSON decoding.
- Added Tier 1 component adapters and delegated HC3 child actions.
- Added availability, attributes, HA Birth, parent UI/API, metrics and concise logging.
- Added a stable custom-icon registry and verified 128 × 128 icon asset.
- Added pure PLua tests, common-producer fixtures, examples and architecture/compatibility documentation.
