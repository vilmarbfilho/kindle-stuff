local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local socket = require("socket")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")

local KindleBridge = WidgetContainer:extend{
    name = "kindle-bridge",
}

local PORT = 8080
local server = nil
local timer_func = nil
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

-- ── POST /text ────────────────────────────────────────────────────────────────
-- Displays a text message as an overlay on the Kindle screen.

local function handle_text(client, headers)
    local body = read_body(client, headers)
    if body == "" then
        send_json(client, "400 Bad Request", { error = "empty body" })
        return
    end

    local ok, data = pcall(json.decode, body)
    local text = (ok and data and data.text) or body

    send_json(client, "200 OK", { ok = true, received = #text })

    -- show after response so the HTTP round-trip completes first
    UIManager:scheduleIn(0.1, function()
        local ok_ui, ui_err = pcall(function()
            UIManager:show(InfoMessage:new{
                text    = "iPhone says:\n" .. text,
                timeout = 8,
            })
        end)
        if not ok_ui then
            logger.err("KindleBridge: UI error: " .. tostring(ui_err))
        end
    end)
end

-- ── POST /file ────────────────────────────────────────────────────────────────
-- Saves a binary file into the Kindle documents folder.
-- Expected headers: X-Filename (e.g. "mybook.epub")
-- Body: raw file bytes

local function handle_file(client, headers)
    local filename = headers["x-filename"]
    if not filename or filename == "" then
        send_json(client, "400 Bad Request", { error = "missing X-Filename header" })
        return
    end

    -- sanitise: strip any path components
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
    f:write(data)
    f:close()

    logger.info("KindleBridge: saved file -> " .. dest)
    send_json(client, "200 OK", { ok = true, filename = filename, bytes = len, path = dest })

    UIManager:scheduleIn(0.1, function()
        UIManager:show(InfoMessage:new{
            text    = "File received:\n" .. filename,
            timeout = 4,
        })
    end)
end

-- ── GET /highlights ───────────────────────────────────────────────────────────
-- Reads highlights for the currently open book from KOReader's sidecar file.

local function get_highlights()
    local ok, ui = pcall(require, "apps/reader/readerui")
    if not (ok and ui and ui.instance and ui.instance.document) then
        return { error = "no book open", highlights = {} }
    end

    local file = ui.instance.document.file or ""
    if file == "" then
        return { error = "no file path", highlights = {} }
    end

    -- KOReader stores highlights in a .sdr sidecar directory next to the book
    local sdr_dir  = file .. ".sdr"
    local meta_path = sdr_dir .. "/metadata.epub.lua"  -- adjust ext if needed

    -- try common metadata filenames
    local candidates = {
        sdr_dir .. "/metadata.epub.lua",
        sdr_dir .. "/metadata.pdf.lua",
        sdr_dir .. "/metadata.fb2.lua",
        sdr_dir .. "/metadata.txt.lua",
        sdr_dir .. "/metadata.mobi.lua",
        sdr_dir .. "/metadata.azw3.lua",
    }

    local meta_file
    for _, path in ipairs(candidates) do
        if lfs.attributes(path, "mode") == "file" then
            meta_file = path
            break
        end
    end

    if not meta_file then
        return { error = "no sidecar found", file = file, highlights = {} }
    end

    -- sidecar is a Lua file that returns a table — load it safely
    local chunk, lerr = loadfile(meta_file)
    if not chunk then
        return { error = "sidecar parse error: " .. tostring(lerr), highlights = {} }
    end
    local meta = chunk()
    if not meta then
        return { error = "sidecar returned nil", highlights = {} }
    end

    local results = {}
    local bookmarks = meta.bookmarks or {}
    for _, bm in ipairs(bookmarks) do
        if bm.highlighted then
            table.insert(results, {
                text    = bm.notes or "",
                chapter = bm.chapter or "",
                page    = bm.page or 0,
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

-- ── request router ────────────────────────────────────────────────────────────

local function handle(client)
    client:settimeout(2)
    local request, err = client:receive("*l")
    if not request then client:close() return end

    local method, path = request:match("^(%u+) (/[^ ]*) HTTP")
    if not method then client:close() return end

    local headers = parse_headers(client)
    logger.info("KindleBridge: " .. method .. " " .. path)

    if method == "GET" and path == "/ping" then
        send_json(client, "200 OK", {
            ok      = true,
            service = "kindle-bridge",
            version = "2.0.0",
            ip      = get_local_ip(),
            port    = PORT,
        })

    elseif method == "GET" and path == "/progress" then
        send_json(client, "200 OK", get_progress())

    elseif method == "GET" and path == "/highlights" then
        send_json(client, "200 OK", get_highlights())

    elseif method == "POST" and path == "/text" then
        handle_text(client, headers)

    elseif method == "POST" and path == "/file" then
        handle_file(client, headers)

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
            text    = "Kindle Bridge\nERROR: " .. tostring(err),
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
        text    = string.format("Kindle Bridge v2\nhttp://%s:%d", ip, PORT),
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