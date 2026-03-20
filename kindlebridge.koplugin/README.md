# Kindle Bridge

**Kindle Side — Technical Documentation**

*Version 4.0.0 · KOReader Plugin · Lua*

## 1. Overview

Kindle Bridge is a KOReader plugin that runs a lightweight HTTP server on a jailbroken 8th-generation Kindle. It exposes a REST API over local Wi-Fi that allows an iPhone app to communicate bidirectionally with the Kindle — sending text, pushing files, issuing page navigation commands, and receiving live reading progress via Server-Sent Events (SSE).

The plugin is written entirely in Lua and runs inside KOReader's own Lua runtime, requiring no external dependencies beyond the libraries already bundled with KOReader.

## 2. Requirements

### 2.1 Hardware

-   Kindle 8th generation (KindleBasic2)

-   Jailbroken device

-   Wi-Fi connection on the same local network as the iPhone

### 2.2 Software

-   KOReader v2026.03 or later

-   KUAL (Kindle Unified Application Launcher) — for manual plugin management

-   luasocket — bundled with KOReader, no separate installation needed

-   rapidjson — bundled with KOReader, no separate installation needed

## 3. Installation

### 3.1 Plugin files

The plugin consists of two files that must be placed in a folder named exactly kindle-bridge.koplugin inside KOReader's plugins directory.

Important: KOReader only loads plugins from folders ending in .koplugin. Any other folder name will be silently ignored.

### 3.2 Step-by-step

-   Connect the Kindle to your Mac via USB.

-   Navigate to /mnt/us/koreader/plugins/ on the Kindle's storage.

-   Create a new folder named kindle-bridge.koplugin.

-   Copy both _meta.lua and main.lua into that folder.

-   The final structure should be:

```
/mnt/us/koreader/plugins/kindle-bridge.koplugin/
    _meta.lua
    main.lua
```
-   Eject the Kindle and open KOReader.

-   On startup, a toast popup will appear showing the Kindle's IP and port.

### 3.3 Auth token

On first startup the plugin auto-generates an 8-character hex token and saves it to:

```
/mnt/us/koreader/kindle-bridge-token.txt
```
This file persists across KOReader restarts. You can read it directly via USB or fetch it from the /token endpoint (see Section 5). All API endpoints except /ping and /token require this token in the X-Bridge-Token request header.

## 4. Architecture

### 4.1 How it works

The plugin binds a TCP socket on port 8080 during KOReader's init() lifecycle call. A non-blocking server loop runs every 500ms via UIManager's scheduler — this is KOReader's cooperative multitasking mechanism. Each tick the loop accepts one pending connection, handles the request synchronously, and reschedules itself.

Because KOReader is single-threaded, the server handles one request at a time. This is sufficient for the intended use case of a single iPhone client.

### 4.2 Key design decisions

-   Non-blocking accept: socket:settimeout(0) ensures the tick returns immediately if no connection is waiting, keeping KOReader's UI responsive.

-   Single init guard: KOReader calls init() on every UI transition (home screen to reader and back). The plugin checks if the server is already running and skips rebinding to avoid 'address already in use' errors.

-   pcall everywhere: all document API calls are wrapped in pcall so errors are logged without crashing the server or KOReader.

-   SSE via the same tick: the SSE client is kept open and written to during the same 500ms tick that handles normal HTTP requests. Page changes are detected by comparing rolling.current_page against the last known value.

### 4.3 Reading state access

KOReader's reader instance is accessed via the Lua module cache:

```
local ui = package.loaded["apps/reader/readerui"]
```
This is more reliable than require() across UI transitions because it always returns the live cached module. The global ReaderUI is not available in this KOReader build.

For reflowable documents (mobi, epub), the current page is read from:

```
instance.rolling.current_page -- direct field, not a method
```
Reading percentage is obtained from:

```
instance.rolling:getLastPercent() -- returns 0.0 to 1.0
```
For paginated documents (PDF), the current page would come from:

```
instance.paging:getCurrentPage()
```
## 5. API Reference

### 5.1 Authentication

All endpoints except /ping and /token require the following HTTP header:

```
X-Bridge-Token: <your-token>
```
Requests missing the token or using an incorrect token receive a 401 Unauthorized response:

