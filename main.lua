--%%name:HC3 MQTT Discovery Bridge
-- Licensed under PolyForm Noncommercial 1.0.0:
-- https://polyformproject.org/licenses/noncommercial/1.0.0
-- Required Notice: Copyright 2026 dkcsn.
-- The concrete controller type is required for the parent to appear in the
-- HC3 Devices UI. com.fibaro.device is only the abstract base type: HC3 will
-- run a QA uploaded with it, but the resulting device has no GUI category.
--%%type:com.fibaro.deviceController
--%%description:HC3 MQTT Discovery Bridge v0.3.1 — scalable discovery approval and native child devices
--%%desktop:true
--%%file:./Constants.lua,Constants
--%%file:./Utils.lua,Utils
--%%file:./TemplateParser.lua,TemplateParser
--%%file:./TemplateEvaluator.lua,TemplateEvaluator
--%%file:./TemplateEngine.lua,TemplateEngine
--%%file:./DiscoveryNormalize.lua,DiscoveryNormalize
--%%file:./Discovery.lua,Discovery
--%%file:./SubscriptionRegistry.lua,SubscriptionRegistry
--%%file:./EntityMapper.lua,EntityMapper
--%%file:./EntityRegistry.lua,EntityRegistry
--%%file:./ApprovalManager.lua,ApprovalManager
--%%file:./ApprovalUI.lua,ApprovalUI
--%%file:./MQTTClient.lua,MQTTClient
--%%file:./ChildClasses.lua,ChildClasses
--%%file:./ChildFactory.lua,ChildFactory
--%%file:./IconRegistry.lua,IconRegistry
--%%file:./IconData.lua,IconData
--%%file:./IconInstaller.lua,IconInstaller
--%%var:brokerHost=""
--%%var:brokerPort="1883"
--%%var:username=""
--%%var:password=""
--%%var:tls="false"
--%%var:clientId="hc3-mqtt-discovery"
--%%var:discoveryPrefix="homeassistant"
--%%var:discoveryQoS="0"
--%%var:publishHABirth="true"
--%%var:logLevel="INFO"
--%%var:discoveryMode="automatic"
--%%var:approvalPageSize="40"
--%%var:birthDelayMax="5"
--%%var:mqttEntityRegistry=""
--%%u:{label="mqttStatus",text="MQTT: Starting"}
--%%u:{label="brokerStatus",text="Broker: not configured"}
--%%u:{label="discoveryStatus",text="Discovery: homeassistant"}
--%%u:{label="entityStatus",text="Entities: 0"}
--%%u:{label="subscriptionStatus",text="Subscriptions: 0"}
--%%u:{label="activityStatus",text="Last activity: never"}
--%%u:{label="approvalStatus",text="Approval: Automatic"}
--%%u:{select="approvalDevice",text="Filter or MQTT device",value="",onToggled="approvalDeviceChanged",options={}}
--%%u:{select="approvalEntity",text="Entity",value="",onToggled="approvalEntityChanged",options={}}
--%%u:{label="approvalPage",text="Page 1/1"}
--%%u:{{button="btnApprovalPrev",text="Previous (start)",onReleased="approvalPreviousPage"},{button="btnApprovalNext",text="Next (end)",onReleased="approvalNextPage"}}
--%%u:{label="approvalSelection",text="Selected: none"}
--%%u:{{button="btnApproveEntity",text="Create selected",onReleased="approveSelectedEntity"},{button="btnApproveDevice",text="Create all from device",onReleased="approveSelectedDevice"}}
--%%u:{{button="btnDisableEntity",text="Disable selected",onReleased="disableSelectedEntity"},{button="btnDeleteEntity",text="Delete from HC3",onReleased="deleteSelectedEntity"}}
--%%u:{button="btnEntityDetails",text="Entity details",onReleased="selectedEntityDetails"}
--%%u:{button="btnCleanupOrphans",text="Clean orphans (0)",onReleased="cleanupOrphanedDevices"}
--%%u:{{button="btnReconnect",text="Reconnect",onReleased="reconnect"},{button="btnDiscover",text="Request Discovery",onReleased="requestDiscovery"}}
--%%u:{{button="btnReload",text="Reload Registry",onReleased="reloadRegistry"},{button="btnSummary",text="Debug Summary",onReleased="debugSummary"}}

