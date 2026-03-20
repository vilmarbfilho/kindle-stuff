local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Event = require("ui/event")
local logger = require("logger")
local socket = require("socket")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")

local KindleBridge = WidgetContainer:extend{
    name = "kindle-bridge",
}

local PORT = 8080
local server      = nil
local timer_func  = nil
local sse_client  = nil   -- at most one SSE subscriber at a time
local last_page   = -1    -- tracks page changes for SSE
local last_title  = ""     -- tracks book changes for SSE
local DOCUMENTS_DIR = "/mnt/us/documents/"

-- ── get real Wi-Fi IP ─────────────────────────────────────────────────────────

local function get_local_ip()
    local udp = socket.udp()
    if not udp then return "unknown" end
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

-- ── read POST body ────────────────────────────────────────────────────────────

local function read_body(client, headers)
    local len = tonumber(headers["content-length"]) or 0
    if len == 0 then return "" end
    local body, err = client:receive(len)
    return body or ""
end

-- ── reading progress ──────────────────────────────────────────────────────────

local function get_reader()
    local ui = package.loaded["apps/reader/readerui"]
    if ui and ui.instance and ui.instance.document then
        return ui.instance
    end
    return nil
end

local function get_title(doc, file)
    -- getProps() can return nil titles on some KOReader builds —
    -- fall back to the filename without extension
    local ok, props = pcall(function() return doc:getProps() end)
    if ok and props and props.title and props.title ~= "" then
        return props.title
    end
    if file and file ~= "" then
        return file:match("([^/]+)%.[^%.]+$") or file:match("([^/]+)$") or file
    end
    return "Unknown"
end

local function get_progress()
    local ok, result = pcall(function()
        local instance = get_reader()
        if not instance then
            return { title = "No book open", authors = "", file = "", page = 0, total = 0, percent = 0 }
        end
        local doc  = instance.document
        local file = doc.file or ""

        -- page: rolling view exposes current_page as a direct field
        local page = 0
        if instance.rolling then
            page = instance.rolling.current_page or 0
        elseif instance.paging then
            local ok_cp, cp = pcall(function() return instance.paging:getCurrentPage() end)
            page = ok_cp and cp or 0
        end

        -- total pages
        local ok_tot, total = pcall(function() return doc:getPageCount() or 0 end)
        local t = ok_tot and total or 0

        -- percent: getLastPercent() returns 0.0–1.0
        local percent = 0
        if instance.rolling then
            local ok_pct, pct = pcall(function() return instance.rolling:getLastPercent() end)
            percent = ok_pct and math.floor((pct or 0) * 100) or 0
        elseif t > 0 then
            percent = math.floor((page / t) * 100)
        end

        return {
            title   = get_title(doc, file),
            authors = "",
            file    = file,
            page    = page,
            total   = t,
            percent = percent,
        }
    end)
    if ok then return result end
    logger.err("KindleBridge: get_progress error: " .. tostring(result))
    return { title = "error", error = tostring(result), page = 0, total = 0, percent = 0 }
end

-- ── GET /highlights ───────────────────────────────────────────────────────────

local function get_highlights()
    local ok, ui = pcall(require, "apps/reader/readerui")
    if not (ok and ui and ui.instance and ui.instance.document) then
        return { error = "no book open", highlights = {} }
    end
    local file = ui.instance.document.file or ""
    if file == "" then return { error = "no file path", highlights = {} } end

    local sdr_dir = file .. ".sdr"
    local exts = { "epub", "pdf", "fb2", "txt", "mobi", "azw3" }
    local meta_file
    for _, ext in ipairs(exts) do
        local p = sdr_dir .. "/metadata." .. ext .. ".lua"
        if lfs.attributes(p, "mode") == "file" then meta_file = p break end
    end
    if not meta_file then
        return { error = "no sidecar found", file = file, highlights = {} }
    end

    local chunk, lerr = loadfile(meta_file)
    if not chunk then return { error = tostring(lerr), highlights = {} } end
    local meta = chunk()
    if not meta then return { error = "sidecar returned nil", highlights = {} } end

    local results = {}
    for _, bm in ipairs(meta.bookmarks or {}) do
        if bm.highlighted then
            table.insert(results, {
                text    = bm.notes    or "",
                chapter = bm.chapter  or "",
                page    = bm.page     or 0,
                time    = bm.datetime or "",
            })
        end
    end
    local props = ui.instance.document:getProps() or {}
    return {
        title      = props.title   or "Unknown",
        authors    = props.authors or "Unknown",
        file       = file,
        total      = #results,
        highlights = results,
    }
