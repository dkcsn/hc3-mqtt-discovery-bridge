-- Portable helpers shared by pure-Lua modules and the HC3 runtime. No helper
-- performs network or filesystem I/O, which keeps unit tests deterministic.
Utils = {}

function Utils.trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

function Utils.copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for k, v in pairs(value) do result[Utils.copy(k, seen)] = Utils.copy(v, seen) end
  return result
end

function Utils.merge(base, extra)
  local result = Utils.copy(base or {})
  for k, v in pairs(extra or {}) do result[k] = Utils.copy(v) end
  return result
end

function Utils.array(value)
  if value == nil then return {} end
  if type(value) ~= "table" then return {value} end
  if value[1] ~= nil then return value end
  return {value}
end

function Utils.bool(value, default)
  if value == nil or value == "" then return default end
  if type(value) == "boolean" then return value end
  local text = tostring(value):lower()
  if text == "true" or text == "1" or text == "yes" or text == "on" then return true end
  if text == "false" or text == "0" or text == "no" or text == "off" then return false end
  return default
end

function Utils.number(value, default)
  local n = tonumber(value)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
  return n
end

function Utils.clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

function Utils.sanitizeName(value)
  local name = Utils.trim(value):gsub("[%z\1-\31]", " "):gsub("%s+", " ")
  if name == "" then name = "MQTT entity" end
  if #name > 120 then name = name:sub(1, 120) end
  return name
end

-- Deterministic DJB2 identity using only portable Lua arithmetic.
function Utils.hash(value)
  local hash = 5381
  for i = 1, #tostring(value) do
    hash = (hash * 33 + tostring(value):byte(i)) % 4294967296
  end
  return string.format("%08x", hash)
end

local function withinJsonLimits(root, maxDepth, maxNodes)
  if type(root)~="table" then return true end
  local stack,seen,nodes={{value=root,depth=1}},{},0
  while #stack>0 do
    local item=table.remove(stack)
    if item.depth>maxDepth then return false,"json_depth_limit" end
    if not seen[item.value] then
      seen[item.value]=true
      for key,value in pairs(item.value) do
        nodes=nodes+1; if nodes>maxNodes then return false,"json_node_limit" end
        if type(key)=="table" then stack[#stack+1]={value=key,depth=item.depth+1} end
        if type(value)=="table" then stack[#stack+1]={value=value,depth=item.depth+1} end
      end
    end
  end
  return true
end

function Utils.decodeJson(text,maxDepth,maxNodes)
  if not json or not json.decode then return nil, "json_api_unavailable" end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= "table" then return nil, ok and "json_root_not_object" or tostring(value) end
  local safe,limitError=withinJsonLimits(value,maxDepth or 32,maxNodes or Constants.MAX_JSON_NODES or 4096)
  if not safe then return nil,limitError end
  return value
end

function Utils.encodeJson(value)
  if not json or not json.encode then return nil, "json_api_unavailable" end
  local ok, result = pcall(json.encode, value)
  if not ok then return nil, tostring(result) end
  return result
end

function Utils.qvarsToMap(qvars)
  local result = {}
  for _, item in ipairs(qvars or {}) do result[item.name] = item.value end
  return result
end

function Utils.mapToQvars(values)
  local result = {}
  for key, value in pairs(values or {}) do
    result[#result + 1] = {name = key, value = tostring(value == nil and "" or value)}
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

function Utils.topicValid(topic)
  return type(topic) == "string" and topic ~= "" and #topic <= 65535 and
    not topic:find("\0", 1, true) and not topic:find("[+#]")
end

return Utils