-- main.lua is intentionally composition-only. Protocol parsing, transport,
-- persistence, templates and HC3 mappings remain independently testable files.
local function variable(self,name,default)
  -- Reading a missing value with getVariable() writes an HC3 warning. Looking
  -- through the property list keeps new optional settings backward-compatible.
  local values=self.properties and self.properties.quickAppVariables or {}
  for _,item in ipairs(values) do
    if item.name==name then return (item.value==nil or item.value=="") and default or item.value end
  end
  return default
end

function QuickApp:_readConfig()
  return {
    brokerHost=tostring(variable(self,"brokerHost",Constants.DEFAULTS.brokerHost)),
    brokerPort=math.floor(Utils.number(variable(self,"brokerPort",Constants.DEFAULTS.brokerPort),1883)),
    username=tostring(variable(self,"username",Constants.DEFAULTS.username)),
    password=tostring(variable(self,"password",Constants.DEFAULTS.password)),
    tls=Utils.bool(variable(self,"tls",Constants.DEFAULTS.tls),false),
    clientId=tostring(variable(self,"clientId",Constants.DEFAULTS.clientId)),
    discoveryPrefix=tostring(variable(self,"discoveryPrefix",Constants.DEFAULTS.discoveryPrefix)),
    discoveryQoS=math.floor(Utils.clamp(Utils.number(variable(self,"discoveryQoS",0),0),0,2)),
    publishHABirth=Utils.bool(variable(self,"publishHABirth",true),true),
    logLevel=tostring(variable(self,"logLevel",Constants.DEFAULTS.logLevel)):upper(),
    discoveryMode=ApprovalManager.normalizeMode(variable(self,"discoveryMode",Constants.DEFAULTS.discoveryMode)),
    approvalPageSize=math.floor(Utils.clamp(Utils.number(variable(self,"approvalPageSize",40),40),10,100)),
    birthDelayMax=math.floor(Utils.clamp(Utils.number(variable(self,"birthDelayMax",5),5),0,60)),
  }
end

function QuickApp:_log(level,area,message)
  local configured=Constants.LOG_LEVELS[self.config.logLevel] or Constants.LOG_LEVELS.INFO
  if (Constants.LOG_LEVELS[level] or 99)>configured then return end
  local text="["..area.."] "..tostring(message)
  if level=="ERROR" then self:error(text)
  elseif level=="WARNING" then self:warning(text)
  elseif level=="DEBUG" or level=="TRACE" then self:debug(text)
  else self:debug(text) end
end

