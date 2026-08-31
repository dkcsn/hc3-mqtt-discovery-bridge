# MQTT Discovery semantics

The bridge subscribes to:

```text
<prefix>/+/+/config
<prefix>/+/+/+/config
```

These cover component discovery, optional `node_id`, Device Discovery and optional Device Discovery `node_id`. Component, node and object identifiers are validated before JSON is decoded.

## Normalization order

1. Enforce the 64 KiB discovery-payload limit.
2. Parse and validate the discovery topic.
3. Decode a JSON object.
4. Expand the centralized HA abbreviation tables at root, device, origin, component and availability levels.
5. Expand `~` at the start or end of fields whose key ends in `topic`, including availability entries.
6. Inherit Device Discovery shared fields into each component.
7. Build canonical entities and deterministic identities.
8. Compile templates and choose adapters before committing the update.

Unknown configuration keys remain available in the live canonical entity. Persistence keeps only adapter-relevant configuration plus canonical fields, which prevents large vendor payloads from exhausting HC3 storage.

## Device Discovery

Each entry under `components` becomes an independent canonical entity. Only Home Assistant's shared Device Discovery options are inherited; component values override them. `device` and `origin` are attached explicitly. One shared state topic creates one broker subscription with multiple consumers.

An updated device payload removes components omitted from the new valid configuration. An empty payload removes every entity currently owned by that discovery topic.

## Migration

`unique_id` is the primary reconciliation key. If the same unique ID appears on another discovery topic, the existing child is updated instead of duplicated. A standalone `migrate_discovery: true` message is recognized, but full emulation of Home Assistant's internal discovery-hash migration queue is outside 0.3.0.

## Availability

`availability_topic` and the `availability` list are normalized to one model. Modes `latest`, `all` and `any` control the child `dead` property. Broker disconnect alone does not permanently mark every physical device dead; availability messages remain the device-level authority.

## Sources

- [Home Assistant MQTT integration and discovery](https://www.home-assistant.io/integrations/mqtt/)
- [Home Assistant Core discovery implementation](https://github.com/home-assistant/core/blob/dev/homeassistant/components/mqtt/discovery.py)
- [Home Assistant Core abbreviation table](https://github.com/home-assistant/core/blob/dev/homeassistant/components/mqtt/abbreviations.py)

The table snapshot date is recorded in `Constants.lua` so updates are auditable.
