-- Reference-counts exact MQTT topics. The broker sees one subscription even
-- when many entity templates consume the same JSON state message.
SubscriptionRegistry = {}
SubscriptionRegistry.__index = SubscriptionRegistry

function SubscriptionRegistry.new(options)
  return setmetatable({entries={}, subscribe=options.subscribe, unsubscribe=options.unsubscribe,
    logger=options.logger}, SubscriptionRegistry)
end

function SubscriptionRegistry:addConsumer(topic, entityId, callback, qos)
  if not Utils.topicValid(topic) then return false, "invalid_topic" end
  local entry = self.entries[topic]
  if not entry then
    entry = {qos=qos or 0, consumers={}}
    self.entries[topic] = entry
    if self.subscribe then self.subscribe(topic, entry.qos) end
  elseif (qos or 0) > entry.qos then entry.qos = qos or 0 end
  entry.consumers[entityId] = callback
  return true
end

function SubscriptionRegistry:removeConsumer(topic, entityId)
  local entry = self.entries[topic]
  if not entry then return end
  entry.consumers[entityId] = nil
  if next(entry.consumers) == nil then
    self.entries[topic] = nil
    if self.unsubscribe then self.unsubscribe(topic) end
  end
end

function SubscriptionRegistry:removeEntity(entityId)
  local topics = {}
  for topic, entry in pairs(self.entries) do if entry.consumers[entityId] then topics[#topics + 1] = topic end end
  for _, topic in ipairs(topics) do self:removeConsumer(topic, entityId) end
end

function SubscriptionRegistry:dispatch(topic, payload, message)
  local entry = self.entries[topic]
  if not entry then return 0 end
  local count = 0
  for entityId, callback in pairs(entry.consumers) do
    count = count + 1
    local ok, err = pcall(callback, payload, message)
    if not ok and self.logger then self.logger("WARNING", "MQTT", entityId .. ": " .. tostring(err)) end
  end
  return count
end

function SubscriptionRegistry:restoreSubscriptions()
  if not self.subscribe then return end
  for topic,entry in pairs(self.entries) do self.subscribe(topic,entry.qos) end
end

function SubscriptionRegistry:count()
  local count = 0; for _ in pairs(self.entries) do count = count + 1 end; return count
end

return SubscriptionRegistry