function QuickApp:onInit()
  self.config=self:_readConfig()
  if self.config.clientId==Constants.DEFAULTS.clientId then self.config.clientId=self.config.clientId.."-"..tostring(self.id) end
  self.metrics={stateUpdates=0,availabilityUpdates=0,attributeUpdates=0,lastActivity=nil}
  self.unsupportedLogged={}
  self:debug(Constants.NAME.." v"..Constants.VERSION)
  -- Expose release identity through standard HC3 device metadata. This makes
  -- the installed version visible without opening source code or logs.
  self:updateProperty("manufacturer","FIBARO Community")
  self:updateProperty("model",Constants.NAME.." v"..Constants.VERSION)
  self:updateProperty("quickAppUuid",Constants.UUID)
  local function logger(level,area,message) self:_log(level,area,message) end
  self.templateEngine=TemplateEngine.new({logger=logger})
  self.registry=EntityRegistry.new({parent=self,logger=logger})
  local loaded,loadError=self.registry:load()
  if not loaded then logger("WARNING","ENTITY","registry ignored: "..tostring(loadError)) end
  self.childFactory=ChildFactory.new({parent=self,registry=self.registry,logger=logger})
  self.childFactory:restore()
  self.approvalUI=ApprovalUI.new(self)

  self.mqtt=MQTTConnection.new({config=self.config,logger=logger,
    onConnected=function(event) self:_mqttConnected(event) end,
    onDisconnected=function() self:_mqttDisconnected() end,
    onMessage=function(topic,payload,event) self:_mqttMessage(topic,payload,event) end})
  self.subscriptions=SubscriptionRegistry.new({logger=logger,
    subscribe=function(topic,qos) return self.mqtt:subscribe(topic,qos) end,
    unsubscribe=function(topic) return self.mqtt:unsubscribe(topic) end})
  self.discovery=Discovery.new({prefix=self.config.discoveryPrefix,logger=logger,
    onUpsert=function(entity,prepareOnly) return self:_upsertEntity(entity,prepareOnly) end,
    onRemove=function(externalId,topic) return self:_removeEntity(externalId,topic) end,
    onTransactionComplete=function(topic,operation) self:_discoveryTransactionComplete(topic,operation) end})

  self:_restoreEntities()
  if self.registry.dirty then self:_persistRegistry("startup migration") end
  self:_applyRegisteredIcon()
  self:_updateUI(true)
  self.mqtt:connect()
end

function QuickApp:_restoreEntities()
  local restored={}
  for externalId,entity in pairs(self.registry.entities) do
    local prepared,err=EntityMapper.prepare(entity,self.templateEngine)
    if prepared then
      prepared.approvalState=ApprovalManager.restoreState(prepared,self.config.discoveryMode)
      restored[externalId]=prepared
      if prepared.supported and prepared.approvalState==ApprovalManager.ACTIVE then
        local child,childError=self.childFactory:ensure(prepared)
        if child then self:_attachSubscriptions(prepared)
        else self:_log("ERROR","CHILD",externalId.." restore failed: "..tostring(childError)) end
      elseif prepared.approvalState==ApprovalManager.DISABLED and prepared.childId then
        local child=self.childDevices[tonumber(prepared.childId)]
        if child then
          child:updateProperty("dead",true)
          child:updateProperty("deadReason","Disabled in MQTT Discovery Bridge")
        end
      end
    else self:_log("WARNING","ENTITY",externalId.." restore failed: "..tostring(err)) end
  end
  self.registry.entities=restored
  self.discovery:restore(restored)
end

function QuickApp:_applyRegisteredIcon()
  self.iconRegistry=IconRegistry.new({uuid=Constants.UUID,appName=Constants.NAME,iconName="main"})
  self.iconInstaller=IconInstaller.new({parent=self,registry=self.iconRegistry,pngHex=IconData,
    deviceType="com.fibaro.deviceController",logger=function(level,area,message) self:_log(level,area,message) end})
  self.iconInstaller:ensure()
end

function QuickApp:_mqttConnected()
  local prefix,qos=self.config.discoveryPrefix,self.config.discoveryQoS
  self.mqtt:subscribe(prefix.."/+/+/config",qos)
  self.mqtt:subscribe(prefix.."/+/+/+/config",qos)
  self.subscriptions:restoreSubscriptions()
  if self.config.publishHABirth then
    local delay=math.random(0,self.config.birthDelayMax)*1000
    if self.birthTimer then clearTimeout(self.birthTimer) end
    self.birthTimer=setTimeout(function() self.birthTimer=nil; if self.mqtt.connected then self:requestDiscovery() end end,delay)
  end
  self:_updateUI(true)
end

function QuickApp:_mqttDisconnected() self:_updateUI(true) end

