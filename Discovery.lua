-- Owns topic-level discovery transactions. Validation/preparation happens for
-- the new model before working entities and their subscriptions are replaced.
Discovery = {}
Discovery.__index = Discovery

function Discovery.new(options)
  return setmetatable({prefix=options.prefix, onUpsert=options.onUpsert,
    onRemove=options.onRemove, logger=options.logger, byTopic={},
    metrics={messages=0, errors=0}}, Discovery)
end

function Discovery:process(topic, payload)
  self.metrics.messages = self.metrics.messages + 1
  local entities, err, metadata = DiscoveryNormalize.payload(topic, payload, self.prefix)
  if not entities then
    self.metrics.errors = self.metrics.errors + 1
    if self.logger then self.logger("WARNING", "DISCOVERY", topic .. ": " .. tostring(err)) end
    return false, err
  end
  local old = self.byTopic[topic] or {}
  if metadata.remove then
    for externalId in pairs(old) do self.onRemove(externalId, topic) end
    self.byTopic[topic] = nil
    return true
  end
  if metadata.migration then return true, "migration_acknowledged" end
  local prepared, nextIds = {}, {}
  for _, entity in ipairs(entities) do
    local ok, preparedEntityOrError = self.onUpsert(entity, true)
    if ok then prepared[#prepared + 1] = preparedEntityOrError or entity
    elseif self.logger then self.logger("WARNING", "DISCOVERY", entity.externalId .. ": " .. tostring(preparedEntityOrError)) end
  end
  if #prepared == 0 then return false, "all_entities_rejected" end
  for _, entity in ipairs(prepared) do
    local ok, commitError = self.onUpsert(entity, false)
    if ok then nextIds[entity.externalId] = true
    elseif self.logger then self.logger("ERROR", "DISCOVERY", entity.externalId .. ": commit failed: " .. tostring(commitError)) end
  end
  for externalId in pairs(old) do if not nextIds[externalId] then self.onRemove(externalId, topic) end end
  self.byTopic[topic] = nextIds
  return true
end

function Discovery:restore(entities)
  for externalId, entity in pairs(entities or {}) do
    self.byTopic[entity.discoveryTopic] = self.byTopic[entity.discoveryTopic] or {}
    self.byTopic[entity.discoveryTopic][externalId] = true
  end
end

return Discovery
