-- Versioned persistent entity index. Runtime-only child objects and compiled
-- ASTs are deliberately stripped before JSON is stored on the parent QA.
EntityRegistry = {}
EntityRegistry.__index = EntityRegistry

local CONFIG_KEYS = {
  device_class=true,unit_of_measurement=true,payload_on=true,payload_off=true,
  state_on=true,state_off=true,brightness_scale=true,brightness_state_topic=true,
  brightness_command_topic=true,position_topic=true,position_closed=true,
  position_open=true,state_open=true,state_opening=true,state_closed=true,
  state_closing=true,state_stopped=true,payload_open=true,payload_close=true,
  payload_stop=true,set_position_topic=true,payload_press=true,min=true,max=true,
  step=true,options=true,payload_home=true,payload_not_home=true,
  percentage_state_topic=true,percentage_command_topic=true,
}

local function compactEntity(entity)
  local copy=Utils.copy(entity)
  copy.valueCompiled=nil; copy.commandCompiled=nil; copy.child=nil
  copy.attributes=nil; copy.availabilityState=nil
  local config={}
  for key,value in pairs(copy.config or {}) do if CONFIG_KEYS[key] then config[key]=value end end
  copy.config=config
  return copy
end

local function storageValue(value)
  if type(value)=="table" and value.value~=nil then return value.value end
  return value
end

function EntityRegistry.new(options)
  return setmetatable({entities={}, byChild={}, parent=options.parent, logger=options.logger,
    dirty=false, generation=nil, metrics={created=0,updated=0,removed=0,persists=0,lastBytes=0,lastError=nil}},EntityRegistry)
end

function EntityRegistry:_internalGet(key)
  if not self.parent.internalStorageGet then return nil,"unsupported" end
  local ok,value=pcall(self.parent.internalStorageGet,self.parent,key)
  if not ok then return nil,tostring(value) end
  return storageValue(value)
end

function EntityRegistry:_internalSet(key,value)
  if not self.parent.internalStorageSet then return false,"unsupported" end
  local ok,err=pcall(self.parent.internalStorageSet,self.parent,key,value,true)
  return ok,ok and nil or tostring(err)
end

function EntityRegistry:_internalRemove(key)
  if not self.parent.internalStorageRemove then return false end
  return pcall(self.parent.internalStorageRemove,self.parent,key)
end

function EntityRegistry:_decode(encoded)
  local data,err=Utils.decodeJson(encoded)
  if not data then return nil,err end
  if data.schema~=Constants.REGISTRY_SCHEMA or type(data.entities)~="table" then
    return nil,"unsupported_registry_schema"
  end
  return data
end