function QuickApp:_mqttMessage(topic,payload,event)
  self.metrics.lastActivity=os.time()
  local discoveryInfo=DiscoveryNormalize.parseTopic(topic,self.config.discoveryPrefix)
  if discoveryInfo then self.discovery:process(topic,payload)
  elseif #payload<=Constants.MAX_STATE_PAYLOAD then self.subscriptions:dispatch(topic,payload,event)
  else self:_log("WARNING","MQTT","oversized state payload ignored on "..topic) end
  self:_updateUI()
end

function QuickApp:_upsertEntity(entity,prepareOnly)
  local prepared,err=EntityMapper.prepare(entity,self.templateEngine)
  if not prepared then return false,err end
  if prepareOnly then return true,prepared end
  local old=self.registry:get(prepared.externalId)
  if not old and self.registry:count()>=Constants.MAX_ENTITIES then return false,"entity_limit_reached" end
  if old then prepared.childId=old.childId; prepared.lastValue=old.lastValue end
  prepared.approvalState=ApprovalManager.nextState(prepared,old,self.config.discoveryMode)
  if prepared.supported and prepared.approvalState==ApprovalManager.ACTIVE then
    local child,childError=self.childFactory:ensure(prepared)
    if not child then return false,childError end
  elseif not prepared.supported then
    if old and old.childId then self.childFactory:remove(old) end
    if not self.unsupportedLogged[prepared.component] then
      self.unsupportedLogged[prepared.component]=true
      self:_log("WARNING","ENTITY","parse-only component: "..tostring(prepared.component))
    end
  end
  if old then self.subscriptions:removeEntity(old.externalId) end
  self.registry:put(prepared)
  if prepared.supported and prepared.approvalState==ApprovalManager.ACTIVE then self:_attachSubscriptions(prepared) end
  return true,prepared
end

-- Discovery can expand one Device Discovery payload into many entities. The
-- transaction callback persists once after all children/subscriptions agree.
function QuickApp:_persistRegistry(context)
  if not self.registry or not self.registry.dirty then return true end
  local ok,err=self.registry:persist()
  if not ok then self:_log("ERROR","ENTITY","registry persistence failed after "..tostring(context)..": "..tostring(err)) end
  return ok,err
end

function QuickApp:_discoveryTransactionComplete(topic,operation)
  self:_persistRegistry(operation.." "..topic)
  self:_updateUI(true)
end

function QuickApp:_attachSubscriptions(entity)
  for _,topic in ipairs(EntityMapper.subscriptions(entity)) do
    if topic and topic~="" then
      self.subscriptions:addConsumer(topic,entity.externalId,function(payload,message)
        self:_entityMessage(entity.externalId,topic,payload,message)
      end,entity.qos)
    end
  end
end

function QuickApp:_entityMessage(externalId,topic,payload,message)
  local entity=self.registry:get(externalId); if not entity then return end
  for _,availability in ipairs(entity.availability.topics or {}) do
    if availability.topic==topic then return self:_availability(entity,availability,payload) end
  end
  if entity.jsonAttributesTopic==topic then return self:_attributes(entity,payload) end
  local child=entity.childId and self.childDevices[tonumber(entity.childId)]
  if not child then return end
  local shared=message and message.__bridgeShared or {}
  if message then message.__bridgeShared=shared end
  local ok,err=EntityMapper.handleState(entity,child,payload,self.templateEngine,shared,topic)
  if ok then self.metrics.stateUpdates=self.metrics.stateUpdates+1
  elseif err~="non_numeric_sensor_value" then self:_log("DEBUG","ENTITY",externalId..": "..tostring(err)) end
end

