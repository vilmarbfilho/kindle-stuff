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

local PORT       = 8080
local TOKEN_FILE = "kindle-bridge-token.txt"
local TOKEN_PATH = "/mnt/us/koreader/" .. TOKEN_FILE

local server     = nil
local timer_func = nil
local sse_client = nil
local last_page  = -1
local last_title = ""
local auth_token = nil
local DOCUMENTS_DIR = "/mnt/us/documents/"

-- ── Wi-Fi IP ──────────────────────────────────────────────────────────────────

local function get_local_ip()
    local udp = socket.udp()
    if not udp then return "unknown" end
    udp:setpeername("8.8.8.8", 80)
    local ip = udp:getsockname()
    udp:close()
    return ip or "unknown"
end

-- ── auth token ────────────────────────────────────────────────────────────────

local function generate_token()
    math.randomseed(os.time())
    return string.format("%04x%04x", math.random(0, 0xffff), math.random(0, 0xffff))
end

local function load_or_create_token()
    local f = io.open(TOKEN_PATH, "r")
    if f then
        local t = f:read("*l")
        f:close()
        if t and #t >= 8 then return t end
    end
    local t = generate_token()
    local fw = io.open(TOKEN_PATH, "w")
    if fw then fw:write(t) fw:close() end
    return t
end

local function check_auth(headers)
    return headers["x-bridge-token"] == auth_token
end

-- ── JSON response ─────────────────────────────────────────────────────────────

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
    return client:receive(len) or ""
end

-- ── reader access ─────────────────────────────────────────────────────────────

local function get_reader()
    local ui = package.loaded["apps/reader/readerui"]
    if ui and ui.instance and ui.instance.document then
        return ui.instance
    end
    return nil
end

local function get_title(doc, file)
    local ok, props = pcall(function() return doc:getProps() end)
    if ok and props and props.title and props.title ~= "" then
        return props.title
    end
    if file and file ~= "" then
        return file:match("([^/]+)%.[^%.]+$") or file:match("([^/]+)$") or file
    end
    return "Unknown"
end

-- ── reading progress ──────────────────────────────────────────────────────────

