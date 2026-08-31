-- Safe template front end: lexical analysis plus AST construction. It never
-- generates Lua source, and all complexity limits are enforced while parsing.
TemplateParser = {}

local function failure(message, position)
  return nil, {type = "parse_error", message = message, position = position or 1}
end

local function lex(source)
  local tokens, i, length = {}, 1, #source
  local function add(kind, value, pos) tokens[#tokens + 1] = {kind=kind, value=value, position=pos} end
  while i <= length do
    local c = source:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == "'" or c == '"' then
      local quote, pos, out = c, i, {}
      i = i + 1
      local closed = false
      while i <= length do
        c = source:sub(i, i)
        if c == quote then closed = true; i = i + 1; break end
        if c == "\\" then
          i = i + 1
          if i > length then break end
          local escaped = source:sub(i, i)
          local map = {n="\n", r="\r", t="\t", ['\\']="\\", ['"']='"', ["'"]="'"}
          out[#out + 1] = map[escaped] or escaped
        else out[#out + 1] = c end
        i = i + 1
      end
      if not closed then return failure("unterminated string", pos) end
      add("string", table.concat(out), pos)
    elseif c:match("[%d]") or (c == "." and source:sub(i + 1, i + 1):match("%d")) then
      local pos, raw = i, source:sub(i):match("^(%d*%.?%d+[eE]?[+-]?%d*)")
      local value = tonumber(raw)
      if not value then return failure("invalid number", pos) end
      add("number", value, pos); i = i + #raw
    elseif c:match("[%a_]") then
      local pos, raw = i, source:sub(i):match("^([%a_][%w_]*)")
      add("identifier", raw, pos); i = i + #raw
    else
      local pos, two = i, source:sub(i, i + 1)
      if two == "==" or two == "!=" or two == ">=" or two == "<=" or
         two == "//" or two == "**" then
        add("operator", two, pos); i = i + 2
      elseif c:match("[+%-%*/%%><|.,%[%]()]" ) then
        add("operator", c, pos); i = i + 1
      else return failure("unexpected character '" .. c .. "'", pos) end
    end
  end
  add("eof", "eof", length + 1)
  return tokens
end

local binaryPrecedence = {
  ["or"] = 10, ["and"] = 20,
  ["=="] = 30, ["!="] = 30, [">"] = 30, [">="] = 30,
  ["<"] = 30, ["<="] = 30, ["in"] = 30, ["not in"] = 30,
  ["+"] = 40, ["-"] = 40,
  ["*"] = 50, ["/"] = 50, ["//"] = 50, ["%"] = 50,
  ["**"] = 60,
}

function TemplateParser.parseExpression(source, limits)
  limits = limits or Constants
  local tokens, lexError = lex(source)
  if not tokens then return nil, lexError end
  local index, nodes = 1, 0
  local function current(offset) return tokens[index + (offset or 0)] end
  local function consume() local token = tokens[index]; index = index + 1; return token end
  local function node(value, position, depth)
    nodes = nodes + 1
    if nodes > (limits.MAX_AST_NODES or 512) then return failure("AST node limit exceeded", position) end
    if depth > (limits.MAX_AST_DEPTH or 32) then return failure("AST depth limit exceeded", position) end
    return value
  end
  local parse
  local function expect(value)
    if current().value ~= value then return failure("expected '" .. value .. "'", current().position) end
    return consume()
  end
  local function primary(depth)
    local token = consume()
    local result, err
    if token.kind == "number" or token.kind == "string" then
      result, err = node({kind="literal", value=token.value}, token.position, depth)
    elseif token.kind == "identifier" then
      local lowered = token.value:lower()
      if lowered == "true" then result, err = node({kind="literal", value=true}, token.position, depth)
      elseif lowered == "false" then result, err = node({kind="literal", value=false}, token.position, depth)
      elseif lowered == "none" then result, err = node({kind="literal", value=nil, isNone=true}, token.position, depth)
      elseif lowered == "not" then
        local operand, operandError = parse(55, depth + 1)
        if not operand then return nil, operandError end
        result, err = node({kind="unary", op="not", operand=operand}, token.position, depth)
      else result, err = node({kind="variable", name=token.value}, token.position, depth) end
    elseif token.value == "-" or token.value == "+" then
      local operand, operandError = parse(55, depth + 1)
      if not operand then return nil, operandError end
      result, err = node({kind="unary", op=token.value, operand=operand}, token.position, depth)
    elseif token.value == "(" then
      result, err = parse(0, depth + 1)
      if not result then return nil, err end
      local _, closeError = expect(")")
      if closeError then return nil, closeError end
    else return failure("expected expression", token.position) end
    if not result then return nil, err end

    local filterCount = 0
    while true do
      token = current()
      if token.value == "." then
        consume()
        local key = consume()
        if key.kind ~= "identifier" then return failure("expected property name", key.position) end
        result, err = node({kind="get", object=result, key={kind="literal", value=key.value}}, key.position, depth)
      elseif token.value == "[" then
        consume()
        local key, keyError = parse(0, depth + 1)
        if not key then return nil, keyError end
        local _, closeError = expect("]")
        if closeError then return nil, closeError end
        result, err = node({kind="get", object=result, key=key}, token.position, depth)
      elseif token.value == "|" then
        filterCount = filterCount + 1
        if filterCount > (limits.MAX_FILTER_CHAIN or 32) then return failure("filter chain limit exceeded", token.position) end
        consume()
        local name = consume()
        if name.kind ~= "identifier" then return failure("expected filter name", name.position) end
        local args = {}
        if current().value == "(" then
          consume()
          if current().value ~= ")" then
            while true do
              local arg, argError = parse(0, depth + 1)
              if not arg then return nil, argError end
              args[#args + 1] = arg
              if current().value ~= "," then break end
              consume()
            end
          end
          local _, closeError = expect(")")
          if closeError then return nil, closeError end
        end
        result, err = node({kind="filter", name=name.value, value=result, args=args}, name.position, depth)
      else break end
      if not result then return nil, err end
    end
    return result
  end

  parse = function(minPrecedence, depth)
    local left, err = primary(depth)
    if not left then return nil, err end
    while true do
      local token, op = current(), current().value
      if token.kind == "identifier" and op == "not" and current(1).value == "in" then op = "not in" end
      if token.kind == "identifier" and op == "is" then
        consume()
        local negated = false
        if current().value == "not" then consume(); negated = true end
        local test = consume()
        if test.kind ~= "identifier" then return failure("expected test name", test.position) end
        local testNode, nodeError = node({kind="test", name=test.value, negated=negated, value=left}, token.position, depth)
        if not testNode then return nil, nodeError end
        left = testNode
      else
        local precedence = binaryPrecedence[op]
        if not precedence or precedence < minPrecedence then break end
        consume()
        if op == "not in" then consume() end
        local right, rightError = parse(precedence + (op == "**" and 0 or 1), depth + 1)
        if not right then return nil, rightError end
        left, err = node({kind="binary", op=op, left=left, right=right}, token.position, depth)
        if not left then return nil, err end
      end
    end
    if minPrecedence == 0 and current().value == "if" then
      local pos = consume().position
      local condition, conditionError = parse(0, depth + 1)
      if not condition then return nil, conditionError end
      local _, elseError = expect("else")
      if elseError then return nil, elseError end
      local fallback, fallbackError = parse(0, depth + 1)
      if not fallback then return nil, fallbackError end
      left, err = node({kind="conditional", condition=condition, yes=left, no=fallback}, pos, depth)
      if not left then return nil, err end
    end
    return left
  end

  local ast, parseError = parse(0, 1)
  if not ast then return nil, parseError end
  if current().kind ~= "eof" then return failure("unexpected token '" .. tostring(current().value) .. "'", current().position) end
  return ast
end

function TemplateParser.parseTemplate(source, limits)
  limits = limits or Constants
  if type(source) ~= "string" then return failure("template must be a string", 1) end
  if #source > (limits.MAX_TEMPLATE_LENGTH or 4096) then return failure("template length limit exceeded", 1) end
  source = source:gsub("{#.-#}", "")
  local position, length = 1, #source
  local function parseSequence(stopTags, depth)
    if depth > (limits.MAX_AST_DEPTH or 32) then return failure("template nesting limit exceeded", position) end
    local segments = {}
    while position <= length do
      local exprStart = source:find("{{", position, true)
      local blockStart = source:find("{%", position, true)
      local start, kind
      if exprStart and (not blockStart or exprStart < blockStart) then start, kind = exprStart, "expr"
      elseif blockStart then start, kind = blockStart, "block" end
      if not start then
        if position <= length then segments[#segments + 1] = {kind="text", value=source:sub(position)} end
        position = length + 1
        return segments
      end
      if start > position then segments[#segments + 1] = {kind="text", value=source:sub(position, start - 1)} end
      local close = source:find(kind == "expr" and "}}" or "%}", start + 2, true)
      if not close then return failure("unterminated template tag", start) end
      local body = Utils.trim(source:sub(start + 2, close - 1))
      position = close + 2
      if kind == "expr" then
        local ast, err = TemplateParser.parseExpression(body, limits)
        if not ast then err.position = start + (err.position or 1); return nil, err end
        segments[#segments + 1] = {kind="expression", ast=ast}
      else
        local keyword, remainder = body:match("^(%S+)%s*(.-)$")
        if stopTags and stopTags[keyword] then return segments, {tag=keyword, expression=remainder, position=start} end
        if keyword ~= "if" then return failure("unsupported block '" .. tostring(keyword) .. "'", start) end
        local condition, err = TemplateParser.parseExpression(remainder, limits)
        if not condition then return nil, err end
        local branches = {}
        local branchBody, stop = parseSequence({elif=true, ["else"]=true, endif=true}, depth + 1)
        if not branchBody then return nil, stop end
        branches[#branches + 1] = {condition=condition, body=branchBody}
        while stop and stop.tag == "elif" do
          local nextCondition, nextError = TemplateParser.parseExpression(stop.expression, limits)
          if not nextCondition then return nil, nextError end
          branchBody, stop = parseSequence({elif=true, ["else"]=true, endif=true}, depth + 1)
          if not branchBody then return nil, stop end
          branches[#branches + 1] = {condition=nextCondition, body=branchBody}
        end
        local otherwise = {}
        if stop and stop.tag == "else" then
          otherwise, stop = parseSequence({endif=true}, depth + 1)
          if not otherwise then return nil, stop end
        end
        if not stop or stop.tag ~= "endif" then return failure("missing endif", start) end
        segments[#segments + 1] = {kind="if", branches=branches, otherwise=otherwise}
      end
    end
    if stopTags then return failure("missing closing block", length) end
    return segments
  end
  return parseSequence(nil, 1)
end

return TemplateParser