function QuickApp:_availability(entity,configuration,payload)
  entity.availabilityState=entity.availabilityState or {}
  local value=payload
  if configuration.template then
    value=self.templateEngine:render(configuration.template,self.templateEngine:messageContext(payload),entity.externalId)
  end
  if value==configuration.available then entity.availabilityState[configuration.topic]=true
  elseif value==configuration.unavailable then entity.availabilityState[configuration.topic]=false
  else return end
  local states,total,online=entity.availabilityState,0,0
  for _,item in ipairs(entity.availability.topics) do total=total+1; if states[item.topic] then online=online+1 end end
  local available=entity.availability.mode=="all" and online==total or entity.availability.mode=="any" and online>0 or states[configuration.topic]
  local child=entity.childId and self.childDevices[tonumber(entity.childId)]
  if child then child:updateProperty("dead",not available); child:updateProperty("deadReason",available and "" or "MQTT unavailable") end
  self.metrics.availabilityUpdates=self.metrics.availabilityUpdates+1
end

function QuickApp:_attributes(entity,payload)
  local value=payload
  if entity.jsonAttributesTemplate then value=self.templateEngine:render(entity.jsonAttributesTemplate,self.templateEngine:messageContext(payload),entity.externalId) end
  local attributes=Utils.decodeJson(value)
  if attributes then entity.attributes=attributes; self.metrics.attributeUpdates=self.metrics.attributeUpdates+1 end
end

function QuickApp:_removeEntity(externalId,discoveryTopic)
  local entity=self.registry:get(externalId)
  -- A stale retained topic must not delete an entity already reconciled by unique_id to a new topic.
  if not entity or entity.discoveryTopic~=discoveryTopic then return false end
  self.subscriptions:removeEntity(externalId)
  self.childFactory:remove(entity)
  self.registry:remove(externalId)
  return true
end

function QuickApp:handleChildAction(childId,action,value)
  local entity=self.registry:forChild(childId); if not entity then return false,"entity_not_found" end
  local command,err=EntityMapper.command(entity,action,value,self.templateEngine)
  if not command then self:_log("WARNING","ENTITY",entity.externalId..": "..tostring(err)); return false,err end
  local ok,publishError=self.mqtt:publish(command.topic,command.payload,command.retain,command.qos)
  if ok and entity.optimistic and command.optimisticValue~=nil then
    local child=self.childDevices[tonumber(childId)]
    if child then child:updateProperty("value",command.optimisticValue) end
    entity.lastValue=command.optimisticValue
  end
  return ok,publishError
end

function QuickApp:requestDiscovery()
  return self.mqtt:publish(self.config.discoveryPrefix.."/status","online",false,0)
end
function QuickApp:reconnect()
  self.config=self:_readConfig()
  if self.config.clientId==Constants.DEFAULTS.clientId then self.config.clientId=self.config.clientId.."-"..tostring(self.id) end
  self.mqtt.config=self.config; self.discovery.prefix=self.config.discoveryPrefix
  self:_applyDiscoveryMode()
  return self.mqtt:reconnect()
end
function QuickApp:reloadRegistry()
  for externalId in pairs(self.registry.entities) do self.subscriptions:removeEntity(externalId) end
  local ok,err=self.registry:load(); if not ok then return false,err end
  self.discovery.byTopic={}; self:_restoreEntities(); self:_updateUI(true); return true
end

-- Switching to automatic mode activates pending discoveries. Explicitly
-- disabled entities are a user choice and therefore remain disabled.
function QuickApp:_applyDiscoveryMode()
  if self.config.discoveryMode~="automatic" then return 0 end
  local activated=0
  for externalId,entity in pairs(self.registry.entities) do
    if entity.supported and entity.approvalState==ApprovalManager.PENDING then
      local ok=self:setEntityApproval(externalId,ApprovalManager.ACTIVE,true)
      if ok then activated=activated+1 end
    end
  end
  if activated>0 then self:_persistRegistry("automatic approval"); self:_updateUI(true) end
  return activated
end

