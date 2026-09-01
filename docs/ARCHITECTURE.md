# Architecture

## File responsibilities

| File | Responsibility |
|---|---|
| `main.lua` | PLua manifest, dependency composition, QuickApp lifecycle, UI and public API. |
| `MQTTClient.lua` | One native MQTT connection, lifecycle, backoff, jitter and transport metrics. |
| `Discovery.lua` | Atomic topic-level discovery update orchestration. |
| `DiscoveryNormalize.lua` | Topic parsing, JSON validation, abbreviations, `~`, Device Discovery and canonical entities. |
| `SubscriptionRegistry.lua` | Reference-counted exact-topic subscriptions and direct dispatch. |
| `EntityRegistry.lua` | External-ID and child-ID indexes plus compact, chunked A/B persistence. |
| `ApprovalManager.lua` | Pure approval states, MQTT device grouping, counts and filter rules. |
| `ApprovalUI.lua` | Dependent HC3 selects, approval actions, dynamic entity probe, details and guarded cleanup. |
| `EntityMapper.lua` | Component adapters, state conversion and command generation. |
| `TemplateParser.lua` | Tokenizer, Pratt expression parser and control-block parser. |
| `TemplateEvaluator.lua` | Safe AST evaluator, filters and tests. |
| `TemplateEngine.lua` | Compilation cache, lazy/shared JSON decoding, metrics and error suppression. |
| `ChildFactory.lua` | Restore/create/update/recreate/remove HC3 children. |
| `ChildClasses.lua` | HC3 actions delegated back to the parent. No child owns MQTT. |
| `IconRegistry.lua` | Stable HC3 custom-icon ID registry. |
| `IconInstaller.lua`, `IconData.lua` | One-time HC3 upload and embedded 128 × 128 PNG bytes. |
| `Constants.lua`, `Utils.lua` | Protocol tables, bounds and portable helpers. |

The ordering in the `--%%file` headers is the runtime dependency order and the FQA packaging order.

## Discovery transaction

```text
retained MQTT config
        │
        ▼
validate topic and payload size
        │
        ▼
decode + normalize + expand Device Discovery
        │
        ▼
compile every referenced template
        │
        ├── failure: keep old working entity
        │
        ▼
detach old subscriptions
        │
        ▼
update registry and child in place
        │
        ▼
attach new subscriptions
        │
        ▼
persist once for the complete discovery transaction
```

Preparation occurs before commit. A malformed sibling in Device Discovery is rejected individually; valid siblings can still commit. Missing components in an updated device payload are removed after valid replacements have committed.

## Identity and restart

Identity priority is `unique_id`, device identifier plus component ID, then a deterministic discovery-topic hash. The child stores `mqttDiscoveryId`; the parent stores a compact canonical entity registry. Schema 4 writes verified internal-storage chunks before atomically switching an A/B generation manifest. Development schemas are deliberately not migrated. Startup loads one exact schema, enumerates children, joins both indexes, recompiles templates and restores exact subscriptions before MQTT states are processed. Display names never participate in identity.

Discovery and state lifecycles are separate. Connection startup subscribes to retained discovery and the exact topics of already-active entities. Publishing Home Assistant Birth is an explicit **Request Discovery** action, so a large discovery replay cannot be coupled implicitly to every reconnect.

## Shared-state efficiency

The subscription registry owns one broker subscription per exact topic and fans it out through a direct consumer table. The MQTT event object carries a message-local cache. When multiple entity templates reference `value_json`, the payload is decoded once and the parsed table is shared.

## HC3 child limitation

HC3 does not expose Home Assistant's device/entity hierarchy. Physical-device identifiers and metadata are preserved, but components are sibling HC3 children with consistent names. `select` and `button` use generic children because HC3 has no equivalent native child type with the same UI semantics.

The approval UI derives a transient semantic group from each entity's Home Assistant `device_class`, component and unit. This grouping is presentation state only and is never persisted into the discovery registry. Device/status, semantic group and entity therefore form three dependent selectors without changing MQTT identity or lifecycle semantics. Unknown metadata is routed to `Other`.

## Security boundaries

Discovery and state payloads are untrusted. The bridge bounds discovery and template sizes, validates topics/numbers, uses `pcall` at entity and MQTT event boundaries, and never translates templates into Lua. The evaluator sees only its explicit context and registered filters/tests; it cannot access files, network, HC3 APIs or Lua globals.