end

-- ── POST /text ────────────────────────────────────────────────────────────────

local function handle_text(client, headers)
    local body = read_body(client, headers)
    if body == "" then
        send_json(client, "400 Bad Request", { error = "empty body" })
        return
    end
    local ok, data = pcall(json.decode, body)
    local text = (ok and data and data.text) or body
    send_json(client, "200 OK", { ok = true, received = #text })
    UIManager:scheduleIn(0.1, function()
        pcall(function()
            UIManager:show(InfoMessage:new{ text = "iPhone says:\n" .. text, timeout = 8 })
        end)
    end)
end

-- ── POST /file ────────────────────────────────────────────────────────────────

local function handle_file(client, headers)
    local filename = headers["x-filename"]
    if not filename or filename == "" then
        send_json(client, "400 Bad Request", { error = "missing X-Filename header" })
        return
    end
    filename = filename:match("([^/\\]+)$") or filename
    local len = tonumber(headers["content-length"]) or 0
    if len == 0 then
        send_json(client, "400 Bad Request", { error = "empty file" })
        return
    end
    local data, err = client:receive(len)
    if not data then
        send_json(client, "500 Internal Server Error", { error = tostring(err) })
        return
    end
    local dest = DOCUMENTS_DIR .. filename
    local f, ferr = io.open(dest, "wb")
    if not f then
        send_json(client, "500 Internal Server Error", { error = tostring(ferr) })
        return
    end
    f:write(data) f:close()
    send_json(client, "200 OK", { ok = true, filename = filename, bytes = len, path = dest })
    UIManager:scheduleIn(0.1, function()
        pcall(function()
            UIManager:show(InfoMessage:new{ text = "File received:\n" .. filename, timeout = 4 })
        end)
    end)
end

-- ── POST /cmd ─────────────────────────────────────────────────────────────────
-- Supported commands: next_page, prev_page, first_page, last_page, open_book
--
-- Body (JSON):
--   { "cmd": "next_page" }
--   { "cmd": "open_book", "file": "/mnt/us/documents/mybook.epub" }

local COMMANDS = {
    next_page  = function() UIManager:sendEvent(Event:new("GotoViewRel",  1)) end,
    prev_page  = function() UIManager:sendEvent(Event:new("GotoViewRel", -1)) end,
    first_page = function() UIManager:sendEvent(Event:new("GotoPage", 1)) end,
    last_page  = function()
        local ok, ui = pcall(require, "apps/reader/readerui")
        if ok and ui and ui.instance and ui.instance.document then
            local total = ui.instance.document:getPageCount() or 1
            UIManager:sendEvent(Event:new("GotoPage", total))
        end
    end,
    open_book = function(params)
        if not params or not params.file then return false, "missing file param" end
        local ok, ui = pcall(require, "apps/reader/readerui")
        if ok and ui and ui.instance then
            ui.instance:switchDocument(params.file)
        end
        return true
    end,
}

local function handle_cmd(client, headers)
    local body = read_body(client, headers)
    if body == "" then
        send_json(client, "400 Bad Request", { error = "empty body" })
        return
    end
    local ok, data = pcall(json.decode, body)
    if not ok or not data or not data.cmd then
        send_json(client, "400 Bad Request", { error = "invalid JSON or missing cmd" })
        return
    end

    local cmd = data.cmd
    local handler = COMMANDS[cmd]
    if not handler then
        send_json(client, "400 Bad Request", {
            error    = "unknown command: " .. tostring(cmd),
            available = { "next_page", "prev_page", "first_page", "last_page", "open_book" },
        })
        return
    end

    send_json(client, "200 OK", { ok = true, cmd = cmd })
    UIManager:scheduleIn(0.1, function()
        pcall(handler, data)
    end)
end

-- ── GET /events (SSE) ─────────────────────────────────────────────────────────
-- Keeps the connection open and pushes a progress event whenever the page
-- changes. Only one subscriber is supported at a time.

local function sse_send(client, event, data_tbl)
    local payload = "event: " .. event .. "\ndata: " .. json.encode(data_tbl) .. "\n\n"
    local ok, err = client:send(payload)
    if not ok then
        logger.info("KindleBridge: SSE client disconnected (" .. tostring(err) .. ")")
        pcall(function() client:close() end)
        sse_client = nil
    end
end

local sse_keepalive = 0  -- counter for keepalive pings

local function handle_events(client)
    -- do NOT close the client — keep it open for streaming
    client:settimeout(0)  -- non-blocking writes
    client:send(table.concat({
        "HTTP/1.1 200 OK",
        "Content-Type: text/event-stream",
        "Cache-Control: no-cache",
        "Access-Control-Allow-Origin: *",
        "Connection: keep-alive",
        "", "",   -- blank line ends headers, stream begins
    }, "\r\n"))

    -- replace any existing SSE client
    if sse_client then
        pcall(function() sse_client:close() end)
    end
    sse_client = client
    sse_keepalive = 0
    last_page  = -1
    last_title = ""

    -- send immediate first event so the client knows it is connected
    local progress = get_progress()
    last_page = progress.page
    sse_send(client, "progress", progress)

    logger.info("KindleBridge: SSE client connected")
end

-- ── SSE tick: push progress when page changes ─────────────────────────────────

local function sse_tick()
    if not sse_client then return end

    -- keepalive: send a comment line every ~10 seconds (20 ticks × 0.5s)
    sse_keepalive = sse_keepalive + 1
    if sse_keepalive >= 20 then
        sse_keepalive = 0
        local ok, err = sse_client:send(": keepalive\n\n")
        if not ok then
            logger.info("KindleBridge: SSE client gone (" .. tostring(err) .. ")")
            pcall(function() sse_client:close() end)
            sse_client = nil
            return
        end
    end

    -- push progress event when page or book changes
    local progress = get_progress()
    if progress.page ~= last_page or progress.title ~= last_title then
        last_page  = progress.page
        last_title = progress.title
        sse_send(sse_client, "progress", progress)
    end
end

-- ── request router ────────────────────────────────────────────────────────────

local function handle(client)
    client:settimeout(2)
    local request, err = client:receive("*l")
    if not request then client:close() return end

    local method, path = request:match("^(%u+) (/[^ ]*) HTTP")
    if not method then client:close() return end

    local headers = parse_headers(client)
    logger.info("KindleBridge: " .. method .. " " .. path)

    if     method == "GET"  and path == "/ping"       then
        send_json(client, "200 OK", {
            ok = true, service = "kindle-bridge", version = "3.0.0",
            ip = get_local_ip(), port = PORT,
        })
    elseif method == "GET"  and path == "/progress"   then
        send_json(client, "200 OK", get_progress())
    elseif method == "GET"  and path == "/highlights"  then
        send_json(client, "200 OK", get_highlights())
    elseif method == "GET"  and path == "/events"      then
        handle_events(client)
    elseif method == "POST" and path == "/text"        then
        handle_text(client, headers)
    elseif method == "POST" and path == "/file"        then
        handle_file(client, headers)
    elseif method == "POST" and path == "/cmd"         then
        handle_cmd(client, headers)
    elseif method == "GET" and path == "/debug" then
        local info = {}
        local ui = package.loaded["apps/reader/readerui"]
        if ui and ui.instance then
            local inst = ui.instance
            local doc  = inst.document

            -- probe props keys
            if doc then
                local ok_pr, pr = pcall(function() return doc:getProps() end)
                if ok_pr and type(pr) == "table" then
                    local keys = {}
                    for k, v in pairs(pr) do
                        keys[#keys+1] = k .. "=" .. tostring(v)
                    end
                    info.props_keys = table.concat(keys, ", ")
                end
            end

            -- probe rolling view methods and fields
            local roll = inst.rolling
            if roll then
                local methods = {}
                for k, v in pairs(roll) do
                    if type(v) == "function" then methods[#methods+1] = k end
                end
                table.sort(methods)
                info.rolling_methods = table.concat(methods, ", ")

                -- probe common page fields directly
                info.roll_current_page   = tostring(roll.current_page)
                info.roll_currentpage    = tostring(roll.currentpage)

                local ok_sp, sp = pcall(function() return roll:getLastPercent() end)
                info.getLastPercent_ok  = tostring(ok_sp)
                info.getLastPercent_val = tostring(sp)

                local ok_xp, xp = pcall(function() return inst.xpointer end)
                info.xpointer = tostring(xp)
            end
        end
        send_json(client, "200 OK", info)

    else
        send_json(client, "404 Not Found", { error = "not found", path = path })
    end
end

-- ── server loop ───────────────────────────────────────────────────────────────

local function tick()
    if not server then return end
    -- accept new HTTP connections
    local client = server:accept()
    if client then
        local ok, err = pcall(handle, client)
        if not ok then
            logger.err("KindleBridge: request error: " .. tostring(err))
            pcall(function() client:close() end)
        end
    end
    -- push SSE events on page change
    pcall(sse_tick)
    UIManager:scheduleIn(0.5, timer_func)
end

-- ── plugin lifecycle ──────────────────────────────────────────────────────────

function KindleBridge:init()
    -- KOReader calls init() on every UI transition (home <-> reader).
    -- Only bind the socket and start the timer once.
    if server then
        logger.info("KindleBridge: init() called again, server already running — skipping")
        return
    end

    local srv, err = socket.bind("*", PORT)
    if not srv then
        logger.err("KindleBridge: bind failed: " .. tostring(err))
        UIManager:show(InfoMessage:new{
            text = "Kindle Bridge\nERROR: " .. tostring(err), timeout = 6,
        })
        return
    end
    srv:settimeout(0)
    server = srv

    timer_func = function() tick() end
    UIManager:scheduleIn(0.5, timer_func)

    local ip = get_local_ip()
    UIManager:show(InfoMessage:new{
        text = string.format("Kindle Bridge v3\nhttp://%s:%d", ip, PORT),
        timeout = 4,
    })
    logger.info("KindleBridge: listening on " .. ip .. ":" .. PORT)
end

-- onCloseWidget fires on every UI transition (e.g. opening a book).
-- We must NOT stop the server here — only clean up the SSE client gently
-- so it gets a proper close event instead of a silent drop.
function KindleBridge:onCloseWidget()
    -- intentionally empty: keep server alive across UI transitions
end

-- onKOReaderClose fires only when KOReader actually exits.
function KindleBridge:onKOReaderClose()
    logger.info("KindleBridge: KOReader closing, stopping server")
    if sse_client then pcall(function() sse_client:close() end) sse_client = nil end
    if server then server:close() server = nil end
    if timer_func then UIManager:unschedule(timer_func) timer_func = nil end
end

-- onReaderReady fires when a document finishes loading.
-- Reset SSE state so the client gets an immediate push with the new book.
function KindleBridge:onReaderReady()
    last_page  = -1
    last_title = ""
    logger.info("KindleBridge: reader ready, SSE state reset")
end

return KindleBridge