function QuickApp:setEntityApproval(externalId,state,deferRefresh)
  local entity=self.registry:get(externalId)
  if not entity then return false,"entity_not_found" end
  if not entity.supported then return false,"unsupported_component" end
  if state==ApprovalManager.ACTIVE then
    if entity.approvalState==ApprovalManager.ACTIVE and entity.childId then return true,entity.childId end
    local child,err=self.childFactory:ensure(entity)
    if not child then return false,err end
    self.subscriptions:removeEntity(externalId)
    entity.approvalState=ApprovalManager.ACTIVE
    self.registry.dirty=true
    child:updateProperty("dead",false)
    child:updateProperty("deadReason","")
    self:_attachSubscriptions(entity)
    if not deferRefresh then self:_persistRegistry("entity activation"); self:_updateUI(true) end
    return true,child.id
  end
  if state==ApprovalManager.DISABLED then
    self.subscriptions:removeEntity(externalId)
    entity.approvalState=ApprovalManager.DISABLED
    self.registry.dirty=true
    local child=entity.childId and self.childDevices[tonumber(entity.childId)]
    if child then
      child:updateProperty("dead",true)
      child:updateProperty("deadReason","Disabled in MQTT Discovery Bridge")
    end
    if not deferRefresh then self:_persistRegistry("entity disable"); self:_updateUI(true) end
    return true,entity.childId
  end
  return false,"invalid_approval_state"
end

