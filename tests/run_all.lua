dofile("Constants.lua")
dofile("Utils.lua")
dofile("TemplateParser.lua")
dofile("TemplateEvaluator.lua")
dofile("TemplateEngine.lua")
dofile("DiscoveryNormalize.lua")
dofile("Discovery.lua")
dofile("SubscriptionRegistry.lua")
dofile("EntityMapper.lua")
dofile("EntityRegistry.lua")

local passed,failed=0,0
local function test(name,fn)
  local ok,err=pcall(fn)
  if ok then passed=passed+1; print("PASS",name)
  else failed=failed+1; print("FAIL",name,err) end
end
local function equal(actual,expected,message)
  if actual~=expected then error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual),2) end
end
local function truthy(value,message) if not value then error(message or "expected truthy value",2) end end

test("release version is synchronized",function()
  local handle=assert(io.open("VERSION","r")); local release=Utils.trim(handle:read("*a")); handle:close()
  equal(Constants.VERSION,release)
  local changelog=assert(io.open("CHANGELOG.md","r")); local text=changelog:read("*a"); changelog:close()
  truthy(text:find("## "..release,1,true),"CHANGELOG is missing release "..release)
end)

local engine=TemplateEngine.new({})
local function render(template,payload,extra,shared)
  local compiled,err=engine:compile(template); truthy(compiled,err and err.message)
  local value,evaluationError=engine:evaluate(compiled,engine:messageContext(payload,extra,shared))
  truthy(not evaluationError,evaluationError and evaluationError.message)
  return value
end

test("template raw value",function() equal(render("{{ value }}","ON"),"ON") end)
test("template nested JSON",function() equal(render("{{ value_json.environment.temperature }}",'{"environment":{"temperature":21.6}}'),"21.6") end)
test("template indexed JSON",function() equal(render('{{ value_json["temperature"] }}','{"temperature":18}'),"18") end)
test("template filter chain",function() equal(render("{{ value_json.temperature | float | round(1) }}",'{"temperature":21.64}'),"21.6") end)
test("template arithmetic",function() equal(render("{{ (value | float) * 1.8 + 32 }}","10"),"50.0") end)
test("template boolean comparison",function() equal(render('{{ "ON" if value | upper == "ON" else "OFF" }}',"on"),"ON") end)
test("template tests",function()
  equal(render('{{ value_json.missing is not defined }}','{}'),"True")
  equal(render('{{ value_json.present is defined }}','{"present":1}'),"True")
end)
test("template if block",function()
  local template="{% if value_json.online %}{{ value_json.temperature }}{% elif value_json.cached %}cached{% else %}unavailable{% endif %}"
  equal(render(template,'{"online":true,"temperature":22}'),"22")
  equal(render(template,'{"online":false}'),"unavailable")
end)
test("template comments",function() equal(render("a{# ignored #}b",""),"ab") end)
test("template malformed",function() local compiled=engine:compile("{{ value | }}"); equal(compiled,nil) end)
test("template unknown filter is controlled",function()
  local compiled=engine:compile("{{ value | shell }}"); truthy(compiled)
  local value,err=engine:evaluate(compiled,{value="x"}); equal(value,nil); equal(err.type,"evaluation_error")
end)
test("template JSON decoded once",function()
  local shared={}; render("{{ value_json.a }}",'{"a":1}',nil,shared); render("{{ value_json.a }}",'{"a":1}',nil,shared)
  truthy(shared.jsonAttempted)
end)