```
{"error": "missing or invalid X-Bridge-Token"}
```
### 5.2 Endpoint summary

  ----------------------------------------------------------------------------------------------------------
  **Method**   **Path**           **Auth**   **Description**
  ------------ ------------------ ---------- ---------------------------------------------------------------
  **GET**      /ping              Public     Health check. Returns service name, version, IP, port.

  **GET**      /token             Public     Returns the auth token. Use once to bootstrap the iPhone app.

  **GET**      /progress          Required   Current book title, file path, page, total pages, percent.

  **GET**      /highlights        Required   Highlights from the currently open book as JSON array.

  **GET**      /events            Required   SSE stream. Pushes a progress event on every page turn.

  **POST**     /text              Required   Display a text message as a popup on the Kindle screen.

  **POST**     /file              Required   Save a file directly to the Kindle documents folder.

  **POST**     /cmd               Required   Send a navigation command to KOReader.
  ----------------------------------------------------------------------------------------------------------

### 5.3 GET /ping

Public. Used by the iPhone for subnet discovery. Always returns 200.

Response example:

```
{
"ok": true,
"service": "kindle-bridge",
```>
```
"version": "4.0.0",
"ip": "192.168.0.106",
"port": 8080
```>
```
}
```
### 5.4 GET /token

Public. Returns the shared auth token. Fetch this once after discovery and store it in the iPhone app.

```
{"token": "20d3ec98"}
```
### 5.5 GET /progress

Returns the current reading state. If no book is open, all fields return defaults.

```
{
"title": "How to Tell a Story - The Moth",
"authors": "",
```>
```
"file": "/mnt/us/documents/How to Tell a Story - The Moth.mobi",
"page": 42,
"total": 504,
```>
```
"percent": 8
}
*title is derived from the filename when getProps() returns no title, which is common on some KOReader builds.*
```
### 5.6 GET /highlights

Returns all highlights for the currently open book. KOReader stores highlights in a sidecar folder next to each book file (e.g. MyBook.mobi.sdr/metadata.mobi.lua).

```
{
"title": "My Book",
"authors": "Unknown",
```>
```
"file": "/mnt/us/documents/MyBook.mobi",
"total": 3,
"highlights": [
```>
```
{ "text": "...", "chapter": "Ch 1", "page": 12, "time": "2026-03-20 10:00" }
]
}
```>
```
*Returns {"error": "no sidecar found"} if no highlights exist yet for the current book.*
```
### 5.7 GET /events

Opens a Server-Sent Events (SSE) stream. The connection stays open and the Kindle pushes a progress event every time the page changes, detected every 500ms.

Response headers:

```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```
Event format:

```
event: progress
data: {"title":"...","page":5,"total":200,"percent":2}
```
A keepalive comment is sent every 10 seconds to prevent connection timeout:

```
: keepalive
*Only one SSE subscriber is supported at a time. Connecting a second client drops the first.*
```
### 5.8 POST /text

Displays a text message as a popup overlay on the Kindle screen. The popup stays visible for 8 seconds.

Request body (JSON):

```
{"text": "Hello from iPhone!"}
```
Response:

```
{"ok": true, "received": 19}
```
### 5.9 POST /file

Saves a binary file directly to /mnt/us/documents/ on the Kindle. The file appears in the KOReader library immediately.

Required headers:

```
X-Bridge-Token: <token>
X-Filename: mybook.epub
Content-Length: <byte count>
```
Body: raw file bytes.

Response:

```
{"ok": true, "filename": "mybook.epub", "bytes": 204800, "path": "/mnt/us/documents/mybook.epub"}
*The filename is sanitised to strip any path components before saving.*
```
### 5.10 POST /cmd

Sends a navigation command to KOReader. The command is executed asynchronously after the HTTP response is sent.

Request body (JSON):

```
{"cmd": "next_page"}
```
Available commands:

  ---------------------------------------------------------------------------------------------
  **Command**        **Description**
  ------------------ --------------------------------------------------------------------------
  next_page          Turn to the next page.

  prev_page          Turn to the previous page.

  first_page         Jump to the first page.

  last_page          Jump to the last page.

  open_book          Open a specific file. Requires additional "file" param with full path.
  ---------------------------------------------------------------------------------------------

Open book example:

```
{"cmd": "open_book", "file": "/mnt/us/documents/mybook.epub"}
```
## 6. Device Discovery

The Kindle's Linux userspace blocks incoming UDP packets from external hosts (confirmed via testing), so mDNS and UDP broadcast discovery are not available. Discovery is implemented as an HTTP subnet scan.

### 6.1 How it works

-   The iPhone determines its own local IP (e.g. 192.168.0.102).

-   It derives the subnet prefix (192.168.0).

-   It sends GET /ping to all 254 hosts in parallel with a 1 second timeout.

-   The first host that returns {"service": "kindle-bridge"} is the Kindle.

-   The iPhone then fetches /token once and stores both IP and token persistently.

### 6.2 Python test script

