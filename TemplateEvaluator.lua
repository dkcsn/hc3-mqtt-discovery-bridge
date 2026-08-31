-- Evaluates only parser-created AST nodes against an explicit context. The
-- filter/test registries are the complete callable surface exposed to MQTT data.
TemplateEvaluator = {}

local UNDEFINED = {__undefined=true}
TemplateEvaluator.UNDEFINED = UNDEFINED

local function isUndefined(value) return value == UNDEFINED end
local function truthy(value)
  if value == nil or value == false or isUndefined(value) then return false end
  if type(value) == "number" and value == 0 then return false end
  if type(value) == "string" and value == "" then return false end
  if type(value) == "table" and next(value) == nil then return false end
  return true
end

local function render(value)
  if value == nil or isUndefined(value) then return "" end
  if value == true then return "True" end
  if value == false then return "False" end
  if type(value) == "table" then
    local encoded = Utils.encodeJson(value)
    return encoded or ""
  end
  return tostring(value)
end

local function sequenceLength(value)
  if type(value) == "string" then return #value end
  if type(value) ~= "table" then return 0 end
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  return count
end

TemplateEvaluator.filters = {
  int = function(value, default)
    local n = tonumber(value); return n and math.floor(n) or (default or 0)
  end,
  float = function(value, default) return tonumber(value) or default or 0.0 end,
  round = function(value, precision)
    local n, p = tonumber(value), tonumber(precision) or 0
    if not n then return value end
    local factor = 10 ^ p
    if n >= 0 then return math.floor(n * factor + 0.5) / factor end
    return math.ceil(n * factor - 0.5) / factor
  end,
  string = render,
  bool = truthy,
  default = function(value, fallback, useFalsy)
    if isUndefined(value) or value == nil or (useFalsy and not truthy(value)) then return fallback end
    return value
  end,
  lower = function(value) return tostring(value or ""):lower() end,
  upper = function(value) return tostring(value or ""):upper() end,
  trim = function(value) return Utils.trim(value) end,
  replace = function(value, old, new)
    old, new = tostring(old or ""), tostring(new or "")
    if old == "" then return tostring(value or "") end
    local pattern = old:gsub("([^%w])", "%%%1")
    return (tostring(value or ""):gsub(pattern, new:gsub("%%", "%%%%")))
  end,
  abs = function(value) local n=tonumber(value); return n and math.abs(n) or value end,
  min = function(value, ...)
    local values = type(value) == "table" and value or {value, ...}
    local result
    for _, item in pairs(values) do if result == nil or item < result then result = item end end
    return result
  end,
  max = function(value, ...)
    local values = type(value) == "table" and value or {value, ...}
    local result
    for _, item in pairs(values) do if result == nil or item > result then result = item end end
    return result
  end,
  length = sequenceLength,
}

TemplateEvaluator.tests = {
  defined = function(value) return not isUndefined(value) end,
  none = function(value) return value == nil end,
  number = function(value) return type(value) == "number" end,
  string = function(value) return type(value) == "string" end,
  boolean = function(value) return type(value) == "boolean" end,
}

local function errorResult(message)
  return nil, {type="evaluation_error", message=message}
end