function QuickApp:approveDevice(deviceKey)
  local matched,created,errors=0,0,{}
  for externalId,entity in pairs(self.registry.entities) do
    if ApprovalManager.deviceKey(entity)==deviceKey and entity.supported then
      matched=matched+1
      if entity.approvalState~=ApprovalManager.ACTIVE then
        local ok,err=self:setEntityApproval(externalId,ApprovalManager.ACTIVE,true)
        if ok then created=created+1 else errors[#errors+1]=externalId..": "..tostring(err) end
      end
    end
  end
  if matched==0 then return false,"device_has_no_supported_entities" end
  self:_persistRegistry("device approval")
  if #errors>0 then return false,table.concat(errors,"; ") end
  self:_updateUI(true)
  return true,{matched=matched,activated=created}
end

-- Remove only the HC3 child. The discovery record is retained as disabled so
-- a retained MQTT config cannot immediately recreate the device.
function QuickApp:deleteEntityChild(externalId)
  local entity=self.registry:get(externalId)
  if not entity then return false,"entity_not_found" end
  self.subscriptions:removeEntity(externalId)
  local ok,err=self.childFactory:remove(entity)
  if not ok then return false,err end
  entity.approvalState=entity.supported and ApprovalManager.DISABLED or ApprovalManager.UNSUPPORTED
  self.registry.dirty=true
  self:_persistRegistry("child deletion")
  self:_updateUI(true)
  return true
end

function QuickApp:deleteOrphanedDevices() return self.childFactory:deleteOrphans() end
function QuickApp:getEntity(externalId) return Utils.copy(self.registry:get(externalId)) end
function QuickApp:getEntities() return self.registry:list() end
function QuickApp:getStatus()
  local approval=ApprovalManager.counts(self.registry.entities)
  return {version=Constants.VERSION,connected=self.mqtt.connected,broker=self.config.brokerHost,
    discoveryPrefix=self.config.discoveryPrefix,entities=self.registry:count(),
    subscriptions=self.subscriptions:count(),unsupported=self:_unsupportedCount(),
    discoveryMode=self.config.discoveryMode,active=approval.active,pending=approval.pending,
    disabled=approval.disabled}
end
function QuickApp:publish(topic,payload,retain,qos) return self.mqtt:publish(topic,payload,retain,qos) end
function QuickApp:sendCommand(externalId,action,value)
  local entity=self.registry:get(externalId); if not entity or not entity.childId then return false,"entity_not_found" end
  return self:handleChildAction(entity.childId,action,value)
end

-- HC3 UI callbacks are intentionally thin; ApprovalUI owns selection state
-- while the methods above own all persistent and device-changing behavior.
function QuickApp:approvalDeviceChanged(event) return self.approvalUI:deviceChanged(event) end
function QuickApp:approvalEntityChanged(event) return self.approvalUI:entityChanged(event) end
function QuickApp:approveSelectedEntity() return self.approvalUI:approveSelected() end
function QuickApp:approveSelectedDevice() return self.approvalUI:approveDevice() end
function QuickApp:disableSelectedEntity() return self.approvalUI:disableSelected() end
function QuickApp:deleteSelectedEntity() return self.approvalUI:deleteSelected() end
function QuickApp:selectedEntityDetails() return self.approvalUI:details() end
function QuickApp:approvalPreviousPage() return self.approvalUI:previousPage() end
function QuickApp:approvalNextPage() return self.approvalUI:nextPage() end
function QuickApp:cleanupOrphanedDevices() return self.approvalUI:cleanupOrphans() end

function QuickApp:_updateUI(force)
  local now=os.time()
  if not force and self.uiLastUpdate and now-self.uiLastUpdate<2 then
    if not self.uiUpdateTimer then
      self.uiUpdateTimer=setTimeout(function() self.uiUpdateTimer=nil; self:_updateUI(true) end,2000)
    end
    return
  end
  self.uiLastUpdate=now
  local connected=self.mqtt and self.mqtt.connected
  self:updateView("mqttStatus","text","MQTT: "..(connected and "Connected" or "Disconnected"))
  self:updateView("brokerStatus","text","Broker: "..(self.config.brokerHost~="" and self.config.brokerHost or "not configured"))
  self:updateView("discoveryStatus","text","Discovery: "..self.config.discoveryPrefix)
  self:updateView("entityStatus","text",string.format("Entities: %d · Unsupported: %d",self.registry and self.registry:count() or 0,self:_unsupportedCount()))
  self:updateView("subscriptionStatus","text","Subscriptions: "..(self.subscriptions and self.subscriptions:count() or 0))
  self:updateView("activityStatus","text","Last activity: "..(self.metrics.lastActivity and os.date("%Y-%m-%d %H:%M:%S",self.metrics.lastActivity) or "never"))
  local approval=ApprovalManager.counts(self.registry and self.registry.entities or {})
  self:updateView("approvalStatus","text",string.format("Approval: %s · Active: %d · Pending: %d · Disabled: %d",
    self.config.discoveryMode=="approval" and "Manual" or "Automatic",approval.active,approval.pending,approval.disabled))
  if self.approvalUI and force then self.approvalUI:refresh(true) end
end

function QuickApp:_unsupportedCount()
  local count=0
  if self.registry then for _,entity in pairs(self.registry.entities) do if not entity.supported then count=count+1 end end end
  return count
end

function QuickApp:_childCount()
  local count=0
  if self.registry then
    for _,entity in pairs(self.registry.entities) do if entity.childId then count=count+1 end end
  end
  return count
end

function QuickApp:debugSummary()
  local tm=self.templateEngine:getMetrics()
  local approval=ApprovalManager.counts(self.registry.entities)
  local lines={Constants.NAME.." v"..Constants.VERSION,"",
    "MQTT: "..(self.mqtt.connected and "connected" or "disconnected"),
    "Broker: "..self.config.brokerHost..":"..self.config.brokerPort,
    "Discovery prefix: "..self.config.discoveryPrefix,
    "Discovery mode: "..self.config.discoveryMode,"",
    "Entities: "..self.registry:count(),"Children: "..self:_childCount(),
    "Active: "..approval.active,"Pending: "..approval.pending,"Disabled: "..approval.disabled,
    "Unsupported: "..self:_unsupportedCount(),"Subscriptions: "..self.subscriptions:count(),"",
    "Templates compiled: "..tm.compiled,"Template cache hits: "..tm.cacheHits,
    "Template evaluations: "..tm.evaluations,"Template errors: "..tm.errors,
    "MQTT received: "..self.mqtt.metrics.received,"MQTT published: "..self.mqtt.metrics.published,
    "MQTT reconnects: "..self.mqtt.metrics.reconnects}
  self:debug(table.concat(lines,"\n"))
  return self:getStatus()
end
