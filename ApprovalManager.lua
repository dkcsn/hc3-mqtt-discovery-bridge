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

return ApprovalManager
