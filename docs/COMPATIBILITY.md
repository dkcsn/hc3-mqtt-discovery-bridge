# Compatibility

Status as of version 0.1.0. `FULL` means the intended basic state/command model is implemented, not every optional Home Assistant attribute.

| HA MQTT component | Level | HC3 child type | State | Commands | Known limitations |
|---|---|---|---|---|---|
| `sensor` | FULL | temperature, humidity or multilevel sensor | Numeric, template, unit metadata | — | Arbitrary string sensors are ignored because native multilevel sensors require numbers. |
| `binary_sensor` | FULL | binary sensor | Custom on/off payloads, template | — | Device-class-specific icons/types are not selected yet. |
| `switch` | FULL | binary switch | State/custom payloads/template | on, off, toggle | Toggle is optimistic when no state topic exists. |
| `light` | PARTIAL | multilevel switch | on/off or scalar brightness | on, off, brightness | RGB/RGBW, color temperature and effects remain metadata only. |
| `cover` | FULL | roller shutter | state/position and reversed ranges | open, close, stop, position | Tilt is not exposed. |
| `button` | FULL | generic device | — | press | No native HC3 button-child tile. Callable action is available. |
| `number` | FULL | multilevel switch | numeric | bounded/stepped set | HC3 tile remains 0–100 even when HA range differs. Validation is correct at publish time. |
| `select` | PARTIAL | generic device | string retained internally | select/setValue | No native option-list child UI. |
| `lock`, `fan`, `climate`, `device_tracker`, `siren`, `text`, `event`, `vacuum`, `valve` | PARSE-ONLY | none | Metadata retained | none | Adapter not implemented. |
| Other documented HA MQTT components | PARSE-ONLY | none | Metadata retained | none | Counted as unsupported; do not crash processing. |

## Cross-cutting features

| Feature | Support |
|---|---|
| Component discovery | YES |
| Device Discovery | YES |
| Current abbreviation table | YES |
| `~` topic base | YES |
| Shared state topics | YES |
| Retained discovery | Broker/HC3 native |
| Empty-payload removal | YES |
| In-place config update | YES |
| Unique-ID migration reconciliation | BASIC |
| Single/multi-topic availability | YES |
| JSON attributes | Internal only |
| QoS 0–2 and command retain | YES |
| TLS | `mqtts://`, subject to HC3 firmware/broker support |
| MQTT v5-only features | NO |

Exact type names were checked against the FIBARO SDK resource data included in PLua 1.3.16. MQTT discovery rules and abbreviations were checked against Home Assistant Core `dev` and Home Assistant 2026.8 documentation on 2026-08-31.
