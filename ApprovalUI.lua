-- HC3 presentation adapter for approval management. It renders two dependent
-- selects: a status/device scope followed by the entities inside that scope.
ApprovalUI = {}
ApprovalUI.__index = ApprovalUI

local function firstEventValue(event)
  if type(event)~="table" then return event end
  local values=event.values or event.value or event.selectedItems or event.selectedItem or {}
  if type(values)~="table" then return values end
  if type(values[1])=="table" then return values[1].value or values[1][1] end
  return values[1]
end

local function option(value,text) return {type="option",value=value,text=text} end

function ApprovalUI.new(parent)
  return setmetatable({parent=parent,scope=nil,externalId=nil,page=1,revision=0,
    lastSignature=nil,maintenance="none"},ApprovalUI)
end

function ApprovalUI:_view(name,property,value)
  local ok,err=pcall(self.parent.updateView,self.parent,name,property,value)
  if not ok then self.parent:_log("DEBUG","UI",name.."."..property..": "..tostring(err)) end
  return ok
end

function ApprovalUI:_scopeOptions()
  local entities=self.parent.registry and self.parent.registry.entities or {}
  local counts=ApprovalManager.counts(entities)
  local options={
    option("filter:pending","Pending approval ("..counts.pending..")"),
    option("filter:active","Active ("..counts.active..")"),
    option("filter:disabled","Disabled ("..counts.disabled..")"),
    option("filter:unsupported","Unsupported ("..counts.unsupported..")"),
    option("filter:all","All entities ("..counts.all..")"),
  }
  for _,group in ipairs(ApprovalManager.deviceGroups(entities)) do
    local suffix=group.pending>0 and (" · "..group.pending.." pending") or ""
    options[#options+1]=option("device:"..group.key,group.label.." ("..group.count..")"..suffix)
  end
  return options,counts
end

local function optionContains(options,value)
  for _,item in ipairs(options) do if item.value==value then return true end end
  return false
end

function ApprovalUI:_entities()
  return ApprovalManager.entitiesForScope(self.parent.registry and self.parent.registry.entities or {},self.scope)
end

function ApprovalUI:_entityOptions(entities)
  local options={}
  for _,entity in ipairs(entities) do
    options[#options+1]=option(entity.externalId,
      tostring(entity.name).." · "..tostring(entity.component).." · "..ApprovalManager.stateLabel(entity))
  end
  return options
end

function ApprovalUI:selectedEntity()
  return self.externalId and self.parent.registry:get(self.externalId) or nil
end

local function displayValue(value)
  if value==nil then return nil end
  if type(value)=="boolean" then return value and "On" or "Off" end
  if type(value)=="table" then return nil end
  local text=tostring(value)
  if #text>32 then text=text:sub(1,29).."..." end
  return text
end

function ApprovalUI:_selectionText(entity)
  if not entity then return "No entity selected" end
  local parts={tostring(entity.name),ApprovalManager.stateLabel(entity)}
  local child=entity.childId and self.parent.childDevices and self.parent.childDevices[tonumber(entity.childId)]
  if entity.childId then
    parts[#parts+1]="Child "..tostring(entity.childId)
    local dead=child and child.properties and child.properties.dead
    parts[#parts+1]=dead==true and "Offline" or "Online"
  else
    parts[#parts+1]="No HC3 child"
  end
  local lastValue=entity.lastValue
  if lastValue==nil and child and child.properties then lastValue=child.properties.value end
  local value=displayValue(lastValue)
  if value then
    local unit=entity.config and entity.config.unit_of_measurement
    parts[#parts+1]="Value "..value..(unit and unit~="" and " "..tostring(unit) or "")
  end
  return table.concat(parts," · ")
end

function ApprovalUI:_renderSelection()
  local entity=self:selectedEntity()
  if not entity then
    self:_view("approvalSelection","text","No entity selected")
    self:_view("btnEntityPrimary","text","Select an entity")
    self:_view("btnEntitySecondary","text","Entity details")
    return
  end
  self:_view("approvalSelection","text",self:_selectionText(entity))
  local primary=entity.approvalState==ApprovalManager.PENDING and "Create child" or
    entity.approvalState==ApprovalManager.ACTIVE and "Disable child" or
    entity.approvalState==ApprovalManager.DISABLED and "Reactivate child" or
    entity.approvalState==ApprovalManager.UNSUPPORTED and "Why unsupported?" or "Entity details"
  self:_view("btnEntityPrimary","text",primary)
  local armed=self.deleteCandidate==entity.externalId and os.time()<=tonumber(self.deleteExpires or 0)
  local secondary=entity.approvalState==ApprovalManager.PENDING and "Ignore entity" or
    entity.approvalState==ApprovalManager.DISABLED and entity.childId and
      (armed and "Confirm delete" or "Delete child") or "Entity details"
  self:_view("btnEntitySecondary","text",secondary)
end

function ApprovalUI:_bulkButtonText()
  local key=self.scope and self.scope:match("^device:(.+)$")
  if not key then return "Select MQTT device for bulk create" end
  local pending=0
  for _,entity in pairs(self.parent.registry and self.parent.registry.entities or {}) do
    if ApprovalManager.deviceKey(entity)==key and entity.supported and
       entity.approvalState==ApprovalManager.PENDING then pending=pending+1 end
  end
  if pending==0 then return "No pending children" end
  return "Create "..pending.." pending "..(pending==1 and "child" or "children")
end

function ApprovalUI:_maintenanceOptions(orphanCount)
  local options={
    option("none","Select operation"),
    option("details","Entity details"),
    option("probe","Probe selected entity (30 sec)"),
    option("request","Request MQTT discovery"),
    option("reconnect","Reconnect MQTT"),
    option("reload","Reload entity registry"),
    option("summary","Write debug summary to log"),
  }
  if orphanCount>0 then
    options[#options+1]=option("cleanup","Clean "..orphanCount.." orphan "..(orphanCount==1 and "child" or "children"))
  end
  return options
end

function ApprovalUI:refresh(force)
  local scopeOptions,counts=self:_scopeOptions()
  if not optionContains(scopeOptions,self.scope) then
    self.scope=counts.pending>0 and "filter:pending" or "filter:all"
  end
  local entities=self:_entities()
  local pageSize=self.parent.config and self.parent.config.approvalPageSize or Constants.APPROVAL_PAGE_SIZE
  local pageEntities,page,pages,total=ApprovalManager.page(entities,self.page,pageSize)
  self.page=page
  local entityOptions=self:_entityOptions(pageEntities)
  if not optionContains(entityOptions,self.externalId) then
    self.externalId=entityOptions[1] and entityOptions[1].value or nil
  end
  local signatureParts={self.scope,tostring(self.externalId),tostring(page)..":"..tostring(pages),
    tostring(counts.all)..":"..tostring(counts.active)..":"..tostring(counts.pending)..":"..
    tostring(counts.disabled)..":"..tostring(counts.unsupported)}
  for _,item in ipairs(scopeOptions) do signatureParts[#signatureParts+1]=item.value.."="..item.text end
  for _,item in ipairs(entityOptions) do signatureParts[#signatureParts+1]=item.value.."="..item.text end
  local signature=table.concat(signatureParts,"|")
  if force or signature~=self.lastSignature then
    self.lastSignature=signature
    self:_view("approvalDevice","options",scopeOptions)
    self:_view("approvalEntity","options",entityOptions)
  end
  self:_view("approvalDevice","selectedItem",self.scope)
  self:_view("approvalEntity","selectedItem",self.externalId or "")
  local first=total==0 and 0 or ((page-1)*pageSize+1)
  local last=math.min(total,page*pageSize)
  self:_view("approvalPage","text",string.format("Page %d/%d · showing %d–%d of %d",page,pages,first,last,total))
  self:_view("btnApprovalPrev","text",page>1 and "Previous page" or "Previous (start)")
  self:_view("btnApprovalNext","text",page<pages and "Next page" or "Next (end)")
  local orphanCount=self.parent.childFactory and self.parent.childFactory:orphanCount() or 0
  local maintenanceOptions=self:_maintenanceOptions(orphanCount)
  if not optionContains(maintenanceOptions,self.maintenance) then self.maintenance="none" end
  self:_view("maintenanceAction","options",maintenanceOptions)
  self:_view("maintenanceAction","selectedItem",self.maintenance)
  self:_view("btnMaintenanceRun","text",
    self.maintenance=="cleanup" and self.cleanupExpires and os.time()<=self.cleanupExpires and
      "Confirm orphan cleanup" or "Run maintenance")
  self:_view("btnApproveDevice","text",self:_bulkButtonText())
  self:_renderSelection()

  -- HC3 installs select options asynchronously. Reassert the selection once
  -- so the browser does not remain on its generic Select placeholder.
  self.revision=self.revision+1
  local revision=self.revision
  if setTimeout then setTimeout(function()
    if revision==self.revision then
      self:_view("approvalDevice","selectedItem",self.scope)
      self:_view("approvalEntity","selectedItem",self.externalId or "")
      self:_view("maintenanceAction","selectedItem",self.maintenance)
    end
  end,250) end
end

function ApprovalUI:deviceChanged(event)
  local value=tostring(firstEventValue(event) or "")
  if value=="" then return end
  self.scope=value; self.externalId=nil; self.page=1; self.deleteCandidate=nil; self:refresh(true)
end

function ApprovalUI:previousPage()
  self.page=math.max(1,(self.page or 1)-1); self.externalId=nil; self:refresh(true)
end

function ApprovalUI:nextPage()
  self.page=(self.page or 1)+1; self.externalId=nil; self:refresh(true)
end

function ApprovalUI:cleanupOrphans()
  local count=self.parent.childFactory and self.parent.childFactory:orphanCount() or 0
  if count==0 then self:_view("approvalSelection","text","No orphaned children found"); return true,0 end
  local now=os.time()
  if not self.cleanupExpires or now>self.cleanupExpires then
    self.cleanupExpires=now+10
    self:refresh(true)
    self:_view("approvalSelection","text","Press Confirm orphan cleanup within 10 seconds to remove "..count.." orphaned child device(s)")
    return false,"confirmation_required"
  end
  self.cleanupExpires=nil
  local ok,result,removed=self.parent:deleteOrphanedDevices()
  self.maintenance="none"
  self:refresh(true)
  if not ok then return false,result,removed end
  return true,result
end

function ApprovalUI:entityChanged(event)
  local value=tostring(firstEventValue(event) or "")
  if value=="" or not self.parent.registry:get(value) then return end
  self.externalId=value; self.deleteCandidate=nil; self:refresh(true)
end

function ApprovalUI:approveSelected()
  local entity=self:selectedEntity()
  if not entity then return false,"entity_not_selected" end
  local ok,err=self.parent:setEntityApproval(entity.externalId,ApprovalManager.ACTIVE)
  self:refresh(true)
  return ok,err
end

-- The primary and secondary buttons follow the selected entity's lifecycle.
-- This keeps normal approval work visible without exposing maintenance and
-- destructive operations as a permanent wall of buttons.
function ApprovalUI:primarySelected()
  local entity=self:selectedEntity()
  if not entity then return false,"entity_not_selected" end
  if entity.approvalState==ApprovalManager.PENDING or
     entity.approvalState==ApprovalManager.DISABLED then return self:approveSelected() end
  if entity.approvalState==ApprovalManager.ACTIVE then return self:disableSelected() end
  return self:details()
end

function ApprovalUI:secondarySelected()
  local entity=self:selectedEntity()
  if not entity then return false,"entity_not_selected" end
  if entity.approvalState==ApprovalManager.PENDING then return self:disableSelected() end
  if entity.approvalState==ApprovalManager.DISABLED and entity.childId then return self:deleteSelected() end
  return self:details()
end

function ApprovalUI:approveDevice()
  local key=self.scope and self.scope:match("^device:(.+)$")
  if not key then
    self:_view("approvalSelection","text","Choose a physical device before bulk creation")
    return false,"device_not_selected"
  end
  local ok,result=self.parent:approveDevice(key)
  self:refresh(true)
  return ok,result
end

function ApprovalUI:maintenanceChanged(event)
  local value=tostring(firstEventValue(event) or "")
  if value=="" then return end
  self.maintenance=value
  self.cleanupExpires=nil
  self:refresh(true)
end

function ApprovalUI:runMaintenance()
  local action=self.maintenance or "none"
  if action=="none" then
    self:_view("approvalSelection","text","Choose a maintenance operation first")
    return false,"maintenance_not_selected"
  end
  if action=="details" then return self:details() end
  if action=="probe" then return self:probeSelected() end
  if action=="cleanup" then return self:cleanupOrphans() end
  local handlers={
    request=function() return self.parent:requestDiscovery() end,
    reconnect=function() return self.parent:reconnect() end,
    reload=function() return self.parent:reloadRegistry() end,
    summary=function() return true,self.parent:debugSummary() end,
  }
  local handler=handlers[action]
  if not handler then return false,"unknown_maintenance_action" end
  local ok,result=handler()
  self.maintenance="none"
  self:refresh(true)
  self:_view("approvalSelection","text",ok and "Maintenance operation started" or
    "Maintenance failed · "..tostring(result))
  return ok,result
end

function ApprovalUI:disableSelected()
  local entity=self:selectedEntity()
  if not entity then return false,"entity_not_selected" end
  local ok,err=self.parent:setEntityApproval(entity.externalId,ApprovalManager.DISABLED)
  self:refresh(true)
  return ok,err
end

function ApprovalUI:deleteSelected()
  local entity=self:selectedEntity()
  if not entity then return false,"entity_not_selected" end
  local now=os.time()
  if self.deleteCandidate~=entity.externalId or now>tonumber(self.deleteExpires or 0) then
    self.deleteCandidate=entity.externalId
    self.deleteExpires=now+10
    self:_view("approvalSelection","text","Press Confirm delete within 10 seconds to remove the HC3 child")
    self:_view("btnEntitySecondary","text","Confirm delete")
    local candidate=entity.externalId
    if setTimeout then setTimeout(function()
      if self.deleteCandidate==candidate and os.time()>tonumber(self.deleteExpires or 0) then
        self.deleteCandidate=nil; self:refresh(true)
      end
    end,10500) end
    return false,"confirmation_required"
  end
  self.deleteCandidate=nil
  local ok,err=self.parent:deleteEntityChild(entity.externalId)
  self:refresh(true)
  return ok,err
end

function ApprovalUI:details()
  local entity=self:selectedEntity()
  if not entity then return false,"entity_not_selected" end
  local details={
    name=entity.name,externalId=entity.externalId,component=entity.component,
    approvalState=entity.approvalState,childId=entity.childId,device=entity.device,
    discoveryTopic=entity.discoveryTopic,stateTopic=entity.stateTopic,
    commandTopic=entity.commandTopic,supported=entity.supported,
  }
  local encoded=Utils.encodeJson(details) or tostring(entity.externalId)
  self.parent:debug("[ENTITY DETAILS] "..encoded)
  self:_view("approvalSelection","text",string.format("%s · %s · %s · details written to log",
    tostring(entity.name),tostring(entity.component),ApprovalManager.stateLabel(entity)))
  return true,details
end

function ApprovalUI:probeSelected()
  local entity=self:selectedEntity()
  if not entity then return false,"entity_not_selected" end
  local ok,result=self.parent:probeEntity(entity.externalId)
  if ok then
    self:_view("approvalSelection","text","Probe armed for 30 seconds · "..tostring(entity.name))
  else
    self:_view("approvalSelection","text","Probe could not start · "..tostring(result))
  end
  return ok,result
end

return ApprovalUI
