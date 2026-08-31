-- Uploads the embedded 128x128 PNG once, selects it on the parent and stores
-- HC3's assigned numeric ID in IconQaRegistry for future updates/reinstalls.
-- IconRegistry owns persistence; this module owns only HC3 runtime mechanics.
IconInstaller = {}
IconInstaller.__index = IconInstaller

local CUSTOM_ICON_MIN=1000

function IconInstaller.new(options)
  assert(type(options)=="table" and options.parent,"IconInstaller parent is required")
  return setmetatable({parent=options.parent,registry=options.registry,pngHex=options.pngHex,
    deviceType=options.deviceType,logger=options.logger,running=false},IconInstaller)
end

function IconInstaller:_log(level,message)
  if self.logger then self.logger(level,"ICON",message) end
end

function IconInstaller:_bytes()
  local hex=tostring(self.pngHex or ""):gsub("%s+","")
  if hex=="" or #hex%2~=0 or not hex:match("^%x+$") then return nil,"invalid_embedded_png" end
  local bytes={}
  hex:gsub("(..)",function(pair) bytes[#bytes+1]=string.char(tonumber(pair,16)) end)
  return table.concat(bytes)
end

function IconInstaller:_select(iconId)
  local id=tonumber(iconId)
  if not id or id<CUSTOM_ICON_MIN then return false,"invalid_custom_icon_id" end
  local ok,result=pcall(api.put,"/devices/"..tostring(self.parent.id),{properties={deviceIcon=id}})
  if not ok then return false,tostring(result) end
  local selected=type(result)=="table" and type(result.properties)=="table" and
    tonumber(result.properties.deviceIcon) or nil
  if selected~=id then
    local readOk,device=pcall(api.get,"/devices/"..tostring(self.parent.id))
    selected=readOk and type(device)=="table" and type(device.properties)=="table" and
      tonumber(device.properties.deviceIcon) or selected
  end
  if selected~=id then return false,"HC3 rejected icon id "..tostring(id) end
  self.parent.properties=self.parent.properties or {}
  self.parent.properties.deviceIcon=id
  pcall(self.parent.updateProperty,self.parent,"deviceIcon",id)
  return true,id
end

function IconInstaller:_remember(iconId)
  local ok,err=self.registry:setIconId(iconId)
  if not ok then self:_log("WARNING","registry update failed: "..tostring(err)) end
end

function IconInstaller:_upload()
  if self.running then return false,"upload_in_progress" end
  if not self.parent.deviceIconTypeMapping or not self.parent.uploadIconFiles then
    self:_log("DEBUG","upload API unavailable in this runtime")
    return false,"icon_upload_unavailable"
  end
  local deviceType=tostring(self.parent.type or self.deviceType)
  local mapping=self.parent.deviceIconTypeMapping[deviceType]
  if not mapping or type(mapping.fileNames)~="table" or #mapping.fileNames~=1 then
    return false,"unsupported_icon_device_type: "..deviceType
  end
  local bytes,byteError=self:_bytes(); if not bytes then return false,byteError end
  self.running=true
  local originalHttpClient=net.HTTPClient
  local ok,err=pcall(function()
    function net.HTTPClient() return originalHttpClient({timeout=60000}) end
    self.parent:uploadIconFiles({files={bytes},fileNames=mapping.fileNames,deviceType=deviceType},{},
      function(iconId)
        self.running=false
        local selected,selectError=self:_select(iconId)
        if not selected then self:_log("ERROR","uploaded icon selection failed: "..tostring(selectError)); return end
        self:_remember(iconId)
        self:_log("INFO","custom icon uploaded and selected: "..tostring(iconId))
      end,
      function(uploadError)
        self.running=false
        self:_log("ERROR","upload failed: "..tostring(uploadError))
      end)
  end)
  net.HTTPClient=originalHttpClient
  if not ok then self.running=false; self:_log("ERROR","upload failed: "..tostring(err)); return false,err end
  return true
end

function IconInstaller:ensure()
  local current=tonumber((self.parent.properties or {}).deviceIcon or 0) or 0
  if current>=CUSTOM_ICON_MIN then
    self:_remember(current)
    self:_log("DEBUG","custom icon already selected: "..tostring(current))
    return true,current
  end
  local registered=self.registry:getIconId()
  if registered then
    local selected,err=self:_select(registered)
    if selected then self:_log("INFO","custom icon restored: "..tostring(registered)); return true,registered end
    self:_log("WARNING","registered icon is stale: "..tostring(err))
  end
  return self:_upload()
end

return IconInstaller
