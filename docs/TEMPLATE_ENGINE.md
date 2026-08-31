# Safe MQTT template engine

This is an intentionally small Jinja-compatible interpreter for MQTT payload templates. It is not Home Assistant's complete Jinja environment.

```text
template source → tokenizer → parser → AST cache → safe evaluator → bounded output
```

No Lua source is generated. `load`, `loadstring`, filesystem, network, HC3 APIs and Lua globals are unavailable to templates.

| Jinja feature | Support |
|---|---|
| `{{ expression }}` and literal text | YES |
| `value`, lazy `value_json`, `entity_id`, `name`, limited `this` | YES |
| dotted/indexed JSON access | YES |
| numbers, strings, booleans, `none` | YES |
| `+ - * / // % **` | YES |
| comparisons, `and`, `or`, `not`, `in`, `not in` | YES |
| inline conditional | YES |
| `if / elif / else / endif` | YES |
| comments `{# ... #}` | YES |
| filters `int`, `float`, `round`, `string`, `bool`, `default`, `lower`, `upper`, `trim`, `replace`, `abs`, `min`, `max`, `length` | YES |
| tests `defined`, `none`, `number`, `string`, `boolean` with optional `not` | YES |
| lists and dictionaries | NO |
| `set`, loops, macros, imports | NO |
| functions such as `states()` or `state_attr()` | NO |

Undefined values are distinct from `none`, enabling `is defined`. Unknown filters/tests and malformed syntax produce controlled error objects. One warning is emitted per unique template/error pair instead of once per MQTT update.

Limits are centralized in `Constants.lua`: 4096 source characters, 512 AST nodes, nesting depth 32, filter chain 32 and 16384 output characters.

`value_json` is decoded only on first access. Multiple consumers of one MQTT event reuse the message-local decoded table.

Example:

```jinja
{% if value_json.online %}
{{ value_json.temperature | float | round(1) }}
{% else %}
unavailable
{% endif %}
```
