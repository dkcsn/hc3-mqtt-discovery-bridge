-- Adapter registry translating canonical HA entities to verified HC3 child
-- types, state properties and outgoing MQTT commands.
EntityMapper = {adapters={}}

local function payloadValue(entity, payload, engine, shared)
  if not entity.valueCompiled then return payload end
  local context = engine:messageContext(payload, {
    entity_id=entity.externalId, name=entity.name,
    this={state=entity.lastValue, name=entity.name, id=entity.externalId},
  }, shared)
  return engine:evaluate(entity.valueCompiled, context, entity.externalId)
end

local function binary(value, onValue, offValue)
  local text = Utils.trim(value)
  if text == tostring(onValue) then return true end
  if text == tostring(offValue) then return false end
  local lowered = text:lower()
  if lowered == "true" or lowered == "on" or lowered == "1" then return true end
  if lowered == "false" or lowered == "off" or lowered == "0" then return false end
  return nil
end

local function stateTopic(entity) return entity.stateTopic and {entity.stateTopic} or {} end

EntityMapper.adapters.sensor = {
  childType=function(entity)
    if entity.config.device_class == "temperature" then return "com.fibaro.temperatureSensor" end
    if entity.config.device_class == "humidity" then return "com.fibaro.humiditySensor" end
    return "com.fibaro.multilevelSensor"
  end,
  subscriptions=stateTopic,
  state=function(entity, value)
    if type(value)=="string" and value:match("^%s*{") then
      local object=Utils.decodeJson(value)
      if object then
        local brightness=Utils.number(object.brightness)
        local scale=Utils.number(entity.config.brightness_scale,255)
        local isOn=binary(object.state or "",entity.config.payload_on or "ON",entity.config.payload_off or "OFF")
        if brightness then return {value=Utils.clamp(brightness/scale*100,0,100),state=isOn~=false} end
        if isOn~=nil then return {value=isOn and math.max(Utils.number(entity.lastValue,100),1) or 0,state=isOn} end
      end
    end
    local n = Utils.number(value)
    if not n then return nil, "non_numeric_sensor_value" end
    return {value=n, unit=entity.config.unit_of_measurement}
  end,
}

EntityMapper.adapters.binary_sensor = {
  childType=function() return "com.fibaro.binarySensor" end,
  subscriptions=stateTopic,
  state=function(entity, value)
    local result = binary(value, entity.config.payload_on or "ON", entity.config.payload_off or "OFF")
    if result == nil then return nil, "unknown_binary_payload" end
    return {value=result}
  end,
}

EntityMapper.adapters.switch = {
  childType=function() return "com.fibaro.binarySwitch" end,
  subscriptions=stateTopic,
  state=function(entity, value)
    local result = binary(value, entity.config.state_on or entity.config.payload_on or "ON",
      entity.config.state_off or entity.config.payload_off or "OFF")
    if result == nil then return nil, "unknown_switch_payload" end
    return {value=result, state=result}
  end,
  command=function(entity, action)
    if action == "turnOn" then return entity.config.payload_on or "ON", true end
    if action == "turnOff" then return entity.config.payload_off or "OFF", false end
    if action == "toggle" then
      local nextValue = not not (not entity.lastValue)
      return nextValue and (entity.config.payload_on or "ON") or (entity.config.payload_off or "OFF"), nextValue
    end
  end,
}

EntityMapper.adapters.light = {
  childType=function() return "com.fibaro.multilevelSwitch" end,
  subscriptions=stateTopic,
  state=function(entity, value)
    local n = Utils.number(value)
    if n then
      local scale = Utils.number(entity.config.brightness_scale, 255)
      return {value=Utils.clamp(n / scale * 100, 0, 100), state=n > 0}
    end
    local result = binary(value, entity.config.payload_on or "ON", entity.config.payload_off or "OFF")
    if result == nil then return nil, "unknown_light_payload" end
    return {value=result and math.max(Utils.number(entity.lastValue, 100), 1) or 0, state=result}
  end,
  command=function(entity, action, value)
    if action == "turnOn" then return entity.config.payload_on or "ON", true end
    if action == "turnOff" then return entity.config.payload_off or "OFF", false end
    if action == "setValue" then
      local percent = Utils.clamp(Utils.number(value, 0), 0, 100)
      local scale = Utils.number(entity.config.brightness_scale, 255)
      return tostring(math.floor(percent / 100 * scale + 0.5)), percent
    end
  end,
}

