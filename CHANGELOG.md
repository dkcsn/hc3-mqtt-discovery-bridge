# Changelog

## 0.3.3 — 2026-09-01

- Added a third, semantic entity-group filter between device/status scope and
  entity selection for large MQTT Discovery datasets.
- Classifies entities deterministically from Home Assistant `device_class`,
  component and unit metadata, with name matching only as a fallback and an
  explicit `Other` group that prevents unknown entities from disappearing.
- Added per-group entity and pending counts, page reset on group changes and
  group-scoped bulk creation that continues to preserve disabled entities.

## 0.3.2 — 2026-09-01

- Redesigned restart reconciliation around an explicit `QuickAppChild` class
  lifecycle and schema-4 registry state, without development-time migrations.
- Separated discovery requests from MQTT connection startup; HA Birth is now an
  explicit operator action and cannot flood the state bootstrap path.
- Added a dynamic 30-second probe for the entity selected in the existing UI;
  no diagnostic topic is hardcoded.
- Detects duplicate children with the same discovery identity and marks only
  the duplicate as an orphan for guarded cleanup.
- Replaced the permanent wall of QA buttons with lifecycle-aware primary and
  secondary actions plus one maintenance selector; status now distinguishes
  HC3 children from shared MQTT topic subscriptions.
- Restricted device bulk creation to pending entities so a previous explicit
  disable is never silently reversed.
- Moved manual MQTT reconnect out of the HC3 action callback and added
  connection generations so delayed events from the replaced client are ignored.

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
