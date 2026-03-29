local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Event = require("ui/event")
local logger = require("logger")
local socket = require("socket")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")

local KindleBridge = WidgetContainer:extend{ name = "kindle-bridge" }

local PORT       = 8080
local TOKEN_PATH = "/mnt/us/koreader/kindle-bridge-token.txt"

local server     = nil
local timer_func = nil
local sse_client = nil
local last_page  = -1
local last_title = ""
local auth_token = nil
local DOCUMENTS_DIR = "/mnt/us/documents/"

-- pending file upload state (persists across ticks)
local pending_file = nil  -- { client, filename, dest_path, file_handle, remaining, received }

-- ── helpers ───────────────────────────────────────────────────────────────────

local function get_local_ip()
    local udp = socket.udp()
    if not udp then return "unknown" end
    udp:setpeername("8.8.8.8", 80)
    local ip = udp:getsockname()
    udp:close()
    return ip or "unknown"
end

local function generate_token()
    math.randomseed(os.time())
    return string.format("%04x%04x", math.random(0, 0xffff), math.random(0, 0xffff))
end

local function load_or_create_token()
    local f = io.open(TOKEN_PATH, "r")
    if f then
        local t = f:read("*l"); f:close()
        if t and #t >= 8 then return t end
    end
    local t = generate_token()
    local fw = io.open(TOKEN_PATH, "w")
    if fw then fw:write(t); fw:close() end
    return t
end

local function check_auth(headers)
    return headers["x-bridge-token"] == auth_token
end

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

local function read_body(client, headers)
    local len = tonumber(headers["content-length"]) or 0
    if len == 0 then return "" end
    return client:receive(len) or ""
end

-- ── reader ────────────────────────────────────────────────────────────────────

local function get_reader()
    local ui = package.loaded["apps/reader/readerui"]
    if ui and ui.instance and ui.instance.document then return ui.instance end
    return nil
end

local function get_title(doc, file)
    local ok, props = pcall(function() return doc:getProps() end)
    if ok and props and props.title and props.title ~= "" then return props.title end
    if file and file ~= "" then
        return file:match("([^/]+)%.[^%.]+$") or file:match("([^/]+)$") or file
    end
    return "Unknown"
end

local function get_progress()
    local ok, result = pcall(function()
        local inst = get_reader()
        if not inst then
            return { title="No book open", authors="", file="", page=0, total=0, percent=0 }
        end
        local doc  = inst.document
        local file = doc.file or ""
        local page, percent = 0, 0
        if inst.rolling then
            page    = inst.rolling.current_page or 0
            local ok2, pct = pcall(function() return inst.rolling:getLastPercent() end)
            percent = ok2 and math.floor((pct or 0) * 100) or 0
        elseif inst.paging then
            local ok2, p = pcall(function() return inst.paging:getCurrentPage() end)
            page = ok2 and p or 0
        end
        local ok3, total = pcall(function() return doc:getPageCount() or 0 end)
        local t = ok3 and total or 0
        if percent == 0 and t > 0 then percent = math.floor((page/t)*100) end
        return { title=get_title(doc,file), authors="", file=file, page=page, total=t, percent=percent }
    end)
    if ok then return result end
    return { title="error", error=tostring(result), page=0, total=0, percent=0 }
end

-- ── highlights ────────────────────────────────────────────────────────────────

local function find_sdr_dir(file)
    local without_ext = file:match("^(.+)%.[^%.]+$") or file
    for _, candidate in ipairs({ without_ext..".sdr", file..".sdr" }) do
        local attr = lfs.attributes(candidate)
        if attr and attr.mode == "directory" then return candidate end
    end
    return nil
end

local function find_meta_file(sdr_dir)
    local escaped = sdr_dir:gsub("'", "'\\''")
    local f = io.popen("ls -1 '"..escaped.."' 2>/dev/null")
    if not f then return nil end
    local result = nil
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line:match("^metadata%..*%.lua$") then result = sdr_dir.."/"..line; break end
    end
    f:close()
    return result
end