A reference Python implementation is provided in discover_kindle.py. Run it from your Mac to verify discovery works before building the iPhone app:

```
pip3 install aiohttp
python3 discover_kindle.py
```
Expected output:

```
Local IP : 192.168.0.102
Scanning : 192.168.0.1 -- 192.168.0.254 in batches of 20 ...
Found at 192.168.0.106
```>
```
Kindle Bridge at 192.168.0.106:8080
Version : 4.0.0
Token : 20d3ec98
```
## 7. curl Quick Reference

Replace 192.168.0.106 with your Kindle's IP and 20d3ec98 with your token.

#### Health check (no auth)

```
curl http://192.168.0.106:8080/ping
```
#### Get token (no auth)

```
curl http://192.168.0.106:8080/token
```
#### Reading progress

```
curl -H "X-Bridge-Token: 20d3ec98" http://192.168.0.106:8080/progress
```
#### Highlights

```
curl -H "X-Bridge-Token: 20d3ec98" http://192.168.0.106:8080/highlights
```
#### Live events stream

```
curl -N -H "X-Bridge-Token: 20d3ec98" http://192.168.0.106:8080/events
```
#### Send text to Kindle

```
curl -X POST http://192.168.0.106:8080/text \
-H "X-Bridge-Token: 20d3ec98" \
-H "Content-Type: application/json" \
```>
```
-d '{"text":"Hello from iPhone!"}'
```
#### Push a file

```
curl -X POST http://192.168.0.106:8080/file \
-H "X-Bridge-Token: 20d3ec98" \
-H "X-Filename: mybook.epub" \
```>
```
--data-binary @/path/to/mybook.epub
```
#### Page navigation

```
curl -X POST http://192.168.0.106:8080/cmd \
-H "X-Bridge-Token: 20d3ec98" \
-H "Content-Type: application/json" \
```>
```
-d '{"cmd":"next_page"}'
```
## 8. File Structure

  ---------------------------------------------------------------------------------------------------------------
  **Path**                                           **Description**
  -------------------------------------------------- ------------------------------------------------------------
  /mnt/us/koreader/plugins/kindle-bridge.koplugin/
    _meta.lua
    main.lua   Plugin folder (must end in .koplugin)

  _meta.lua                                         Plugin metadata — name, version, description

  main.lua                                           All plugin logic — HTTP server, endpoints, SSE

  /mnt/us/koreader/kindle-bridge-token.txt           Auth token, auto-generated on first run

  /mnt/us/documents/                                 Target folder for POST /file uploads

  /mnt/us/documents/\<book\>.sdr/                    KOReader sidecar — highlights source for GET /highlights
  ---------------------------------------------------------------------------------------------------------------

## 9. Known Limitations

-   Single-threaded: one HTTP request is handled per 500ms tick. Concurrent requests queue up in the OS socket buffer.

-   Single SSE client: only one /events subscriber at a time. A new connection drops the previous one.

-   No UDP: the Kindle's network stack drops incoming UDP from external hosts. Discovery relies on HTTP subnet scanning instead.

-   No title metadata: getProps() returns an empty table on this KOReader build. Book titles are derived from the filename.

-   Rolling view only tested: the current_page field approach is confirmed working for mobi/epub. PDF (paging view) uses a different code path that has not been verified on this device.

-   Token is plaintext: the auth token is stored unencrypted in /mnt/us/koreader/kindle-bridge-token.txt. This is acceptable for a local Wi-Fi use case.

## 10. Troubleshooting

  ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  **Symptom**                                               **Fix**
  --------------------------------------------------------- ------------------------------------------------------------------------------------------------------------------------------------------------
  **Plugin does not appear in KOReader plugin manager**     Folder must be named exactly kindle-bridge.koplugin. Check the folder name on the Kindle's storage.

  **curl: (28) Failed to connect — timeout**              The server is not running. Check that KOReader is open and the startup toast appeared.

  **curl: (52) Empty reply from server**                    A Lua error crashed the request handler before send_json was called. Check the KOReader log for errors.

  **ERROR: address already in use on KOReader startup**     A stray end keyword in main.lua caused a syntax error that prevented the single-init guard from running. Validate Lua syntax before deploying.

  **GET /progress returns page 0 even with a book open**    The book uses a paging view (PDF). The rolling.current_page path does not apply. Use instance.paging:getCurrentPage() instead.

  **GET /highlights returns 'no sidecar found'**          No highlights have been created yet, or the sidecar file uses an unexpected extension. Check the .sdr folder next to the book file.

  **SSE stream shows only keepalive, no progress events**   Confirm GET /progress returns correct page data first. If progress works but SSE does not, check that last_page is being reset on book open.
  ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
