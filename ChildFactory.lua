-- Reconciles persisted external identities with HC3 child devices. A child is
-- recreated only when its required HC3 base type actually changes.
ChildFactory = {}
ChildFactory.__index = ChildFactory

function ChildFactory.new(options)
  return setmetatable({parent=options.parent,registry=options.registry,logger=options.logger,
    orphans={}},ChildFactory)
end

local function childConstructors()
  local types={"com.fibaro.device","com.fibaro.binarySensor","com.fibaro.binarySwitch",
    "com.fibaro.multilevelSensor","com.fibaro.multilevelSwitch","com.fibaro.temperatureSensor",
    "com.fibaro.humiditySensor","com.fibaro.rollerShutter"}
  local map={}
  for _,deviceType in ipairs(types) do map[deviceType]=function(device) return BridgeChild(device) end end
  return map
end

function ChildFactory:restore()
  self.parent:initChildDevices(childConstructors())
  for id,child in pairs(self.parent.childDevices or {}) do
    local externalId=child:getVariable("mqttDiscoveryId")
    local entity=self.registry:get(externalId)
    if externalId~="" and entity then
      entity.childId=id; self.registry.byChild[tonumber(id)]=externalId; child.parent=self.parent
    else self.orphans[id]=true end
  end
end

local function metadataVariables(entity)
  return Utils.mapToQvars({mqttDiscoveryId=entity.externalId,mqttUniqueId=entity.uniqueId,
    mqttComponent=entity.component,mqttDiscoveryTopic=entity.discoveryTopic,
    mqttDeviceId=entity.device.identifiers and entity.device.identifiers[1] or "",
    mqttManufacturer=entity.device.manufacturer,mqttModel=entity.device.model,
    mqttOrigin=entity.origin and entity.origin.name or ""})
end

function ChildFactory:ensure(entity)
  local child=entity.childId and self.parent.childDevices[tonumber(entity.childId)] or nil
  local replacedChildId
  -- Create the replacement first. If HC3 rejects the new type, the currently
  -- working child remains intact and the discovery transaction can abort.
  if child and child.type~=entity.childType then
    replacedChildId=tonumber(entity.childId); entity.childId=nil; child=nil
  end
  if not child then
    local properties={quickAppVariables=metadataVariables(entity),dead=false}
    if entity.childType~="com.fibaro.device" then
      properties.value=(entity.component=="binary_sensor" or entity.component=="switch") and false or 0
    end
    local ok,result=pcall(function()
      return self.parent:createChildDevice({name=entity.name,type=entity.childType,
        initialProperties=properties,initialInterfaces={}},BridgeChild)
    end)
    if not ok or not result then return nil,"child_creation_failed: "..tostring(result) end
    child=result; entity.childId=child.id; self.registry.byChild[tonumber(child.id)]=entity.externalId
    self.logger("INFO","CHILD","created "..entity.name.." ("..child.id..")")
    if replacedChildId then
      pcall(api.delete,"/plugins/removeChildDevice/"..replacedChildId)
      self.parent.childDevices[replacedChildId]=nil; self.registry.byChild[replacedChildId]=nil
    end
  else
    child.parent=self.parent
    if child.name~=entity.name then pcall(function() child:setName(entity.name) end) end
    child:updateProperty("quickAppVariables",metadataVariables(entity))
  end
  return child
end

function ChildFactory:remove(entity)
  if not entity or not entity.childId then return true end
  local id=tonumber(entity.childId)
  local ok,result=pcall(api.delete,"/plugins/removeChildDevice/"..id)
  if ok then
    self.parent.childDevices[id]=nil; self.registry.byChild[id]=nil; entity.childId=nil
    self.logger("INFO","CHILD","removed child "..id)
  end
  return ok,result
end

function ChildFactory:deleteOrphans()
  local count=0
  for id in pairs(self.orphans) do
    local ok=pcall(api.delete,"/plugins/removeChildDevice/"..id)
    if ok then self.parent.childDevices[id]=nil; self.orphans[id]=nil; count=count+1 end
  end
  return count
end

return ChildFactory
