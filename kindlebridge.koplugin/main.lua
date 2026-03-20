local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local socket = require("socket")
local json = require("rapidjson")

local KindleBridge = WidgetContainer:extend{
    name = "kindle-bridge",
}

local PORT = 8080
local server = nil
local timer_func = nil

-- ── get real Wi-Fi IP ─────────────────────────────────────────────────────────

local function get_local_ip()
    local udp = socket.udp()
    if not udp then return "unknown" end
    -- connect to any routable address (packet is never sent)
    udp:setpeername("8.8.8.8", 80)
    local ip = udp:getsockname()
    udp:close()
    return ip or "unknown"
end

-- ── JSON response helper ──────────────────────────────────────────────────────

local function send_json(client, status, tbl)
    local body = json.encode(tbl)
    client:send(table.concat({
        "HTTP/1.1 " .. status,
        "Content-Type: application/json",
        "Access-Control-Allow-Origin: *",
        "Content-Length: " .. #body,
        "Connection: close",
        "", body,
    }, "\r\n"))
    client:close()
end

-- ── parse headers ─────────────────────────────────────────────────────────────

local function parse_headers(client)
    local headers = {}
    while true do
        local line, err = client:receive("*l")
        if err or not line or line == "" then break end
        local key, val = line:match("^([^:]+):%s*(.+)$")
        if key then headers[key:lower()] = val end
    end
    return headers
end

-- ── reading progress ──────────────────────────────────────────────────────────

local function get_progress()
    local ok, ui = pcall(require, "apps/reader/readerui")
    if ok and ui and ui.instance and ui.instance.document then
        local doc   = ui.instance.document
        local view  = ui.instance.paging or ui.instance.rolling
        local page  = view and view:getCurrentPage() or 0
        local total = doc:getPageCount() or 0
        local props = doc:getProps() or {}
        return {
            title   = props.title   or "Unknown",
            authors = props.authors or "Unknown",
            file    = doc.file      or "",
            page    = page,
            total   = total,
            percent = total > 0 and math.floor((page / total) * 100) or 0,
        }
    end
    return { title = "No book open", authors = "", file = "", page = 0, total = 0, percent = 0 }
end

-- ── request router ────────────────────────────────────────────────────────────

local function handle(client)
    client:settimeout(2)
    local request, err = client:receive("*l")
    if not request then client:close() return end

    local method, path = request:match("^(%u+) (/[^ ]*) HTTP")
    if not method then client:close() return end

    parse_headers(client)
    logger.info("KindleBridge: " .. method .. " " .. path)

    if method == "GET" and path == "/ping" then
        send_json(client, "200 OK", {
            ok      = true,
            service = "kindle-bridge",
            version = "1.0.0",
            ip      = get_local_ip(),
            port    = PORT,
        })

    elseif method == "GET" and path == "/progress" then
        send_json(client, "200 OK", get_progress())

    else
        send_json(client, "404 Not Found", { error = "not found", path = path })
    end
end

-- ── server loop ───────────────────────────────────────────────────────────────

local function tick()
    if not server then return end
    local client = server:accept()
    if client then
        local ok, err = pcall(handle, client)
        if not ok then
            logger.err("KindleBridge: request error: " .. tostring(err))
            pcall(function() client:close() end)
        end
    end
    UIManager:scheduleIn(0.5, timer_func)
end

-- ── plugin lifecycle ──────────────────────────────────────────────────────────

function KindleBridge:init()
    local srv, err = socket.bind("*", PORT)
    if not srv then
        logger.err("KindleBridge: bind failed: " .. tostring(err))
        UIManager:show(InfoMessage:new{
            text = "Kindle Bridge\nERROR: " .. tostring(err),
            timeout = 6,
        })
        return
    end
    srv:settimeout(0)
    server = srv

    timer_func = function() tick() end
    UIManager:scheduleIn(0.5, timer_func)

    local ip = get_local_ip()
    UIManager:show(InfoMessage:new{
        text = string.format("Kindle Bridge started\nhttp://%s:%d", ip, PORT),
        timeout = 4,
    })
    logger.info("KindleBridge: listening on " .. ip .. ":" .. PORT)
end

function KindleBridge:onCloseWidget()
    if server then server:close() server = nil end
    if timer_func then UIManager:unschedule(timer_func) timer_func = nil end
    logger.info("KindleBridge: stopped")
end

return KindleBridge