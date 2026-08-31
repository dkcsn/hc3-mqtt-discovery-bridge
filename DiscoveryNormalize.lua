-- Converts untrusted HA discovery JSON into the canonical entity model used by
-- every downstream module. Component-specific behavior does not belong here.
DiscoveryNormalize = {}

local function replaceKeys(input, abbreviations)
  if type(input) ~= "table" then return input end
  local output = {}
  for key, value in pairs(input) do output[abbreviations[key] or key] = Utils.copy(value) end
  return output
end

local function normalizeNested(config, componentOnly)
  config = replaceKeys(config, Constants.ABBREVIATIONS)
  if config.availability then
    local values = Utils.array(config.availability)
    for index, item in ipairs(values) do values[index] = replaceKeys(item, Constants.ABBREVIATIONS) end
    config.availability = values
  end
  if not componentOnly then
    if config.device then config.device = replaceKeys(config.device, Constants.DEVICE_ABBREVIATIONS) end
    if config.origin then config.origin = replaceKeys(config.origin, Constants.ORIGIN_ABBREVIATIONS) end
    if type(config.components) == "table" then
      local components = {}
      for id, item in pairs(config.components) do components[id] = normalizeNested(item, true) end
      config.components = components
    end
  end
  return config
end

local function expandTopic(base, topic)
  if type(topic) ~= "string" or topic == "" then return topic end
  if topic:sub(1, 1) == "~" then topic = base .. topic:sub(2) end
  if topic:sub(-1) == "~" then topic = topic:sub(1, -2) .. base end
  return topic
end

local function expandBase(config)
  local base = config["~"]
  if type(base) ~= "string" or base == "" then config["~"] = nil; return config end
  config["~"] = nil
  for key, value in pairs(config) do
    if type(value) == "string" and key:match("topic$") then config[key] = expandTopic(base, value) end
  end
  for _, availability in ipairs(Utils.array(config.availability)) do
    if type(availability) == "table" then availability.topic = expandTopic(base, availability.topic) end
  end
  return config
end

local function splitTopic(topic)
  local parts = {}
  for part in tostring(topic):gmatch("[^/]+") do parts[#parts + 1] = part end
  return parts
end

function DiscoveryNormalize.parseTopic(topic, prefix)
  local parts = splitTopic(topic)
  if parts[1] ~= prefix or parts[#parts] ~= "config" or (#parts ~= 4 and #parts ~= 5) then
    return nil, "invalid_discovery_topic"
  end
  local component, nodeId, objectId = parts[2], nil, nil
  if #parts == 4 then objectId = parts[3] else nodeId, objectId = parts[3], parts[4] end
  if not component:match("^[%w_]+$") or not objectId:match("^[%w_-]+$") or
     (nodeId and not nodeId:match("^[%w_-]+$")) then return nil, "illegal_discovery_topic" end
  return {component=component, nodeId=nodeId, objectId=objectId}
end

local function identifiers(device)
  local ids = device and device.identifiers
  if type(ids) == "string" then return {ids} end
  if type(ids) == "table" then return ids end
  return {}
end

local function normalizeAvailability(config)
  local result = {mode=config.availability_mode or "latest", topics={}}
  if config.availability_topic then
    result.topics[1] = {
      topic=config.availability_topic,
      available=config.payload_available or "online",
      unavailable=config.payload_not_available or "offline",
      template=config.availability_template,
    }
  end
  for _, item in ipairs(Utils.array(config.availability)) do
    if type(item) == "table" and item.topic then
      result.topics[#result.topics + 1] = {
        topic=item.topic,
        available=item.payload_available or config.payload_available or "online",
        unavailable=item.payload_not_available or config.payload_not_available or "offline",
        template=item.value_template,
      }
    end
  end
  if result.mode ~= "all" and result.mode ~= "any" then result.mode = "latest" end
  return result
end

local function canonical(config, topicInfo, discoveryTopic, componentId)
  local component = config.platform or topicInfo.component
  local device = config.device or {}
  local ids = identifiers(device)
  local identity
  if type(config.unique_id) == "string" and config.unique_id ~= "" then identity = "uid:" .. config.unique_id
  elseif ids[1] then identity = "dev:" .. tostring(ids[1]) .. ":" .. tostring(componentId or topicInfo.objectId)
  else identity = "topic:" .. Utils.hash(discoveryTopic .. ":" .. tostring(componentId or "")) end
  local display = config.name
  if not display or display == "" then display = componentId or topicInfo.objectId end
  if device.name and device.name ~= "" and display ~= device.name then display = device.name .. " – " .. display end
  local qos = math.floor(Utils.number(config.qos, 0) or 0)
  if qos < 0 or qos > 2 then qos = 0 end
  return {
    externalId=identity, discoveryTopic=discoveryTopic, component=component,
    componentId=componentId, uniqueId=config.unique_id, objectId=topicInfo.objectId,
    nodeId=topicInfo.nodeId, name=Utils.sanitizeName(display), originalName=config.name,
    device={identifiers=ids, name=device.name, manufacturer=device.manufacturer,
      model=device.model, modelId=device.model_id, serialNumber=device.serial_number,
      swVersion=device.sw_version, hwVersion=device.hw_version},
    origin=Utils.copy(config.origin or {}), stateTopic=config.state_topic,
    commandTopic=config.command_topic, valueTemplate=config.value_template or config.state_value_template,
    commandTemplate=config.command_template, jsonAttributesTopic=config.json_attributes_topic,
    jsonAttributesTemplate=config.json_attributes_template, availability=normalizeAvailability(config),
    qos=qos, retain=Utils.bool(config.retain, false), optimistic=Utils.bool(config.optimistic, not config.state_topic),
    config=Utils.copy(config), supported=Constants.TIER1[component] == true,
  }
end

function DiscoveryNormalize.payload(discoveryTopic, payload, prefix)
  if type(payload) ~= "string" then return nil, "payload_not_string" end
  if #payload > Constants.MAX_DISCOVERY_PAYLOAD then return nil, "payload_too_large" end
  local topicInfo, topicError = DiscoveryNormalize.parseTopic(discoveryTopic, prefix)
  if not topicInfo then return nil, topicError end
  if payload == "" then return {}, nil, {remove=true, topic=topicInfo} end
  local decoded, decodeError = Utils.decodeJson(payload)
  if not decoded then return nil, "invalid_json: " .. tostring(decodeError) end
  decoded = normalizeNested(decoded, false)
  local baseTopic = decoded["~"]
  if decoded.migrate_discovery == true then return {}, nil, {migration=true, topic=topicInfo} end
  local entities = {}
  if topicInfo.component == "device" then
    if type(decoded.components) ~= "table" then return nil, "device_components_missing" end
    local shared = Utils.copy(decoded); shared.components = nil
    for componentId, componentConfig in pairs(decoded.components) do
      if type(componentConfig) == "table" then
        local merged = Utils.merge(shared, componentConfig)
        merged.device = componentConfig.device or shared.device
        merged.origin = componentConfig.origin or shared.origin
        if baseTopic and merged["~"] == nil then merged["~"] = baseTopic end
        merged = expandBase(merged)
        if type(merged.platform) == "string" then
          entities[#entities + 1] = canonical(merged, topicInfo, discoveryTopic, componentId)
        end
      end
    end
  else entities[1] = canonical(expandBase(decoded), topicInfo, discoveryTopic) end
  if #entities == 0 then return nil, "no_valid_entities" end
  return entities, nil, {topic=topicInfo, raw=decoded}
end

return DiscoveryNormalize