local function get_highlights()
    local ui = package.loaded["apps/reader/readerui"]
    if not (ui and ui.instance and ui.instance.document) then
        return { error="no book open", highlights={} }
    end
    local file = ui.instance.document.file or ""
    if file == "" then return { error="no file path", highlights={} } end
    local sdr_dir = find_sdr_dir(file)
    if not sdr_dir then return { error="no sidecar found", file=file, highlights={} } end
    local meta_file = find_meta_file(sdr_dir)
    if not meta_file then return { error="no metadata file in sidecar", sdr_dir=sdr_dir, highlights={} } end
    local chunk, lerr = loadfile(meta_file)
    if not chunk then return { error=tostring(lerr), highlights={} } end
    local meta = chunk()
    if not meta then return { error="sidecar returned nil", highlights={} } end
    local results = {}
    for _, ann in ipairs(meta.annotations or {}) do
        table.insert(results, { text=ann.text or "", chapter=ann.chapter or "", page=ann.pageno or 0, time=ann.datetime or "", drawer=ann.drawer or "" })
    end
    if #results == 0 then
        for _, bm in ipairs(meta.bookmarks or {}) do
            if bm.highlighted then
                table.insert(results, { text=bm.notes or "", chapter=bm.chapter or "", page=bm.page or 0, time=bm.datetime or "", drawer="" })
            end
        end
    end
    return { title=get_title(ui.instance.document,file), authors="", file=file, total=#results, highlights=results }
end

-- ── POST handlers ─────────────────────────────────────────────────────────────

local function handle_text(client, headers)
    local body = read_body(client, headers)
    if body == "" then send_json(client, "400 Bad Request", { error="empty body" }); return end
    local ok, data = pcall(json.decode, body)
    local text = (ok and data and data.text) or body
    send_json(client, "200 OK", { ok=true, received=#text })
    UIManager:scheduleIn(0.1, function()
        pcall(function() UIManager:show(InfoMessage:new{ text="iPhone says:\n"..text, timeout=8 }) end)
    end)
end

local function handle_file_start(client, headers)
    logger.info("KindleBridge: /file called")
    local filename = headers["x-filename"]
    logger.info("KindleBridge: x-filename = " .. tostring(filename))
    if not filename or filename == "" then
        send_json(client, "400 Bad Request", { error="missing X-Filename header" }); return
    end
    filename = filename:match("([^/\\]+)$") or filename
    local len = tonumber(headers["content-length"]) or 0
    logger.info("KindleBridge: content-length = " .. tostring(len))
    if len == 0 then
        send_json(client, "400 Bad Request", { error="missing Content-Length" }); return
    end
    local dest = DOCUMENTS_DIR .. filename
    local f, ferr = io.open(dest, "wb")
    if not f then
        logger.err("KindleBridge: cannot open dest: " .. tostring(ferr))
        send_json(client, "500 Internal Server Error", { error=tostring(ferr) }); return
    end
    client:settimeout(0)
    pending_file = {
        client   = client,
        filename = filename,
        dest     = dest,
        handle   = f,
        total    = len,
        received = 0,
    }
    logger.info("KindleBridge: pending_file set, waiting for data ticks")
end

local function handle_file_start_sync(client, headers)
    -- synchronous fallback: read entire body with a generous timeout
    logger.info("KindleBridge: /file-sync called")
    local filename = headers["x-filename"]
    if not filename or filename == "" then
        send_json(client, "400 Bad Request", { error="missing X-Filename header" }); return
    end
    filename = filename:match("([^/\\]+)$") or filename
    local len = tonumber(headers["content-length"]) or 0
    logger.info("KindleBridge: sync upload "..filename.." len="..len)
    if len == 0 then
        send_json(client, "400 Bad Request", { error="missing Content-Length" }); return
    end
    -- set a long timeout and read all at once
    client:settimeout(60)
    local data, err, partial = client:receive(len)
    local got = data or partial or ""
    logger.info("KindleBridge: received "..#got.." bytes, err="..tostring(err))
    if #got == 0 then
        send_json(client, "500 Internal Server Error", { error="no data: "..tostring(err) }); return
    end
    local dest = DOCUMENTS_DIR .. filename
    local f, ferr = io.open(dest, "wb")
    if not f then
        send_json(client, "500 Internal Server Error", { error=tostring(ferr) }); return
    end
    f:write(got); f:close()
    logger.info("KindleBridge: file saved to "..dest)
    send_json(client, "200 OK", { ok=true, filename=filename, bytes=#got, path=dest })
    UIManager:scheduleIn(0.1, function()
        pcall(function()
            UIManager:show(InfoMessage:new{ text="File received:\n"..filename, timeout=4 })
        end)
    end)
end

local function tick_pending_file()
    if not pending_file then return end
    local pf = pending_file
    local CHUNK = 4096
    local to_read = math.min(CHUNK, pf.total - pf.received)
    if to_read <= 0 then
        -- done
        pf.handle:close()
        send_json(pf.client, "200 OK", { ok=true, filename=pf.filename, bytes=pf.received, path=pf.dest })
        UIManager:scheduleIn(0.1, function()
            pcall(function()
                UIManager:show(InfoMessage:new{ text="File received:\n"..pf.filename, timeout=4 })
            end)
        end)
        pending_file = nil
        return
    end
    -- non-blocking read — get whatever is available right now
    local chunk, err, partial = pf.client:receive(to_read)
    local got = chunk or partial
    if got and #got > 0 then
        pf.handle:write(got)
        pf.received = pf.received + #got
    elseif err == "closed" then
        pf.handle:close()
        if pf.received > 0 then
            send_json(pf.client, "200 OK", { ok=true, filename=pf.filename, bytes=pf.received, path=pf.dest })
        else
            os.remove(pf.dest)
            pcall(function() pf.client:close() end)
        end
        pending_file = nil
    end
    -- if err == "timeout" just wait for next tick
end

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
    if body == "" then send_json(client, "400 Bad Request", { error="empty body" }); return end
    local ok, data = pcall(json.decode, body)
    if not ok or not data or not data.cmd then
        send_json(client, "400 Bad Request", { error="invalid JSON or missing cmd" }); return
    end
    local handler = COMMANDS[data.cmd]
    if not handler then
        send_json(client, "400 Bad Request", { error="unknown command: "..tostring(data.cmd),
            available={"next_page","prev_page","first_page","last_page","open_book"} }); return
    end
    send_json(client, "200 OK", { ok=true, cmd=data.cmd })
    UIManager:scheduleIn(0.1, function() pcall(handler, data) end)
end

-- ── SSE ───────────────────────────────────────────────────────────────────────

local sse_keepalive = 0

local function sse_send(client, event, data_tbl)
    local payload = "event: "..event.."\ndata: "..json.encode(data_tbl).."\n\n"
    local ok = client:send(payload)
    if not ok then pcall(function() client:close() end); sse_client = nil end
end

local function handle_events(client)
    client:settimeout(0)
    client:send(table.concat({
        "HTTP/1.1 200 OK","Content-Type: text/event-stream",
        "Cache-Control: no-cache","Access-Control-Allow-Origin: *",
        "Connection: keep-alive","","",
    }, "\r\n"))
    if sse_client then pcall(function() sse_client:close() end) end
    sse_client=client; sse_keepalive=0; last_page=-1; last_title=""
    local p = get_progress(); last_page=p.page; last_title=p.title
    sse_send(client, "progress", p)
end

local function sse_tick()
    if not sse_client then return end
    sse_keepalive = sse_keepalive + 1
    if sse_keepalive >= 20 then
        sse_keepalive = 0
        local ok = sse_client:send(": keepalive\n\n")
        if not ok then pcall(function() sse_client:close() end); sse_client=nil; return end
    end
    local p = get_progress()
    if p.page ~= last_page or p.title ~= last_title then
        last_page=p.page; last_title=p.title; sse_send(sse_client,"progress",p)
    end
end

-- ── router ────────────────────────────────────────────────────────────────────

local function handle(client)
    client:settimeout(2)
    local request, req_err = client:receive("*l")
    logger.info("KindleBridge: raw request=["..tostring(request).."] err=["..tostring(req_err).."]")
    if not request then client:close(); return end
    local method, path = request:match("^(%u+) (/[^ ]*) HTTP")
    logger.info("KindleBridge: method=["..tostring(method).."] path=["..tostring(path).."]")
    if not method then client:close(); return end
    local headers = parse_headers(client)
    logger.info("KindleBridge: headers parsed, content-length=["..tostring(headers["content-length"]).."] x-filename=["..tostring(headers["x-filename"]).."]")

    local public = (path == "/ping" or path == "/token")
    if not public and not check_auth(headers) then
        send_json(client, "401 Unauthorized", { error="missing or invalid X-Bridge-Token" }); return
    end

    if     method=="GET"  and path=="/ping"       then
        send_json(client,"200 OK",{ ok=true,service="kindle-bridge",version="4.0.0",ip=get_local_ip(),port=PORT })
    elseif method=="GET"  and path=="/token"      then send_json(client,"200 OK",{ token=auth_token })
    elseif method=="GET"  and path=="/progress"   then send_json(client,"200 OK",get_progress())
    elseif method=="GET"  and path=="/highlights" then send_json(client,"200 OK",get_highlights())
    elseif method=="GET"  and path=="/events"     then handle_events(client)
    elseif method=="POST" and path=="/text"       then handle_text(client,headers)
    elseif method=="POST" and path=="/file"       then handle_file_start(client,headers)
    elseif method=="POST" and path=="/file-sync"  then handle_file_start_sync(client,headers)
    elseif method=="POST" and path=="/cmd"        then handle_cmd(client,headers)
    else send_json(client,"404 Not Found",{ error="not found",path=path })
    end
end

-- ── tick ──────────────────────────────────────────────────────────────────────

local function tick()
    if not server then return end
    -- process pending file upload first
    if pending_file then
        pcall(tick_pending_file)
    else
        -- only accept new connections when not uploading
        local client = server:accept()
        if client then
            local ok, err = pcall(handle, client)
            if not ok then
                logger.err("KindleBridge: "..tostring(err))
                pcall(function() client:close() end)
            end
        end
    end
    pcall(sse_tick)
    UIManager:scheduleIn(0.5, timer_func)
end

-- ── lifecycle ─────────────────────────────────────────────────────────────────

function KindleBridge:init()
    if server then return end
    auth_token = load_or_create_token()
    -- create server socket with explicit backlog of 8
    local srv, err = socket.tcp()
    if not srv then
        UIManager:show(InfoMessage:new{ text="Kindle Bridge\nERROR: "..tostring(err), timeout=6 }); return
    end
    srv:setoption("reuseaddr", true)
    local ok_bind, bind_err = srv:bind("*", PORT)
    if not ok_bind then
        UIManager:show(InfoMessage:new{ text="Kindle Bridge\nBind ERROR: "..tostring(bind_err), timeout=6 }); return
    end
    local ok_listen, listen_err = srv:listen(8)
    if not ok_listen then
        UIManager:show(InfoMessage:new{ text="Kindle Bridge\nListen ERROR: "..tostring(listen_err), timeout=6 }); return
    end
    srv:settimeout(0); server=srv
    timer_func = function() tick() end
    UIManager:scheduleIn(0.5, timer_func)
    local ip = get_local_ip()
    UIManager:show(InfoMessage:new{ text=string.format("Kindle Bridge v4\nhttp://%s:%d",ip,PORT), timeout=4 })
    logger.info("KindleBridge: listening on "..ip..":"..PORT)
end

function KindleBridge:onCloseWidget() end

function KindleBridge:onKOReaderClose()
    if pending_file then pcall(function() pending_file.handle:close() end); pending_file=nil end
    if sse_client  then pcall(function() sse_client:close()  end); sse_client=nil end
    if server      then server:close(); server=nil end
    if timer_func  then UIManager:unschedule(timer_func); timer_func=nil end
end

function KindleBridge:onReaderReady() last_page=-1; last_title="" end

return KindleBridge