-- Pure approval and grouping rules for discovered MQTT entities. This module
-- deliberately knows nothing about HC3 views or child-device APIs, which keeps
-- state transitions deterministic and independently testable.
ApprovalManager = {}

ApprovalManager.ACTIVE = "active"
ApprovalManager.PENDING = "pending"
ApprovalManager.DISABLED = "disabled"
ApprovalManager.UNSUPPORTED = "unsupported"

local validState = {
  active=true, pending=true, disabled=true, unsupported=true,
}

local function lower(value) return tostring(value or ""):lower() end

-- Stable semantic groups keep large discovery devices navigable without
-- coupling the UI to one producer's entity names. Home Assistant metadata is
-- authoritative; textual matching is only a fallback for incomplete configs.
local entityGroupDefinitions = {
  {key="live_power",label="Live power"},
  {key="energy_totals",label="Energy totals"},
  {key="voltage_current",label="Voltage & current"},
  {key="power_quality",label="Power quality"},
  {key="prices_cost",label="Prices & cost"},
  {key="forecasts_peaks",label="Forecasts & peaks"},
  {key="environment",label="Environment"},
  {key="controls",label="Controls"},
  {key="diagnostics",label="Diagnostics"},
  {key="other",label="Other"},
}

local groupLabels={all="All entities"}
local groupOrder={}
for index,definition in ipairs(entityGroupDefinitions) do
  groupLabels[definition.key]=definition.label
  groupOrder[definition.key]=index
end

local function oneOf(value,values)
  for _,candidate in ipairs(values) do if value==candidate then return true end end
  return false
end

local function containsAny(value,needles)
  for _,needle in ipairs(needles) do if value:find(needle,1,true) then return true end end
  return false
end

function ApprovalManager.entityGroupKey(entity)
  local config=entity.config or {}
  local component=lower(entity.component)
  local deviceClass=lower(config.device_class or entity.deviceClass)
  local unit=lower(config.unit_of_measurement):gsub("%s+","")
  local category=lower(config.entity_category)
  local name=lower((entity.name or "").." "..(entity.objectId or "").." "..(entity.externalId or ""))

  if oneOf(component,{"switch","light","cover","button","number","select","siren","fan","lock","climate"}) then
    return "controls"
  end
  if category=="diagnostic" or oneOf(deviceClass,{"battery","connectivity","duration","enum",
      "signal_strength","timestamp","data_rate","data_size"}) then return "diagnostics" end
  if oneOf(deviceClass,{"monetary"}) then return "prices_cost" end
  if oneOf(deviceClass,{"power","apparent_power","reactive_power"}) then return "live_power" end
  if oneOf(deviceClass,{"energy","energy_storage","gas","water"}) then return "energy_totals" end
  if oneOf(deviceClass,{"current","voltage"}) then return "voltage_current" end
  if oneOf(deviceClass,{"frequency","power_factor"}) then return "power_quality" end
  if oneOf(deviceClass,{"temperature","humidity","pressure","atmospheric_pressure","illuminance",
      "carbon_dioxide","carbon_monoxide","volatile_organic_compounds","volatile_organic_compounds_parts",
      "pm1","pm10","pm25","nitrogen_dioxide","nitrogen_monoxide","nitrous_oxide","ozone",
      "sulphur_dioxide","wind_speed","precipitation","precipitation_intensity","moisture"}) then
    return "environment"
  end

  -- Units are more reliable than translated display names when device_class
  -- is omitted. Test energy before power because kWh also contains a W.
  if containsAny(unit,{"kwh","mwh","wh","m³","m3","ft³","ft3"}) then return "energy_totals" end
  if oneOf(unit,{"w","kw","mw","va","kva","var","kvar"}) then return "live_power" end
  if oneOf(unit,{"v","mv","a","ma"}) then return "voltage_current" end
  if oneOf(unit,{"hz","%"}) and containsAny(name,{"frequency","power factor","pf"}) then return "power_quality" end
  if containsAny(unit,{"°c","°f","ppm","µg/m³","ug/m3","lx","hpa"}) then return "environment" end

  if containsAny(name,{"forecast","cheapest","expensive","period ahead"," peak"}) then return "forecasts_peaks" end
  if containsAny(name,{"price","cost","tariff","currency"}) then return "prices_cost" end
  if containsAny(name,{"voltage"," current","current l","ampere"}) then return "voltage_current" end
  if containsAny(name,{"power factor","frequency","reactive","apparent"}) then return "power_quality" end
  if containsAny(name,{"power","active import","active export","watt"}) then return "live_power" end
  if containsAny(name,{"energy","accumulated","meter reading","used","usage","consumption"}) then return "energy_totals" end
  if containsAny(name,{"temperature","humidity","pressure","co2","illuminance","air quality"}) then return "environment" end
  if containsAny(name,{"uptime","timestamp","last seen","age","rssi","signal","firmware","online","status"}) then
    return "diagnostics"
  end
  return "other"
