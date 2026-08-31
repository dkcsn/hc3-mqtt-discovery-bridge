# Changelog

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
