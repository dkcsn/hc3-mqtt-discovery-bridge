-- A single child class is deliberate: after restart HC3 selects constructors by
-- device type, while several MQTT components can share one HC3 type. The persisted
-- external identity lets the parent choose the correct adapter at action time.
class 'BridgeChild'(QuickAppChild)

function BridgeChild:__init(device)
  QuickAppChild.__init(self,device)
end

function BridgeChild:onInit() end

local function dispatch(self, action, value)
  if not self.parent or not self.parent.handleChildAction then return end
  return self.parent:handleChildAction(self.id,action,value)
end

function BridgeChild:turnOn() return dispatch(self,"turnOn") end
function BridgeChild:turnOff() return dispatch(self,"turnOff") end
function BridgeChild:toggle() return dispatch(self,"toggle") end
function BridgeChild:setValue(value) return dispatch(self,"setValue",value) end
function BridgeChild:open() return dispatch(self,"open") end
function BridgeChild:close() return dispatch(self,"close") end
function BridgeChild:stop() return dispatch(self,"stop") end
function BridgeChild:press() return dispatch(self,"press") end
function BridgeChild:select(value) return dispatch(self,"select",value) end

return BridgeChild