function TemplateEvaluator.evaluateExpression(ast, context)
  local evaluate
  local function resolveVariable(name)
    if name == "value_json" and context.value_json == nil and context.__decodeJson then
      local decoded = context.__decodeJson()
      context.value_json = decoded or UNDEFINED
    end
    local value = context[name]
    if value == nil then return UNDEFINED end
    return value
  end
  local function numeric(value, operator)
    local n = tonumber(value)
    if not n then return errorResult("operator '" .. operator .. "' requires a number") end
    return n
  end
  evaluate = function(node)
    if node.kind == "literal" then return node.isNone and nil or node.value end
    if node.kind == "variable" then return resolveVariable(node.name) end
    if node.kind == "get" then
      local object, objectError = evaluate(node.object)
      if objectError then return nil, objectError end
      if type(object) ~= "table" then return UNDEFINED end
      local key, keyError = evaluate(node.key)
      if keyError then return nil, keyError end
      local value = object[key]
      return value == nil and UNDEFINED or value
    end
    if node.kind == "unary" then
      local value, err = evaluate(node.operand); if err then return nil, err end
      if node.op == "not" then return not truthy(value) end
      local number, numberError = numeric(value, node.op); if numberError then return nil, numberError end
      return node.op == "-" and -number or number
    end
    if node.kind == "binary" then
      local left, err = evaluate(node.left); if err then return nil, err end
      if node.op == "and" then return truthy(left) and evaluate(node.right) or left end
      if node.op == "or" then return truthy(left) and left or evaluate(node.right) end
      local right, rightError = evaluate(node.right); if rightError then return nil, rightError end
      if node.op == "==" then return (isUndefined(left) and isUndefined(right)) or left == right end
      if node.op == "!=" then return not ((isUndefined(left) and isUndefined(right)) or left == right) end
      if node.op == "in" or node.op == "not in" then
        local found = false
        if type(right) == "string" then found = right:find(tostring(left), 1, true) ~= nil
        elseif type(right) == "table" then
          if right[left] ~= nil then found = true else for _, value in pairs(right) do if value == left then found = true; break end end end
        end
        return node.op == "in" and found or not found
      end
      if node.op == "+" and (type(left) == "string" or type(right) == "string") then return render(left) .. render(right) end
      if node.op == ">" or node.op == ">=" or node.op == "<" or node.op == "<=" then
        if isUndefined(left) or isUndefined(right) then return false end
        if node.op == ">" then return left > right end
        if node.op == ">=" then return left >= right end
        if node.op == "<" then return left < right end
        return left <= right
      end
      local a, aError = numeric(left, node.op); if aError then return nil, aError end
      local b, bError = numeric(right, node.op); if bError then return nil, bError end
      if node.op == "+" then return a + b end
      if node.op == "-" then return a - b end
      if node.op == "*" then return a * b end
      if node.op == "/" then if b == 0 then return errorResult("division by zero") end; return a / b end
      if node.op == "//" then if b == 0 then return errorResult("division by zero") end; return math.floor(a / b) end
      if node.op == "%" then if b == 0 then return errorResult("modulo by zero") end; return a % b end
      if node.op == "**" then return a ^ b end
      return errorResult("unsupported operator '" .. tostring(node.op) .. "'")
    end
    if node.kind == "filter" then
      local filter = TemplateEvaluator.filters[node.name]
      if not filter then return errorResult("unknown filter '" .. tostring(node.name) .. "'") end
      local value, err = evaluate(node.value); if err then return nil, err end
      local args = {}
      for i, arg in ipairs(node.args) do args[i], err = evaluate(arg); if err then return nil, err end end
      local ok, result = pcall(filter, value, table.unpack(args))
      if not ok then return errorResult("filter '" .. node.name .. "' failed: " .. tostring(result)) end
      return result
    end
    if node.kind == "test" then
      local test = TemplateEvaluator.tests[node.name]
      if not test then return errorResult("unknown test '" .. tostring(node.name) .. "'") end
      local value, err = evaluate(node.value); if err then return nil, err end
      local result = test(value)
      return node.negated and not result or result
    end
    if node.kind == "conditional" then
      local condition, err = evaluate(node.condition); if err then return nil, err end
      return evaluate(truthy(condition) and node.yes or node.no)
    end
    return errorResult("unknown AST node")
  end
  return evaluate(ast)
end

function TemplateEvaluator.evaluateTemplate(segments, context, limits)
  local output = {}
  local function append(value)
    output[#output + 1] = value
    if #table.concat(output) > ((limits or Constants).MAX_TEMPLATE_OUTPUT or 16384) then
      return errorResult("template output limit exceeded")
    end
    return true
  end
  local function renderSegments(items)
    for _, segment in ipairs(items) do
      if segment.kind == "text" then
        local ok, err = append(segment.value); if not ok then return nil, err end
      elseif segment.kind == "expression" then
        local value, err = TemplateEvaluator.evaluateExpression(segment.ast, context)
        if err then return nil, err end
        local ok; ok, err = append(render(value)); if not ok then return nil, err end
      elseif segment.kind == "if" then
        local selected = segment.otherwise
        for _, branch in ipairs(segment.branches) do
          local condition, err = TemplateEvaluator.evaluateExpression(branch.condition, context)
          if err then return nil, err end
          if truthy(condition) then selected = branch.body; break end
        end
        local ok, err = renderSegments(selected); if not ok then return nil, err end
      end
    end
    return true
  end
  local ok, err = renderSegments(segments)
  if not ok then return nil, err end
  return table.concat(output)
end

return TemplateEvaluator