end

function ApprovalManager.entityGroupLabel(key)
  key=tostring(key or "all"):gsub("^group:","")
  return groupLabels[key] or groupLabels.other
end

function ApprovalManager.matchesEntityGroup(entity,group)
  local key=tostring(group or "group:all"):gsub("^group:","")
  return key=="all" or ApprovalManager.entityGroupKey(entity)==key
end

function ApprovalManager.entityGroups(entities)
  local grouped={}
  local total,pending=0,0
  for _,entity in ipairs(entities or {}) do
    local key=ApprovalManager.entityGroupKey(entity)
    local group=grouped[key]
    if not group then group={key=key,label=ApprovalManager.entityGroupLabel(key),count=0,pending=0}; grouped[key]=group end
    group.count=group.count+1; total=total+1
    if entity.approvalState==ApprovalManager.PENDING then group.pending=group.pending+1; pending=pending+1 end
  end
  local result={{key="all",label=groupLabels.all,count=total,pending=pending}}
  for _,group in pairs(grouped) do result[#result+1]=group end
  table.sort(result,function(a,b)
    if a.key=="all" then return true end
    if b.key=="all" then return false end
    return (groupOrder[a.key] or 999)<(groupOrder[b.key] or 999)
  end)
  return result
end

function ApprovalManager.entitiesForGroup(entities,group)
  local result={}
  for _,entity in ipairs(entities or {}) do
    if ApprovalManager.matchesEntityGroup(entity,group) then result[#result+1]=entity end
  end
  return result
end

function ApprovalManager.normalizeMode(value)
  value=lower(value)
  if value=="approval" then return "approval" end
  return "automatic"
end

-- Preserve an explicit user choice across discovery updates. Pending entities
-- become active if the operator changes the global mode back to automatic;
-- explicitly disabled entities always remain disabled.
function ApprovalManager.nextState(entity,previous,mode)
  if not entity.supported then return ApprovalManager.UNSUPPORTED end
  local old=previous and previous.approvalState
  if old==ApprovalManager.DISABLED then return old end
  if old==ApprovalManager.ACTIVE then return old end
  if old==ApprovalManager.PENDING and ApprovalManager.normalizeMode(mode)=="approval" then return old end
  if previous and previous.childId then return ApprovalManager.ACTIVE end
  return ApprovalManager.normalizeMode(mode)=="approval" and ApprovalManager.PENDING or ApprovalManager.ACTIVE
end

function ApprovalManager.restoreState(entity,mode)
  if not entity.supported then return ApprovalManager.UNSUPPORTED end
  local state=entity.approvalState
  if not validState[state] or state==ApprovalManager.UNSUPPORTED then
    state=entity.childId and ApprovalManager.ACTIVE or
      (ApprovalManager.normalizeMode(mode)=="approval" and ApprovalManager.PENDING or ApprovalManager.ACTIVE)
  end
  if state==ApprovalManager.PENDING and ApprovalManager.normalizeMode(mode)=="automatic" then
    return ApprovalManager.ACTIVE
  end
  return state
end

function ApprovalManager.deviceKey(entity)
  local device=entity.device or {}
  local identifiers=device.identifiers or {}
  if identifiers[1] and tostring(identifiers[1])~="" then return "id:"..tostring(identifiers[1]) end
  if entity.nodeId and tostring(entity.nodeId)~="" then return "node:"..tostring(entity.nodeId) end
  if device.name and tostring(device.name)~="" then return "name:"..tostring(device.name) end
  return "ungrouped"
end

function ApprovalManager.deviceLabel(entity)
  local device=entity.device or {}
  if device.name and tostring(device.name)~="" then return tostring(device.name) end
  if entity.nodeId and tostring(entity.nodeId)~="" then return tostring(entity.nodeId) end
  local identifiers=device.identifiers or {}
  if identifiers[1] and tostring(identifiers[1])~="" then return tostring(identifiers[1]) end
  return "Without device information"
end

function ApprovalManager.counts(entities)
  local result={all=0,active=0,pending=0,disabled=0,unsupported=0}
  for _,entity in pairs(entities or {}) do
    result.all=result.all+1
    local state=entity.approvalState
    if result[state]~=nil then result[state]=result[state]+1 end
  end
  return result
end

function ApprovalManager.deviceGroups(entities)
  local groups={}
  for _,entity in pairs(entities or {}) do
    local key=ApprovalManager.deviceKey(entity)
    local group=groups[key]
    if not group then
      group={key=key,label=ApprovalManager.deviceLabel(entity),count=0,pending=0}
      groups[key]=group
    end
    group.count=group.count+1
    if entity.approvalState==ApprovalManager.PENDING then group.pending=group.pending+1 end
  end
  local result={}
  for _,group in pairs(groups) do result[#result+1]=group end
  table.sort(result,function(a,b)
    local al,bl=lower(a.label),lower(b.label)
    return al==bl and a.key<b.key or al<bl
  end)
  return result
end

local function matchesFilter(entity,filter)
  if filter=="all" then return true end
  return entity.approvalState==filter
end

function ApprovalManager.entitiesForScope(entities,scope)
  local result={}
  local filter=scope and scope:match("^filter:(.+)$")
  local deviceKey=scope and scope:match("^device:(.+)$")
  for _,entity in pairs(entities or {}) do
    if (filter and matchesFilter(entity,filter)) or
       (deviceKey and ApprovalManager.deviceKey(entity)==deviceKey) then
      result[#result+1]=entity
    end
  end
  table.sort(result,function(a,b)
    local an,bn=lower(a.name),lower(b.name)
    if an~=bn then return an<bn end
    if tostring(a.component)~=tostring(b.component) then return tostring(a.component)<tostring(b.component) end
    return tostring(a.externalId)<tostring(b.externalId)
  end)
  return result
end

function ApprovalManager.stateLabel(entity)
  local labels={active="Active",pending="Pending approval",disabled="Disabled",unsupported="Unsupported"}
  return labels[entity and entity.approvalState] or "Unknown"
end

-- Return one stable page without mutating the caller's sorted collection.
-- HC3 select controls become difficult to use with hundreds of options.
function ApprovalManager.page(items,page,pageSize)
  pageSize=math.max(1,math.floor(tonumber(pageSize) or Constants.APPROVAL_PAGE_SIZE))
  local total=#(items or {})
  local pages=math.max(1,math.ceil(total/pageSize))
  page=math.max(1,math.min(pages,math.floor(tonumber(page) or 1)))
  local result={}
  local first=(page-1)*pageSize+1
  for index=first,math.min(total,first+pageSize-1) do result[#result+1]=items[index] end
  return result,page,pages,total
end

return ApprovalManager
