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
  return setmetatable({parent=parent,scope=nil,externalId=nil,revision=0,lastSignature=nil},ApprovalUI)
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

function ApprovalUI:_renderSelection()
  local entity=self:selectedEntity()
  if not entity then
    self:_view("approvalSelection","text","Selected: none")
    self:_view("btnApproveEntity","text","Create selected")
    self:_view("btnDeleteEntity","text","Delete from HC3")
    return
  end
  local child=entity.childId and tostring(entity.childId) or "not created"
  self:_view("approvalSelection","text",string.format("Selected: %s · %s · %s · HC3 %s",
    tostring(entity.name),tostring(entity.component),ApprovalManager.stateLabel(entity),child))
  local buttonText=entity.approvalState==ApprovalManager.DISABLED and "Reactivate selected" or
    entity.approvalState==ApprovalManager.ACTIVE and "Already active" or "Create selected"
  self:_view("btnApproveEntity","text",buttonText)
  local armed=self.deleteCandidate==entity.externalId and os.time()<=tonumber(self.deleteExpires or 0)
  self:_view("btnDeleteEntity","text",armed and "Confirm delete" or "Delete from HC3")
end

function ApprovalUI:refresh(force)
  local scopeOptions,counts=self:_scopeOptions()
  if not optionContains(scopeOptions,self.scope) then
    self.scope=counts.pending>0 and "filter:pending" or "filter:all"
  end
  local entities=self:_entities()
  local entityOptions=self:_entityOptions(entities)
  if not optionContains(entityOptions,self.externalId) then
    self.externalId=entityOptions[1] and entityOptions[1].value or nil
  end
  local signatureParts={self.scope,tostring(self.externalId),
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
  self:_renderSelection()

  -- HC3 installs select options asynchronously. Reassert the selection once
  -- so the browser does not remain on its generic Select placeholder.
  self.revision=self.revision+1
  local revision=self.revision
  if setTimeout then setTimeout(function()
    if revision==self.revision then
      self:_view("approvalDevice","selectedItem",self.scope)
      self:_view("approvalEntity","selectedItem",self.externalId or "")
    end
  end,250) end
end

function ApprovalUI:deviceChanged(event)
  local value=tostring(firstEventValue(event) or "")
  if value=="" then return end
  self.scope=value; self.externalId=nil; self.deleteCandidate=nil; self:refresh(true)
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
    self:_view("btnDeleteEntity","text","Confirm delete")
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

return ApprovalUI