local function get_progress()
    local ok, result = pcall(function()
        local instance = get_reader()
        if not instance then
            return { title = "No book open", authors = "", file = "", page = 0, total = 0, percent = 0 }
        end
        local doc  = instance.document
        local file = doc.file or ""
        local page = 0
        if instance.rolling then
            page = instance.rolling.current_page or 0
        elseif instance.paging then
            local ok_cp, cp = pcall(function() return instance.paging:getCurrentPage() end)
            page = ok_cp and cp or 0
        end
        local ok_tot, total = pcall(function() return doc:getPageCount() or 0 end)
        local t = ok_tot and total or 0
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
    return { title = "error", error = tostring(result), page = 0, total = 0, percent = 0 }
end

-- ── highlights ────────────────────────────────────────────────────────────────

local function find_sdr_dir(file)
    -- KOReader strips the file extension before naming the sidecar folder
    -- e.g. "Book.mobi" -> "Book.sdr"  (NOT "Book.mobi.sdr")
    local without_ext = file:match("^(.+)%.[^%.]+$") or file
    local candidates = {
        without_ext .. ".sdr",
        file .. ".sdr",
    }
    for _, candidate in ipairs(candidates) do
        local attr = lfs.attributes(candidate)
        if attr and attr.mode == "directory" then
            return candidate
        end
    end
    return nil
end

local function find_meta_file(sdr_dir)
    -- escape special chars for shell
    local escaped = sdr_dir:gsub("'", "'\\''")
    local f = io.popen("ls -1 '" .. escaped .. "' 2>/dev/null")
    if not f then return nil end
    local result = nil
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line:match("^metadata%..*%.lua$") then
            result = sdr_dir .. "/" .. line
            break
        end
    end
    f:close()
    return result
end

local function get_highlights()
    local ui = package.loaded["apps/reader/readerui"]
    if not (ui and ui.instance and ui.instance.document) then
        return { error = "no book open", highlights = {} }
    end
    local file = ui.instance.document.file or ""
    if file == "" then return { error = "no file path", highlights = {} } end

    local sdr_dir = find_sdr_dir(file)
    if not sdr_dir then
        return { error = "no sidecar found", file = file, highlights = {} }
    end

    local meta_file = find_meta_file(sdr_dir)
    if not meta_file then
        return { error = "no metadata file in sidecar", sdr_dir = sdr_dir, highlights = {} }
    end

    local chunk, lerr = loadfile(meta_file)
    if not chunk then return { error = tostring(lerr), highlights = {} } end
    local meta = chunk()
    if not meta then return { error = "sidecar returned nil", highlights = {} } end

    local results = {}

    -- KOReader stores highlights in "annotations" (newer builds)
    -- and may also use "bookmarks" with bm.highlighted (older builds)
    for _, ann in ipairs(meta.annotations or {}) do
        table.insert(results, {
            text    = ann.text    or "",
            chapter = ann.chapter or "",
            page    = ann.pageno  or 0,
            time    = ann.datetime or "",
            drawer  = ann.drawer  or "",
        })
    end

    -- fallback: older KOReader used bookmarks with highlighted=true
    if #results == 0 then
        for _, bm in ipairs(meta.bookmarks or {}) do
            if bm.highlighted then
                table.insert(results, {
                    text    = bm.notes    or "",
                    chapter = bm.chapter  or "",
                    page    = bm.page     or 0,
                    time    = bm.datetime or "",
                    drawer  = "",
                })
            end
        end
    end

    return {
        title      = get_title(ui.instance.document, file),
        authors    = "",
        file       = file,
        total      = #results,
        highlights = results,
    }
end

-- ── POST /text ────────────────────────────────────────────────────────────────

local function handle_text(client, headers)
    local body = read_body(client, headers)
    if body == "" then send_json(client, "400 Bad Request", { error = "empty body" }) return end
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
        send_json(client, "400 Bad Request", { error = "missing X-Filename header" }) return
    end
    filename = filename:match("([^/\\]+)$") or filename
    local len = tonumber(headers["content-length"]) or 0
    if len == 0 then send_json(client, "400 Bad Request", { error = "empty file" }) return end
    local data, err = client:receive(len)
    if not data then send_json(client, "500 Internal Server Error", { error = tostring(err) }) return end
    local dest = DOCUMENTS_DIR .. filename
    local f, ferr = io.open(dest, "wb")
    if not f then send_json(client, "500 Internal Server Error", { error = tostring(ferr) }) return end
    f:write(data) f:close()
    send_json(client, "200 OK", { ok = true, filename = filename, bytes = len, path = dest })
    UIManager:scheduleIn(0.1, function()
        pcall(function()
            UIManager:show(InfoMessage:new{ text = "File received:\n" .. filename, timeout = 4 })
        end)
    end)
end

-- ── POST /cmd ─────────────────────────────────────────────────────────────────

local COMMANDS = {
    next_page  = function() UIManager:sendEvent(Event:new("GotoViewRel",  1)) end,
    prev_page  = function() UIManager:sendEvent(Event:new("GotoViewRel", -1)) end,
    first_page = function() UIManager:sendEvent(Event:new("GotoPage", 1)) end,
    last_page  = function()
        local ok, ui = pcall(require, "apps/reader/readerui")
        if ok and ui and ui.instance and ui.instance.document then
            UIManager:sendEvent(Event:new("GotoPage", ui.instance.document:getPageCount() or 1))
        end
    end,
    open_book = function(params)
        if not params or not params.file then return end
        local ok, ui = pcall(require, "apps/reader/readerui")
        if ok and ui and ui.instance then ui.instance:switchDocument(params.file) end
    end,
}

local function handle_cmd(client, headers)
    local body = read_body(client, headers)
    if body == "" then send_json(client, "400 Bad Request", { error = "empty body" }) return end
    local ok, data = pcall(json.decode, body)
    if not ok or not data or not data.cmd then
        send_json(client, "400 Bad Request", { error = "invalid JSON or missing cmd" }) return
    end
    local handler = COMMANDS[data.cmd]
    if not handler then
        send_json(client, "400 Bad Request", {
            error = "unknown command: " .. tostring(data.cmd),
            available = { "next_page", "prev_page", "first_page", "last_page", "open_book" },
        }) return
    end
    send_json(client, "200 OK", { ok = true, cmd = data.cmd })
    UIManager:scheduleIn(0.1, function() pcall(handler, data) end)
end

-- ── SSE ───────────────────────────────────────────────────────────────────────

local sse_keepalive = 0

local function sse_send(client, event, data_tbl)
    local payload = "event: " .. event .. "\ndata: " .. json.encode(data_tbl) .. "\n\n"
    local ok, err = client:send(payload)
    if not ok then
        pcall(function() client:close() end)
        sse_client = nil
    end
end

local function handle_events(client)
    client:settimeout(0)
    client:send(table.concat({
        "HTTP/1.1 200 OK",
        "Content-Type: text/event-stream",
        "Cache-Control: no-cache",
        "Access-Control-Allow-Origin: *",
        "Connection: keep-alive",
        "", "",
    }, "\r\n"))
    if sse_client then pcall(function() sse_client:close() end) end
    sse_client    = client
    sse_keepalive = 0
    last_page     = -1
    last_title    = ""
    local progress = get_progress()
    last_page  = progress.page
    last_title = progress.title
    sse_send(client, "progress", progress)
end

local function sse_tick()
    if not sse_client then return end
    sse_keepalive = sse_keepalive + 1
    if sse_keepalive >= 20 then
        sse_keepalive = 0
        local ok, err = sse_client:send(": keepalive\n\n")
        if not ok then
            pcall(function() sse_client:close() end)
            sse_client = nil
            return
        end
    end
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

    local public = (path == "/ping" or path == "/token")
    if not public and not check_auth(headers) then
        send_json(client, "401 Unauthorized", { error = "missing or invalid X-Bridge-Token" })
        return
    end

    if     method == "GET"  and path == "/ping"       then
        send_json(client, "200 OK", {
            ok = true, service = "kindle-bridge", version = "4.0.0",
            ip = get_local_ip(), port = PORT,
        })
    elseif method == "GET"  and path == "/token"      then
        send_json(client, "200 OK", { token = auth_token })
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
    elseif method == "GET"  and path == "/debug-sdr"   then
        local file = ""
        local ui = package.loaded["apps/reader/readerui"]
        if ui and ui.instance and ui.instance.document then
            file = ui.instance.document.file or ""
        end
        local without_ext = file:match("^(.+)%.[^%.]+$") or file
        local sdr_dir = without_ext .. ".sdr"

        -- find metadata file
        local escaped = sdr_dir:gsub("'", "'\''")
        local meta_file = nil
        local sdr_files = {}
        local f1 = io.popen("ls -1 '" .. escaped .. "' 2>/dev/null")
        if f1 then
            for line in f1:lines() do
                line = line:match("^%s*(.-)%s*$")
                table.insert(sdr_files, line)
                if line:match("^metadata%..*%.lua$") then
                    meta_file = sdr_dir .. "/" .. line
                end
            end
            f1:close()
        end

        -- read raw bookmarks from metadata
        local bookmarks_raw = {}
        if meta_file then
            local chunk = loadfile(meta_file)
            if chunk then
                local meta = chunk()
                if meta and meta.bookmarks then
                    for i, bm in ipairs(meta.bookmarks) do
                        local entry = {}
                        for k, v in pairs(bm) do
                            entry[k] = tostring(v)
                        end
                        table.insert(bookmarks_raw, entry)
                        if i >= 5 then break end  -- max 5 for debug
                    end
                end
            end
        end

        -- also read raw content of metadata file (first 800 chars)
        local meta_content = ""
        if meta_file then
            local mf = io.open(meta_file, "r")
            if mf then
                meta_content = mf:read(800) or ""
                mf:close()
            end
        end

        send_json(client, "200 OK", {
            file          = file,
            sdr_dir       = sdr_dir,
            sdr_files     = sdr_files,
            meta_file     = meta_file or "not found",
            meta_content  = meta_content,
            bookmarks_raw = bookmarks_raw,
            total_raw     = #bookmarks_raw,
        })
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
            logger.err("KindleBridge: " .. tostring(err))
            pcall(function() client:close() end)
        end
    end
    pcall(sse_tick)
    UIManager:scheduleIn(0.5, timer_func)
end

-- ── plugin lifecycle ──────────────────────────────────────────────────────────

function KindleBridge:init()
    if server then return end
    auth_token = load_or_create_token()
    local srv, err = socket.bind("*", PORT)
    if not srv then
        UIManager:show(InfoMessage:new{ text = "Kindle Bridge\nERROR: " .. tostring(err), timeout = 6 })
        return
    end
    srv:settimeout(0)
    server = srv
    timer_func = function() tick() end
    UIManager:scheduleIn(0.5, timer_func)
    local ip = get_local_ip()
    UIManager:show(InfoMessage:new{
        text = string.format("Kindle Bridge v4\nhttp://%s:%d", ip, PORT),
        timeout = 4,
    })
    logger.info("KindleBridge: listening on " .. ip .. ":" .. PORT)
end

function KindleBridge:onCloseWidget() end

function KindleBridge:onKOReaderClose()
    if sse_client  then pcall(function() sse_client:close()  end) sse_client  = nil end
    if server      then server:close() server = nil end
    if timer_func  then UIManager:unschedule(timer_func) timer_func = nil end
end

function KindleBridge:onReaderReady()
    last_page  = -1
    last_title = ""
end

return KindleBridge