function EntityRegistry:load()
  self.entities={}; self.byChild={}
  local encoded,manifest
  local manifestRaw=self:_internalGet(Constants.REGISTRY_MANIFEST)
  if type(manifestRaw)=="string" and manifestRaw~="" then
    manifest=Utils.decodeJson(manifestRaw)
    if not manifest or manifest.schema~=Constants.REGISTRY_SCHEMA or type(manifest.chunks)~="number" then
      return false,"invalid_registry_manifest"
    end
    local parts={}
    for index=1,manifest.chunks do
      local part=self:_internalGet(Constants.REGISTRY_CHUNK_PREFIX..manifest.generation.."_"..index)
      if type(part)~="string" then return false,"missing_registry_chunk_"..index end
      parts[#parts+1]=part
    end
    encoded=table.concat(parts)
    if #encoded~=manifest.bytes or Utils.hash(encoded)~=manifest.hash then return false,"registry_integrity_error" end
    self.generation=manifest.generation
  else
    local ok,value=pcall(self.parent.getVariable,self.parent,Constants.REGISTRY_VARIABLE)
    encoded=ok and value or ""
  end
  if encoded==nil or encoded=="" then return true end
  local data,err=self:_decode(encoded); if not data then return false,err end
  self.entities = data.entities
  for externalId,entity in pairs(self.entities) do
    if entity.childId then self.byChild[tonumber(entity.childId)]=externalId end
  end
  self.dirty=manifest==nil
  return true
end

function EntityRegistry:persist()
  local serializable = {}
  for externalId,entity in pairs(self.entities) do serializable[externalId]=compactEntity(entity) end
  local encoded, err=Utils.encodeJson({schema=Constants.REGISTRY_SCHEMA,entities=serializable})
  if not encoded then return false,err end
  if #encoded>Constants.MAX_REGISTRY_BYTES then
    self.metrics.lastError="registry_size_limit"; return false,self.metrics.lastError
  end
  self.metrics.lastBytes=#encoded
  if not self.parent.internalStorageSet or not self.parent.internalStorageGet then
    local ok,setError=pcall(self.parent.setVariable,self.parent,Constants.REGISTRY_VARIABLE,encoded)
    if not ok then self.metrics.lastError=tostring(setError); return false,self.metrics.lastError end
    self.metrics.persists=self.metrics.persists+1; self.metrics.lastError=nil; self.dirty=false
    return true
  end
  local generation=self.generation=="a" and "b" or "a"
  local chunks=math.max(1,math.ceil(#encoded/Constants.REGISTRY_CHUNK_SIZE))
  for index=1,chunks do
    local value=encoded:sub((index-1)*Constants.REGISTRY_CHUNK_SIZE+1,index*Constants.REGISTRY_CHUNK_SIZE)
    local key=Constants.REGISTRY_CHUNK_PREFIX..generation.."_"..index
    local ok,writeError=self:_internalSet(key,value)
    if not ok then self.metrics.lastError="chunk_write_failed: "..tostring(writeError); return false,self.metrics.lastError end
    local verify=self:_internalGet(key)
    if verify~=value then self.metrics.lastError="chunk_verify_failed_"..index; return false,self.metrics.lastError end
  end
  local manifest={schema=Constants.REGISTRY_SCHEMA,generation=generation,chunks=chunks,bytes=#encoded,hash=Utils.hash(encoded)}
  local manifestEncoded=assert(Utils.encodeJson(manifest))
  local ok,writeError=self:_internalSet(Constants.REGISTRY_MANIFEST,manifestEncoded)
  if not ok then self.metrics.lastError="manifest_write_failed: "..tostring(writeError); return false,self.metrics.lastError end
  local oldGeneration=self.generation
  if oldGeneration then
    local oldIndex=1
    while self:_internalGet(Constants.REGISTRY_CHUNK_PREFIX..oldGeneration.."_"..oldIndex)~=nil do
      self:_internalRemove(Constants.REGISTRY_CHUNK_PREFIX..oldGeneration.."_"..oldIndex); oldIndex=oldIndex+1
    end
  end
  self.generation=generation
  pcall(self.parent.setVariable,self.parent,Constants.REGISTRY_VARIABLE,"")
  self.metrics.persists=self.metrics.persists+1; self.metrics.lastError=nil; self.dirty=false
  return true
end

function EntityRegistry:put(entity)
  local previous=self.entities[entity.externalId]
  if previous then
    entity.childId=entity.childId or previous.childId
    entity.lastValue=entity.lastValue~=nil and entity.lastValue or previous.lastValue
    self.metrics.updated=self.metrics.updated+1
  else self.metrics.created=self.metrics.created+1 end
  self.entities[entity.externalId]=entity
  if entity.childId then self.byChild[tonumber(entity.childId)]=entity.externalId end
  self.dirty=true
  return previous
end

function EntityRegistry:remove(externalId)
  local entity=self.entities[externalId]; if not entity then return nil end
  self.entities[externalId]=nil
  if entity.childId then self.byChild[tonumber(entity.childId)]=nil end
  self.metrics.removed=self.metrics.removed+1
  self.dirty=true
  return entity
end

function EntityRegistry:get(externalId) return self.entities[externalId] end
function EntityRegistry:forChild(childId) local id=self.byChild[tonumber(childId)]; return id and self.entities[id] end
function EntityRegistry:count() local n=0; for _ in pairs(self.entities) do n=n+1 end; return n end
function EntityRegistry:list() return Utils.copy(self.entities) end

return EntityRegistry
