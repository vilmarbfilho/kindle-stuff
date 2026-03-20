local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")

local KindleBridge = WidgetContainer:extend{
    name = "kindle-bridge",
}

local PORT = 8080
local server = nil
local timer_func = nil

local function show(msg)
    logger.info("KindleBridge: " .. tostring(msg))
    UIManager:show(InfoMessage:new{ text = "KindleBridge:\n" .. tostring(msg), timeout = 6 })
end

local function start_server()
    -- Test 1: can we load luasocket?
    local ok_sock, socket = pcall(require, "socket")
    if not ok_sock then
        show("ERROR: cannot load socket\n" .. tostring(socket))
        return
    end
    show("socket loaded OK")

    -- Test 2: can we bind?
    local srv, err = socket.bind("*", PORT)
    if not srv then
        show("ERROR: bind failed\n" .. tostring(err))
        return
    end
    srv:settimeout(0)
    server = srv
    show("Bound on port " .. PORT .. "\nTest:\ncurl http://<kindle-ip>:" .. PORT .. "/ping")

    -- Test 3: start tick loop
    timer_func = function()
        if not server then return end
        local client = server:accept()
        if client then
            client:settimeout(2)
            local req = client:receive("*l")
            repeat local l = client:receive("*l") until not l or l == ""
            local body = '{"ok":true,"port":' .. PORT .. '}'
            client:send(
                "HTTP/1.1 200 OK\r\n" ..
                "Content-Type: application/json\r\n" ..
                "Content-Length: " .. #body .. "\r\n" ..
                "Connection: close\r\n\r\n" .. body
            )
            client:close()
        end
        UIManager:scheduleIn(0.5, timer_func)
    end
    UIManager:scheduleIn(0.5, timer_func)
end

function KindleBridge:init()
    show("Plugin init called")
    start_server()
end

function KindleBridge:onCloseWidget()
    if server then server:close() server = nil end
    if timer_func then UIManager:unschedule(timer_func) timer_func = nil end
end

return KindleBridge