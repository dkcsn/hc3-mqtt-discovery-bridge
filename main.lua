--%%name:HC3 MQTT Discovery Bridge
--%%type:com.fibaro.device
--%%description:HC3 MQTT Discovery Bridge v0.1.0 — native Home Assistant MQTT Discovery consumer
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
--%%file:./MQTTClient.lua,MQTTClient
--%%file:./ChildClasses.lua,ChildClasses
--%%file:./ChildFactory.lua,ChildFactory
--%%file:./IconRegistry.lua,IconRegistry
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
--%%var:mqttEntityRegistry=""
--%%u:{label="mqttStatus",text="MQTT: Starting"}
--%%u:{label="brokerStatus",text="Broker: not configured"}
--%%u:{label="discoveryStatus",text="Discovery: homeassistant"}
--%%u:{label="entityStatus",text="Entities: 0"}
--%%u:{label="subscriptionStatus",text="Subscriptions: 0"}
--%%u:{label="activityStatus",text="Last activity: never"}
--%%u:{{button="btnReconnect",text="Reconnect",onReleased="reconnect"},{button="btnDiscover",text="Request Discovery",onReleased="requestDiscovery"}}
--%%u:{{button="btnReload",text="Reload Registry",onReleased="reloadRegistry"},{button="btnSummary",text="Debug Summary",onReleased="debugSummary"}}

-- main.lua is intentionally composition-only. Protocol parsing, transport,
-- persistence, templates and HC3 mappings remain independently testable files.
local function variable(self,name,default)
  local value=self:getVariable(name)
  return (value==nil or value=="") and default or value
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

  self.mqtt=MQTTConnection.new({config=self.config,logger=logger,
    onConnected=function(event) self:_mqttConnected(event) end,
    onDisconnected=function() self:_mqttDisconnected() end,
    onMessage=function(topic,payload,event) self:_mqttMessage(topic,payload,event) end})
  self.subscriptions=SubscriptionRegistry.new({logger=logger,
    subscribe=function(topic,qos) return self.mqtt:subscribe(topic,qos) end,
    unsubscribe=function(topic) return self.mqtt:unsubscribe(topic) end})
  self.discovery=Discovery.new({prefix=self.config.discoveryPrefix,logger=logger,
    onUpsert=function(entity,prepareOnly) return self:_upsertEntity(entity,prepareOnly) end,
    onRemove=function(externalId,topic) return self:_removeEntity(externalId,topic) end})

  self:_restoreEntities()
  self:_applyRegisteredIcon()
  self:_updateUI(true)
  self.mqtt:connect()
end

function QuickApp:_restoreEntities()
  local restored={}
  for externalId,entity in pairs(self.registry.entities) do
    local prepared,err=EntityMapper.prepare(entity,self.templateEngine)
    if prepared then
      restored[externalId]=prepared
      if prepared.supported then
        self.childFactory:ensure(prepared)
        self:_attachSubscriptions(prepared)
      end
    else self:_log("WARNING","ENTITY",externalId.." restore failed: "..tostring(err)) end
  end
  self.registry.entities=restored
  self.discovery:restore(restored)
end

function QuickApp:_applyRegisteredIcon()
  self.iconRegistry=IconRegistry.new({uuid=Constants.UUID,appName=Constants.NAME,iconName="main"})
  local iconId=self.iconRegistry:getIconId()
  if iconId then self:updateProperty("deviceIcon",iconId) end
end

function QuickApp:_mqttConnected()
  local prefix,qos=self.config.discoveryPrefix,self.config.discoveryQoS
  self.mqtt:subscribe(prefix.."/+/+/config",qos)
  self.mqtt:subscribe(prefix.."/+/+/+/config",qos)
  self.subscriptions:restoreSubscriptions()
  if self.config.publishHABirth then self:requestDiscovery() end
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
  if prepared.supported then
    local child,childError=self.childFactory:ensure(prepared)
    if not child then return false,childError end
  else
    if old and old.childId then self.childFactory:remove(old) end
    if not self.unsupportedLogged[prepared.component] then
      self.unsupportedLogged[prepared.component]=true
      self:_log("WARNING","ENTITY","parse-only component: "..tostring(prepared.component))
    end
  end
  if old then self.subscriptions:removeEntity(old.externalId) end
  self.registry:put(prepared)
  if prepared.supported then self:_attachSubscriptions(prepared) end
  self.registry:persist()
  return true,prepared
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
  local ok,err=EntityMapper.handleState(entity,child,payload,self.templateEngine,shared)
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
  self.registry:persist()
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
  self.config=self:_readConfig(); self.mqtt.config=self.config; self.discovery.prefix=self.config.discoveryPrefix
  return self.mqtt:reconnect()
end
function QuickApp:reloadRegistry()
  for externalId in pairs(self.registry.entities) do self.subscriptions:removeEntity(externalId) end
  local ok,err=self.registry:load(); if not ok then return false,err end
  self.discovery.byTopic={}; self:_restoreEntities(); self:_updateUI(true); return true
end
function QuickApp:deleteOrphanedDevices() return self.childFactory:deleteOrphans() end
function QuickApp:getEntity(externalId) return Utils.copy(self.registry:get(externalId)) end
function QuickApp:getEntities() return self.registry:list() end
function QuickApp:getStatus()
  return {version=Constants.VERSION,connected=self.mqtt.connected,broker=self.config.brokerHost,
    discoveryPrefix=self.config.discoveryPrefix,entities=self.registry:count(),
    subscriptions=self.subscriptions:count(),unsupported=self:_unsupportedCount()}
end
function QuickApp:publish(topic,payload,retain,qos) return self.mqtt:publish(topic,payload,retain,qos) end
function QuickApp:sendCommand(externalId,action,value)
  local entity=self.registry:get(externalId); if not entity or not entity.childId then return false,"entity_not_found" end
  return self:handleChildAction(entity.childId,action,value)
end

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
end

function QuickApp:_unsupportedCount()
  local count=0
  if self.registry then for _,entity in pairs(self.registry.entities) do if not entity.supported then count=count+1 end end end
  return count
end

function QuickApp:debugSummary()
  local tm=self.templateEngine:getMetrics()
  local lines={Constants.NAME.." v"..Constants.VERSION,"",
    "MQTT: "..(self.mqtt.connected and "connected" or "disconnected"),
    "Broker: "..self.config.brokerHost..":"..self.config.brokerPort,
    "Discovery prefix: "..self.config.discoveryPrefix,"",
    "Entities: "..self.registry:count(),"Children: "..tostring(self.registry:count()-self:_unsupportedCount()),
    "Unsupported: "..self:_unsupportedCount(),"Subscriptions: "..self.subscriptions:count(),"",
    "Templates compiled: "..tm.compiled,"Template cache hits: "..tm.cacheHits,
    "Template evaluations: "..tm.evaluations,"Template errors: "..tm.errors,
    "MQTT received: "..self.mqtt.metrics.received,"MQTT published: "..self.mqtt.metrics.published,
    "MQTT reconnects: "..self.mqtt.metrics.reconnects}
  self:debug(table.concat(lines,"\n"))
  return self:getStatus()
end