EntityMapper.adapters.cover = {
  childType=function() return "com.fibaro.rollerShutter" end,
  subscriptions=function(entity)
    local topics = {}; if entity.stateTopic then topics[#topics+1]=entity.stateTopic end
    if entity.config.position_topic and entity.config.position_topic ~= entity.stateTopic then topics[#topics+1]=entity.config.position_topic end
    return topics
  end,
  state=function(entity, value)
    local n = Utils.number(value)
    if n then
      local closed, opened = Utils.number(entity.config.position_closed, 0), Utils.number(entity.config.position_open, 100)
      local percent = opened == closed and n or ((n - closed) / (opened - closed) * 100)
      return {value=Utils.clamp(percent, 0, 100)}
    end
    local states = {
      [entity.config.state_open or "open"]="Open", [entity.config.state_opening or "opening"]="Opening",
      [entity.config.state_closed or "closed"]="Closed", [entity.config.state_closing or "closing"]="Closing",
      [entity.config.state_stopped or "stopped"]="Stopped",
    }
    if not states[tostring(value)] then return nil, "unknown_cover_payload" end
    return {state=states[tostring(value)]}
  end,
  command=function(entity, action, value)
    if action == "open" then return entity.config.payload_open or "OPEN", 100, entity.commandTopic end
    if action == "close" then return entity.config.payload_close or "CLOSE", 0, entity.commandTopic end
    if action == "stop" then return entity.config.payload_stop or "STOP", nil, entity.commandTopic end
    if action == "setValue" then
      local percent = Utils.clamp(Utils.number(value, 0), 0, 100)
      local closed, opened = Utils.number(entity.config.position_closed, 0), Utils.number(entity.config.position_open, 100)
      local outgoing = closed + percent / 100 * (opened - closed)
      return tostring(math.floor(outgoing + 0.5)), percent, entity.config.set_position_topic or entity.commandTopic
    end
  end,
}

EntityMapper.adapters.button = {
  childType=function() return "com.fibaro.device" end, subscriptions=function() return {} end,
  command=function(entity, action)
    if action == "press" then return entity.config.payload_press or "PRESS", nil end
  end,
}

EntityMapper.adapters.number = {
  childType=function() return "com.fibaro.multilevelSwitch" end, subscriptions=stateTopic,
  state=function(entity, value)
    local n=Utils.number(value); if not n then return nil, "invalid_number" end; return {value=n}
  end,
  command=function(entity, action, value)
    if action ~= "setValue" then return end
    local n=Utils.number(value); if not n then return nil, nil, nil, "invalid_number" end
    local minimum, maximum = Utils.number(entity.config.min, 1), Utils.number(entity.config.max, 100)
    if n < minimum or n > maximum then return nil, nil, nil, "number_out_of_range" end
    local step=Utils.number(entity.config.step, 1); n=minimum + math.floor((n-minimum)/step+0.5)*step
    return tostring(n), n
  end,
}

EntityMapper.adapters.select = {
  childType=function() return "com.fibaro.device" end, subscriptions=stateTopic,
  state=function(_, value) return {value=tostring(value)} end,
  command=function(entity, action, value)
    if action ~= "setValue" and action ~= "select" then return end
    for _, option in ipairs(entity.config.options or {}) do if tostring(option)==tostring(value) then return tostring(value), tostring(value) end end
    return nil, nil, nil, "invalid_select_option"
  end,
}

function EntityMapper.prepare(entity, engine)
  local adapter = EntityMapper.adapters[entity.component]
  if not adapter then entity.supported=false; return entity end
  entity.childType = adapter.childType(entity)
  if entity.valueTemplate then
    local compiled, err = engine:compile(entity.valueTemplate); if not compiled then return nil, err.message end
    entity.valueCompiled = compiled
  end
  if entity.commandTemplate then
    local compiled, err = engine:compile(entity.commandTemplate); if not compiled then return nil, err.message end
    entity.commandCompiled = compiled
  end
  entity.supported = true
  return entity
end

function EntityMapper.subscriptions(entity)
  local adapter = EntityMapper.adapters[entity.component]
  local topics = adapter and adapter.subscriptions(entity) or {}
  if entity.jsonAttributesTopic then topics[#topics+1] = entity.jsonAttributesTopic end
  for _, availability in ipairs(entity.availability.topics or {}) do topics[#topics+1] = availability.topic end
  return topics
end

function EntityMapper.handleState(entity, child, payload, engine, shared)
  local adapter=EntityMapper.adapters[entity.component]; if not adapter then return false, "unsupported_component" end
  local value, templateError=payloadValue(entity,payload,engine,shared); if templateError then return false, templateError.message end
  local properties, err=adapter.state(entity,value); if not properties then return false,err end
  for key, propertyValue in pairs(properties) do
    if propertyValue ~= nil then child:updateProperty(key, propertyValue) end
  end
  entity.lastValue = properties.value ~= nil and properties.value or value
  return true
end

function EntityMapper.command(entity, action, value, engine)
  local adapter=EntityMapper.adapters[entity.component]; if not adapter or not adapter.command then return nil,"unsupported_action" end
  local payload, optimisticValue, topic, err=adapter.command(entity,action,value)
  if err then return nil,err end
  if payload == nil then return nil,"unsupported_action" end
  topic = topic or entity.commandTopic
  if not Utils.topicValid(topic) then return nil,"command_topic_missing" end
  if entity.commandCompiled then
    local context={value=optimisticValue ~= nil and optimisticValue or value,
      entity_id=entity.externalId,name=entity.name,this={state=entity.lastValue,name=entity.name,id=entity.externalId}}
    payload, err=engine:evaluate(entity.commandCompiled,context,entity.externalId)
    if not payload then return nil,err and err.message or "command_template_failed" end
  end
  return {topic=topic,payload=tostring(payload),qos=entity.qos,retain=entity.retain,optimisticValue=optimisticValue}
end

return EntityMapper
