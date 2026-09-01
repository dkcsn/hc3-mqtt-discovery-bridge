-- Thin lifecycle wrapper around the native HC3 mqtt.Client. It owns the sole
-- broker connection; child devices communicate only through the parent.
MQTTConnection = {}
MQTTConnection.__index = MQTTConnection

function MQTTConnection.new(options)
  return setmetatable({config=options.config, logger=options.logger,
    onConnected=options.onConnected, onDisconnected=options.onDisconnected,
    onMessage=options.onMessage, client=nil, connected=false, stopping=false,
    reconnectIndex=1, reconnectTimer=nil, generation=0,
    metrics={received=0,published=0,reconnects=0}}, MQTTConnection)
end

function MQTTConnection:_uri()
  local scheme = self.config.tls and "mqtts://" or "mqtt://"
  return scheme .. self.config.brokerHost .. ":" .. tostring(self.config.brokerPort)
end

function MQTTConnection:connect()
  if self.config.brokerHost == "" then
    self.logger("WARNING","MQTT","brokerHost is not configured")
    return false,"broker_not_configured"
  end
  self.stopping=false
  if self.reconnectTimer then clearTimeout(self.reconnectTimer); self.reconnectTimer=nil end
  self.generation=self.generation+1
  local generation=self.generation
  if self.client then pcall(function() self.client:disconnect() end); self.client=nil end
  local options={clientId=self.config.clientId,username=self.config.username,
    password=self.config.password,cleanSession=true,keepAlivePeriod=60}
  local ok, client=pcall(mqtt.Client.connect,self:_uri(),options)
  if not ok or not client then self:_failed(tostring(client)); return false,tostring(client) end
  self.client=client
  -- HC3's native MQTT client exposes `closed`; `disconnected` belongs to
  -- other socket APIs and crashes the QA on firmware that validates names.
  local function listen(name,handler)
    local function currentConnection(event)
      if generation~=self.generation or client~=self.client then return end
      return handler(event)
    end
    local registered,registrationError=pcall(client.addEventListener,client,name,currentConnection)
    if not registered then
      self.logger("ERROR","MQTT","could not register "..name.." event: "..tostring(registrationError))
      return false
    end
    return true
  end
  local listenersOk=true
  listenersOk=listen("connected",function(event) self:_connected(event) end) and listenersOk
  listenersOk=listen("message",function(event) self:_message(event) end) and listenersOk
  listenersOk=listen("error",function(event)
    self:_failed(event and (event.error or event.message or event.code) or "mqtt_error")
  end) and listenersOk
  listenersOk=listen("closed",function() self:_disconnected() end) and listenersOk
  if not listenersOk then
    pcall(function() client:disconnect() end); self.client=nil
    return false,"mqtt_event_registration_failed"
  end
  return true
end

function MQTTConnection:_connected(event)
  self.connected=true; self.reconnectIndex=1
  self.logger("INFO","MQTT","connected to "..self.config.brokerHost..":"..self.config.brokerPort)
  if self.onConnected then self.onConnected(event) end
end

function MQTTConnection:_message(event)
  self.metrics.received=self.metrics.received+1
  if self.onMessage then
    local ok,err=pcall(self.onMessage,event.topic,event.payload or "",event)
    if not ok then self.logger("ERROR","MQTT","message handler failed: "..tostring(err)) end
  end
end

function MQTTConnection:_failed(message)
  if self.stopping then return end
  self.logger("WARNING","MQTT","connection error: "..tostring(message))
  self:_scheduleReconnect()
end

function MQTTConnection:_disconnected()
  local wasConnected=self.connected; self.connected=false
  if self.onDisconnected then self.onDisconnected(wasConnected) end
  if not self.stopping then self:_scheduleReconnect() end
end

function MQTTConnection:_scheduleReconnect()
  if self.stopping or self.reconnectTimer then return end
  self.connected=false
  local delay=Constants.RECONNECT_DELAYS[self.reconnectIndex] or 60
  self.reconnectIndex=math.min(self.reconnectIndex+1,#Constants.RECONNECT_DELAYS)
  -- Jitter prevents several bridges from reconnecting to a recovered broker in lockstep.
  local milliseconds=math.floor(delay*1000*(0.85+math.random()*0.30))
  self.metrics.reconnects=self.metrics.reconnects+1
  self.logger("INFO","MQTT","reconnecting in "..string.format("%.1f",milliseconds/1000).."s")
  self.reconnectTimer=setTimeout(function() self.reconnectTimer=nil; self:connect() end,milliseconds)
end

function MQTTConnection:disconnect()
  self.stopping=true; self.connected=false
  if self.reconnectTimer then clearTimeout(self.reconnectTimer); self.reconnectTimer=nil end
  self.generation=self.generation+1
  if self.client then pcall(function() self.client:disconnect() end); self.client=nil end
end

-- Native HC3 MQTT disconnect must not run inside the QuickApp onAction stack.
-- A two-phase restart also invalidates late events from the old client before
-- the replacement connection becomes current.
function MQTTConnection:reconnect()
  self.stopping=true; self.connected=false
  if self.reconnectTimer then clearTimeout(self.reconnectTimer); self.reconnectTimer=nil end
  self.generation=self.generation+1
  local oldClient=self.client
  self.client=nil
  self.reconnectTimer=setTimeout(function()
    self.reconnectTimer=nil
    if oldClient then pcall(function() oldClient:disconnect() end) end
    self.reconnectTimer=setTimeout(function()
      self.reconnectTimer=nil
      self.stopping=false
      self:connect()
    end,250)
  end,0)
  return true
end

function MQTTConnection:subscribe(topic,qos)
  if not self.connected or not self.client then return false,"not_connected" end
  local ok,err=pcall(function() self.client:subscribe(topic,{qos=qos or 0}) end)
  return ok,ok and nil or err
end

function MQTTConnection:unsubscribe(topic)
  if not self.connected or not self.client then return false,"not_connected" end
  local ok,err=pcall(function() self.client:unsubscribe(topic) end)
  return ok,ok and nil or err
end

function MQTTConnection:publish(topic,payload,retain,qos)
  if not self.connected or not self.client then return false,"not_connected" end
  if not Utils.topicValid(topic) then return false,"invalid_topic" end
  local ok,err=pcall(function() self.client:publish(topic,tostring(payload or ""),{retain=retain==true,qos=qos or 0}) end)
  if ok then self.metrics.published=self.metrics.published+1 end
  return ok,ok and nil or err
end

return MQTTConnection
