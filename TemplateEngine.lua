-- Cache and message-context layer around the parser/evaluator. JSON decoding is
-- lazy and can be shared by every entity consuming one MQTT message.
TemplateEngine = {}
TemplateEngine.__index = TemplateEngine

function TemplateEngine.new(options)
  return setmetatable({
    cache = {}, errorsLogged = {}, logger = options and options.logger,
    metrics = {compiled=0, cacheHits=0, cacheMisses=0, evaluations=0, errors=0},
  }, TemplateEngine)
end

function TemplateEngine:compile(source)
  if source == nil or source == "" then return {passthrough=true, source=""} end
  if self.cache[source] then self.metrics.cacheHits = self.metrics.cacheHits + 1; return self.cache[source] end
  self.metrics.cacheMisses = self.metrics.cacheMisses + 1
  local ast, err = TemplateParser.parseTemplate(source, Constants)
  if not ast then self.metrics.errors = self.metrics.errors + 1; return nil, err end
  local cacheSize=0; for _ in pairs(self.cache) do cacheSize=cacheSize+1 end
  if cacheSize>=Constants.MAX_TEMPLATE_CACHE then
    local oldest=next(self.cache); if oldest then self.cache[oldest]=nil end
  end
  local compiled = {source=source, ast=ast}
  self.cache[source] = compiled
  self.metrics.compiled = self.metrics.compiled + 1
  return compiled
end

function TemplateEngine:messageContext(payload, extra, shared)
  shared = shared or {}
  local context = Utils.merge(extra or {}, {value=payload})
  context.__decodeJson = function()
    if shared.jsonAttempted then return shared.jsonValue, shared.jsonError end
    shared.jsonAttempted = true
    shared.jsonValue, shared.jsonError = Utils.decodeJson(payload)
    return shared.jsonValue, shared.jsonError
  end
  return context
end

function TemplateEngine:evaluate(compiled, context, identity)
  self.metrics.evaluations = self.metrics.evaluations + 1
  if not compiled or compiled.passthrough then return context.value end
  local value, err = TemplateEvaluator.evaluateTemplate(compiled.ast, context, Constants)
  if err then
    self.metrics.errors = self.metrics.errors + 1
    local key = compiled.source .. "|" .. tostring(err.message)
    if not self.errorsLogged[key] then
      local errorCount=0; for _ in pairs(self.errorsLogged) do errorCount=errorCount+1 end
      if errorCount>=Constants.MAX_TEMPLATE_CACHE then local oldest=next(self.errorsLogged); if oldest then self.errorsLogged[oldest]=nil end end
      self.errorsLogged[key] = true
      if self.logger then self.logger("WARNING", "TEMPLATE", tostring(identity or "entity") .. ": " .. err.message) end
    end
    return nil, err
  end
  return Utils.trim(value)
end

function TemplateEngine:render(source, context, identity)
  local compiled, err = self:compile(source)
  if not compiled then return nil, err end
  return self:evaluate(compiled, context, identity)
end

function TemplateEngine:getMetrics() return Utils.copy(self.metrics) end

return TemplateEngine
