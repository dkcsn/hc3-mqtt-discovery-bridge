-- Versioned persistent entity index. Runtime-only child objects and compiled
-- ASTs are deliberately stripped before JSON is stored on the parent QA.
EntityRegistry = {}
EntityRegistry.__index = EntityRegistry

function EntityRegistry.new(options)
  return setmetatable({entities={}, byChild={}, parent=options.parent, logger=options.logger,
    metrics={created=0,updated=0,removed=0}},EntityRegistry)
end

function EntityRegistry:load()
  local encoded = self.parent:getVariable(Constants.REGISTRY_VARIABLE)
  if encoded == "" then return true end
  local data, err = Utils.decodeJson(encoded)
  if not data then return false, err end
  if data.schema ~= Constants.REGISTRY_SCHEMA or type(data.entities) ~= "table" then return false,"unsupported_registry_schema" end
  self.entities = data.entities
  for externalId, entity in pairs(self.entities) do if entity.childId then self.byChild[tonumber(entity.childId)] = externalId end end
  return true
end

function EntityRegistry:persist()
  local serializable = {}
  for externalId, entity in pairs(self.entities) do
    local copy = Utils.copy(entity); copy.valueCompiled=nil; copy.commandCompiled=nil; copy.child=nil
    serializable[externalId]=copy
  end
  local encoded, err=Utils.encodeJson({schema=Constants.REGISTRY_SCHEMA,entities=serializable})
  if not encoded then return false,err end
  self.parent:setVariable(Constants.REGISTRY_VARIABLE,encoded)
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
  return previous
end

function EntityRegistry:remove(externalId)
  local entity=self.entities[externalId]; if not entity then return nil end
  self.entities[externalId]=nil
  if entity.childId then self.byChild[tonumber(entity.childId)]=nil end
  self.metrics.removed=self.metrics.removed+1
  return entity
end

function EntityRegistry:get(externalId) return self.entities[externalId] end
function EntityRegistry:forChild(childId) local id=self.byChild[tonumber(childId)]; return id and self.entities[id] end
function EntityRegistry:count() local n=0; for _ in pairs(self.entities) do n=n+1 end; return n end
function EntityRegistry:list() return Utils.copy(self.entities) end

return EntityRegistry
