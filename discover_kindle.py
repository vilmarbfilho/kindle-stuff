import socket
import asyncio
import aiohttp
import sys

BATCH_SIZE = 20   # scan 20 hosts at a time — safe for Kindle's single-threaded server
PORT       = 8080
TIMEOUT    = 1.5

async def probe(session, ip):
    try:
        url = f"http://{ip}:{PORT}/ping"
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=TIMEOUT)) as r:
            if r.status == 200:
                data = await r.json(content_type=None)
                if data.get("service") == "kindle-bridge":
                    return ip, data
    except Exception:
        pass
    return None, None

async def get_subnet():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    local_ip = s.getsockname()[0]
    s.close()
    prefix = ".".join(local_ip.split(".")[:3])
    print(f"Local IP : {local_ip}")
    print(f"Scanning : {prefix}.1 – {prefix}.254 in batches of {BATCH_SIZE} ...")
    return prefix

async def main():
    prefix = await get_subnet()
    candidates = [f"{prefix}.{i}" for i in range(1, 255)]

    found = []
    connector = aiohttp.TCPConnector(limit=BATCH_SIZE)
    async with aiohttp.ClientSession(connector=connector) as session:
        for i in range(0, len(candidates), BATCH_SIZE):
            batch = candidates[i:i + BATCH_SIZE]
            end_ip = batch[-1].split(".")[-1]
            print(f"  Trying .{i+1} – .{end_ip} ...", end="\r")
            tasks = [probe(session, ip) for ip in batch]
            results = await asyncio.gather(*tasks)
            for ip, data in results:
                if ip is not None:
                    found.append((ip, data))
                    print(f"\n  ✓ Found at {ip}")

    print()
    if not found:
        print("No Kindle Bridge found.")
        print("Make sure KOReader is open and on the same Wi-Fi network.")
        sys.exit(1)

    kindle_ip, ping_data = found[0]
    print(f"Kindle Bridge at {kindle_ip}:{PORT}")
    print(f"  Version : {ping_data.get('version')}")

    # fetch token
    async with aiohttp.ClientSession() as session:
        async with session.get(f"http://{kindle_ip}:{PORT}/token") as r:
            token = (await r.json(content_type=None)).get("token")
    print(f"  Token   : {token}")

    # authenticated progress check
    headers = {"X-Bridge-Token": token}
    async with aiohttp.ClientSession(headers=headers) as session:
        async with session.get(f"http://{kindle_ip}:{PORT}/progress") as r:
            p = await r.json(content_type=None)
    print(f"\nCurrent reading:")
    print(f"  Title   : {p.get('title')}")
    print(f"  Page    : {p.get('page')} / {p.get('total')}")
    print(f"  Percent : {p.get('percent')}%")
    print(f"\nDiscovery complete. Save this for the app:")
    print(f"  KINDLE_IP    = {kindle_ip}")
    print(f"  KINDLE_TOKEN = {token}")

if __name__ == "__main__":
    asyncio.run(main())