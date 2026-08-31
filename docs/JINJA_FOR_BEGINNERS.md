# MQTT/Jinja templates for beginners

## What a template does

An MQTT payload is just text. Sometimes the text is already the value HC3
needs, for example `22.4`. Often it is JSON containing several values:

```json
{"temperature":22.4,"humidity":51,"online":true}
```

A template selects or converts one value from that payload. The bridge uses a
safe, deliberately limited Jinja-compatible template engine. It does not run
the template as Lua and the template cannot access HC3, files or the network.

## Where the template is configured

You normally do **not** type templates into a QuickApp variable. The MQTT
device or gateway includes them in its retained MQTT Discovery configuration:

```json
{
  "name": "Kitchen temperature",
  "unique_id": "kitchen_temperature",
  "state_topic": "house/kitchen/climate",
  "value_template": "{{ value_json.temperature | float | round(1) }}",
  "unit_of_measurement": "°C",
  "device_class": "temperature"
}
```

That JSON is published retained to a discovery topic such as:

```text
homeassistant/sensor/kitchen_temperature/config
```

The normal state message is then published to:

```text
house/kitchen/climate
```

If the state payload is `{"temperature":22.43,"humidity":51}`, the template
returns `22.4`, and the HC3 temperature child is updated with that value.

## The two most important input values

| Name | Meaning | Example |
|---|---|---|
| `value` | The complete MQTT payload as text | `ON` |
| `value_json` | The payload decoded as JSON | `value_json.temperature` |

Use `value` for simple payloads:

```jinja
{{ value | upper }}
```

Use `value_json` for JSON payloads:

```jinja
{{ value_json.environment.temperature | float | round(1) }}
```

Array and unusual property names can use brackets:

```jinja
{{ value_json.sensors[0].value }}
{{ value_json["current-power"] | float }}
```

## Common recipes

Convert text to a number:

```jinja
{{ value | float }}
```

Use a default when a JSON field is missing:

```jinja
{{ value_json.temperature | default(0) | float }}
```

Convert a number from tenths of a degree:

```jinja
{{ (value_json.temperature | float) / 10 | round(1) }}
```

Map text to `ON` or `OFF`:

```jinja
{{ "ON" if value | lower == "active" else "OFF" }}
```

Use a longer condition:

```jinja
{% if value_json.online %}
{{ value_json.temperature | float | round(1) }}
{% else %}
unavailable
{% endif %}
```

Create a JSON command payload with `command_template`:

```jinja
{"state":"{{ value | upper }}"}
```

For a switch, `value` is the outgoing command value selected by the component
adapter, normally `ON` or `OFF`. The rendered result is published to the
entity's `command_topic`.

## How it appears in the QuickApp

1. The bridge receives the retained discovery configuration.
2. It validates and compiles `value_template` and `command_template`.
3. In `discoveryMode=approval`, the entity appears as **Pending approval**.
4. **Create selected** creates its HC3 child and starts its state subscription.
5. Each MQTT state payload is processed by the template before HC3 is updated.

Press **Entity details** to write the selected entity's discovery topic, state
topic, command topic and approval state to the HC3 log. Set `logLevel=DEBUG` if
you need controlled template error messages.

## Important difference from Home Assistant

The bridge supports payload transformation, not Home Assistant's complete
template environment. Functions such as `states()`, `state_attr()`, areas,
devices, loops, macros, imports and `set` are unavailable. They depend on Home
Assistant's internal state database, which does not exist on HC3.

For the exact supported operators, filters and tests, see
[`TEMPLATE_ENGINE.md`](TEMPLATE_ENGINE.md).

## If you do not create the discovery messages yourself

Most devices, Zigbee2MQTT installations and gateways publish the discovery JSON
for you. In that situation, no Jinja work is required in the QA. The table in
`TEMPLATE_ENGINE.md` is primarily a compatibility reference explaining which
templates the bridge can consume automatically.