test("normal component discovery",function()
  local entities,err=DiscoveryNormalize.payload("homeassistant/sensor/kitchen/config",'{"name":"Temperature","unique_id":"temp_1","state_topic":"kitchen/state"}',"homeassistant")
  truthy(entities,err); equal(#entities,1); equal(entities[1].externalId,"uid:temp_1"); equal(entities[1].component,"sensor")
end)
test("node id discovery",function()
  local entities=assert(DiscoveryNormalize.payload("homeassistant/switch/node1/relay/config",'{"state_topic":"relay/state","command_topic":"relay/set"}',"homeassistant"))
  equal(entities[1].nodeId,"node1"); equal(entities[1].objectId,"relay")
end)
test("abbreviations and base topic",function()
  local entities=assert(DiscoveryNormalize.payload("homeassistant/switch/test/config",'{"~":"room/relay","uniq_id":"relay_1","stat_t":"~/state","cmd_t":"~/set","pl_on":"YES"}',"homeassistant"))
  equal(entities[1].stateTopic,"room/relay/state"); equal(entities[1].commandTopic,"room/relay/set"); equal(entities[1].config.payload_on,"YES")
end)
test("device discovery creates components",function()
  local payload='{"dev":{"ids":"multi1","name":"Kitchen"},"o":{"name":"fixture"},"state_topic":"multi/state","cmps":{"temperature":{"p":"sensor","uniq_id":"multi_temp","val_tpl":"{{ value_json.temperature }}"},"humidity":{"p":"sensor","uniq_id":"multi_hum","val_tpl":"{{ value_json.humidity }}"},"battery":{"p":"sensor","uniq_id":"multi_bat","val_tpl":"{{ value_json.battery }}"}}}'
  local entities,err=DiscoveryNormalize.payload("homeassistant/device/kitchen/config",payload,"homeassistant")
  truthy(entities,err); equal(#entities,3); equal(entities[1].stateTopic,"multi/state")
end)
test("device discovery base topic inheritance",function()
  local payload='{"~":"dev1","dev":{"ids":"dev1"},"cmps":{"relay":{"p":"switch","stat_t":"~/state","cmd_t":"~/set"}}}'
  local entities=assert(DiscoveryNormalize.payload("homeassistant/device/dev1/config",payload,"homeassistant"))
  equal(entities[1].stateTopic,"dev1/state"); equal(entities[1].commandTopic,"dev1/set")
end)
test("empty config removes",function()
  local entities,err,meta=DiscoveryNormalize.payload("homeassistant/sensor/test/config","","homeassistant")
  truthy(entities,err); equal(#entities,0); truthy(meta.remove)
end)
test("invalid discovery JSON",function()
  local entities,err=DiscoveryNormalize.payload("homeassistant/sensor/test/config","{", "homeassistant")
  equal(entities,nil); truthy(err:find("invalid_json",1,true))
end)
test("oversized discovery rejected",function()
  local entities,err=DiscoveryNormalize.payload("homeassistant/sensor/test/config",string.rep("x",Constants.MAX_DISCOVERY_PAYLOAD+1),"homeassistant")
  equal(entities,nil); equal(err,"payload_too_large")
end)
test("deep JSON rejected",function()
  local text=string.rep('{"x":',33).."1"..string.rep("}",33)
  local value,err=Utils.decodeJson(text); equal(value,nil); equal(err,"json_depth_limit")
end)

test("shared subscription lifecycle",function()
  local subscribed,unsubscribed,received=0,0,0
  local registry=SubscriptionRegistry.new({subscribe=function() subscribed=subscribed+1 end,unsubscribe=function() unsubscribed=unsubscribed+1 end})
  registry:addConsumer("device/state","a",function() received=received+1 end,0)
  registry:addConsumer("device/state","b",function() received=received+1 end,0)
  equal(subscribed,1); equal(registry:dispatch("device/state","{}",{}),2); equal(received,2)
  registry:removeConsumer("device/state","a"); equal(unsubscribed,0)
  registry:removeConsumer("device/state","b"); equal(unsubscribed,1)
end)

test("switch mapping command",function()
  local entity={externalId="uid:s",component="switch",stateTopic="s/state",commandTopic="s/set",config={payload_on="YES",payload_off="NO"},qos=0,retain=false}
  assert(EntityMapper.prepare(entity,engine))
  local command=assert(EntityMapper.command(entity,"turnOn",nil,engine)); equal(command.payload,"YES"); equal(command.topic,"s/set")
end)
test("number range validation",function()
  local entity={externalId="uid:n",component="number",commandTopic="n/set",config={min=1,max=10,step=0.5},qos=0,retain=false}
  assert(EntityMapper.prepare(entity,engine))
  local command,err=EntityMapper.command(entity,"setValue",11,engine); equal(command,nil); equal(err,"number_out_of_range")
end)
test("cover reversed position",function()
  local entity={component="cover",config={position_closed=100,position_open=0}}
  local state=EntityMapper.adapters.cover.state(entity,"25"); equal(state.value,75)
end)

test("discovery update and removal",function()
  local active,removed={},{0}
  local discovery=Discovery.new({prefix="homeassistant",onUpsert=function(entity) active[entity.externalId]=entity; return true,entity end,
    onRemove=function(id) active[id]=nil; removed[1]=removed[1]+1 end})
  truthy(discovery:process("homeassistant/sensor/test/config",'{"unique_id":"u1","state_topic":"a"}'))
  truthy(discovery:process("homeassistant/sensor/test/config",'{"unique_id":"u1","state_topic":"b"}'))
  equal(active["uid:u1"].stateTopic,"b")
  truthy(discovery:process("homeassistant/sensor/test/config","")); equal(active["uid:u1"],nil); equal(removed[1],1)
end)

test("registry restart restore",function()
  local stored=""
  local parent={getVariable=function() return stored end,setVariable=function(_,_,value) stored=value end}
  local first=EntityRegistry.new({parent=parent})
  first:put({externalId="uid:restart",component="sensor",childId=42,discoveryTopic="homeassistant/sensor/restart/config"})
  truthy(first:persist())
  local second=EntityRegistry.new({parent=parent}); truthy(second:load())
  equal(second:get("uid:restart").childId,42); equal(second:forChild(42).externalId,"uid:restart")
end)

test("realistic fixtures normalize",function()
  local names={"zigbee2mqtt-device","tasmota-switch","wled-light","openmqttgateway-sensor","diy-sensor","generic-switch"}
  for _,name in ipairs(names) do
    local handle=assert(io.open("tests/fixtures/"..name..".json","r")); local fixture=assert(Utils.decodeJson(handle:read("*a"))); handle:close()
    local payload=assert(Utils.encodeJson(fixture.payload))
    local entities,err=DiscoveryNormalize.payload(fixture.topic,payload,"homeassistant")
    truthy(entities,name..": "..tostring(err))
  end
end)

print(string.format("RESULT %d passed, %d failed",passed,failed))
if failed>0 then error(string.format("%d tests failed",failed)) end
