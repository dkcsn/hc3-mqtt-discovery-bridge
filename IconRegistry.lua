-- Shared HC3 custom-icon registry. The PNG upload is intentionally separate:
-- HC3 assigns the numeric ID, and this module keeps that assignment stable when
-- the QuickApp is reinstalled or moved between source and packaged form.
IconRegistry = {DEFAULT_NAME="IconQaRegistry",SCHEMA_VERSION=1,TEMPLATE_VERSION="1.0.0"}

local RegistryClient={}
RegistryClient.__index=RegistryClient

local function registryName(options) return tostring((options or {}).registryName or IconRegistry.DEFAULT_NAME) end
local function validateOptions(options)
  assert(type(options)=="table","IconRegistry options must be a table")
  assert(type(options.uuid)=="string" and options.uuid~="","IconRegistry uuid is missing")
  assert(type(options.iconName)=="string" and options.iconName~="","IconRegistry iconName is missing")
end
local function decodeRegistry(value)
  if type(value)=="table" then return value end
  if type(value)~="string" or value=="" then return nil,"registry_not_found" end
  if not json or not json.decode then return nil,"json_api_unavailable" end
  local ok,decoded=pcall(json.decode,value)
  if not ok or type(decoded)~="table" then return nil,"invalid_registry_json" end
  return decoded
end

function IconRegistry.read(name)
  if not api or not api.get then return nil,"global_registry_api_unavailable" end
  local ok,variable=pcall(api.get,"/globalVariables/"..tostring(name or IconRegistry.DEFAULT_NAME))
  if not ok or type(variable)~="table" then return nil,"registry_not_found" end
  return decodeRegistry(variable.value)
end

function IconRegistry.getIconId(options)
  validateOptions(options)
  local registry=IconRegistry.read(registryName(options))
  local quickApps=type(registry)=="table" and registry.quickApps or nil
  local entry=type(quickApps)=="table" and quickApps[options.uuid] or nil
  local icons=type(entry)=="table" and entry.icons or nil
  return tonumber(type(icons)=="table" and icons[options.iconName] or nil)
end

function IconRegistry.new(options)
  validateOptions(options)
  return setmetatable({options={registryName=options.registryName,uuid=options.uuid,
    appName=options.appName,iconName=options.iconName}},RegistryClient)
end
function RegistryClient:getIconId() return IconRegistry.getIconId(self.options) end
function RegistryClient:setIconId(iconId) return IconRegistry.setIconId(self.options,iconId) end

function IconRegistry.setIconId(options,iconId)
  validateOptions(options)
  local id=tonumber(iconId); if not id then return false,"invalid_icon_id" end
  if not api or not api.get or not api.post or not api.put or not json or not json.encode then
    return false,"global_registry_api_unavailable"
  end
  local name=registryName(options)
  local registry=IconRegistry.read(name) or {version=IconRegistry.SCHEMA_VERSION,quickApps={}}
  registry.version=tonumber(registry.version) or IconRegistry.SCHEMA_VERSION
  registry.quickApps=type(registry.quickApps)=="table" and registry.quickApps or {}
  local entry=registry.quickApps[options.uuid]; if type(entry)~="table" then entry={} end
  entry.uuid=options.uuid; entry.name=tostring(options.appName or entry.name or options.uuid)
  entry.icons=type(entry.icons)=="table" and entry.icons or {}; entry.icons[options.iconName]=id
  entry.updated_at=os.time(); registry.quickApps[options.uuid]=entry
  local encoded=json.encode(registry)
  local getOk,existing=pcall(api.get,"/globalVariables/"..name)
  if getOk and type(existing)=="table" and existing.name==name then
    local putOk,result=pcall(api.put,"/globalVariables/"..name,{value=encoded})
    if not putOk then return false,tostring(result) end
    return true,result
  end
  local postOk,result=pcall(api.post,"/globalVariables",{name=name,value=encoded})
  if not postOk then return false,tostring(result) end
  return true,result
end

return IconRegistry
