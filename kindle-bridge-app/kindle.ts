// kindle.ts — all communication with the Kindle Bridge HTTP server

const TIMEOUT_MS = 5000;

export interface KindleConfig {
  ip: string;
  port: number;
  token: string;
}

export interface Progress {
  title: string;
  authors: string;
  file: string;
  page: number;
  total: number;
  percent: number;
}

export interface Highlight {
  text: string;
  chapter: string;
  page: number;
  time: string;
  drawer?: string;
}

export interface HighlightsResponse {
  title: string;
  authors: string;
  file: string;
  total: number;
  highlights: Highlight[];
  error?: string;
}

// ── helpers ───────────────────────────────────────────────────────────────────

function baseUrl(cfg: KindleConfig) {
  return `http://${cfg.ip}:${cfg.port}`;
}

async function get<T>(cfg: KindleConfig, path: string): Promise<T> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${baseUrl(cfg)}${path}`, {
      headers: { 'X-Bridge-Token': cfg.token },
      signal: ctrl.signal,
    });
    return res.json() as Promise<T>;
  } finally {
    clearTimeout(timer);
  }
}

async function post<T>(cfg: KindleConfig, path: string, body: object): Promise<T> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${baseUrl(cfg)}${path}`, {
      method: 'POST',
      headers: {
        'X-Bridge-Token': cfg.token,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    return res.json() as Promise<T>;
  } finally {
    clearTimeout(timer);
  }
}

// ── discovery ─────────────────────────────────────────────────────────────────

export async function discoverKindle(
  subnet: string,
  onProgress?: (scanned: number, total: number) => void,
): Promise<KindleConfig | null> {
  const PORT = 8080;
  const BATCH = 20;
  const candidates = Array.from({ length: 254 }, (_, i) => `${subnet}.${i + 1}`);

  for (let i = 0; i < candidates.length; i += BATCH) {
    const batch = candidates.slice(i, i + BATCH);
    onProgress?.(i, candidates.length);

    const results = await Promise.all(
      batch.map(async (ip) => {
        try {
          const ctrl = new AbortController();
          setTimeout(() => ctrl.abort(), 1000);
          const res = await fetch(`http://${ip}:${PORT}/ping`, { signal: ctrl.signal });
          const data = await res.json();
          if (data?.service === 'kindle-bridge') return ip;
        } catch {
          // not this host
        }
        return null;
      }),
    );

    const found = results.find((ip) => ip !== null);
    if (found) {
      // fetch token
      const tokenRes = await fetch(`http://${found}:${PORT}/token`);
      const { token } = await tokenRes.json();
      return { ip: found, port: PORT, token };
    }
  }
  onProgress?.(candidates.length, candidates.length);
  return null;
}

// ── API calls ─────────────────────────────────────────────────────────────────

export function getProgress(cfg: KindleConfig) {
  return get<Progress>(cfg, '/progress');
}

export function getHighlights(cfg: KindleConfig) {
  return get<HighlightsResponse>(cfg, '/highlights');
}

export function sendText(cfg: KindleConfig, text: string) {
  return post<{ ok: boolean }>(cfg, '/text', { text });
}

export function sendCmd(cfg: KindleConfig, cmd: string, extra?: object) {
  return post<{ ok: boolean }>(cfg, '/cmd', { cmd, ...extra });
}

export async function pushFile(
  cfg: KindleConfig,
  filename: string,
  fileUri: string,
  onProgress?: (sent: number, total: number) => void,
): Promise<{ ok: boolean; bytes?: number; error?: string }> {
  try {
    onProgress?.(0, 1);

    // Use the new SDK 54 File API to read file as ArrayBuffer
    const { File } = await import('expo-file-system');
    const file = new File(fileUri);
    const arrayBuffer = await file.arrayBuffer();
    const bytes = new Uint8Array(arrayBuffer);
    const total = bytes.length;
    onProgress?.(0, total);

    // Upload via XHR with progress tracking
    return new Promise((resolve) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', `http://${cfg.ip}:${cfg.port}/file-sync`);
      xhr.setRequestHeader('X-Bridge-Token', cfg.token);
      xhr.setRequestHeader('X-Filename', filename);
      xhr.setRequestHeader('Content-Type', 'application/octet-stream');
      xhr.timeout = 120000;

      xhr.upload.onprogress = (e) => {
        onProgress?.(e.loaded, e.lengthComputable ? e.total : total);
      };
      xhr.onload = () => {
        onProgress?.(total, total);
        try { resolve(JSON.parse(xhr.responseText)); }
        catch { resolve({ ok: false, error: `HTTP ${xhr.status}` }); }
      };
      xhr.onerror   = () => resolve({ ok: false, error: 'Network error' });
      xhr.ontimeout = () => resolve({ ok: false, error: 'Timeout' });
      xhr.send(bytes.buffer);
    });
  } catch (e: any) {
    return { ok: false, error: e.message ?? 'File read error' };
  }
}

// ── SSE stream ────────────────────────────────────────────────────────────────

export function openEventStream(
  cfg: KindleConfig,
  onProgress: (p: Progress) => void,
  onError: (err: string) => void,
): () => void {
  let active = true;

  async function connect() {
    try {
      const ctrl = new AbortController();
      const res = await fetch(`${baseUrl(cfg)}/events`, {
        headers: { 'X-Bridge-Token': cfg.token },
        signal: ctrl.signal,
      });

      if (!res.body) { onError('No response body'); return; }
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      while (active) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const parts = buffer.split('\n\n');
        buffer = parts.pop() ?? '';
        for (const chunk of parts) {
          if (chunk.startsWith(':')) continue; // keepalive
          const dataLine = chunk.split('\n').find((l) => l.startsWith('data:'));
          if (dataLine) {
            try {
              const p = JSON.parse(dataLine.slice(5).trim()) as Progress;
              onProgress(p);
            } catch {
              // malformed event
            }
          }
        }
      }
      reader.cancel();
    } catch (e: any) {
      if (active) {
        onError(e.message ?? 'SSE error');
        // reconnect after 3s
        setTimeout(() => { if (active) connect(); }, 3000);
      }
    }
  }

  connect();
  return () => { active = false; };
}