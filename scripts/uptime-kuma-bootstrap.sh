#!/bin/sh
# Auto-initialization script for Uptime Kuma.
# Waits for the container to be healthy, then:
#   1. Configures Docker host and container monitors via Socket.IO
# Uses docker exec to run Node.js inside the Uptime Kuma container — no external image needed.
# Idempotent: each step is skipped if already configured.
# Note: ntfy notification must be configured manually in the Uptime Kuma web UI.

set -e

MAX_RETRIES=90
RETRY_INTERVAL=2

log() {
    echo "[uptime-kuma-bootstrap] $(date '+%H:%M:%S') $*" >&2
}

wait_for_container() {
    log "Waiting for uptime-kuma container to appear..."
    for i in $(seq 1 "$MAX_RETRIES"); do
        if docker ps --format '{{.Names}}' | grep -q '^pi-uptime-kuma$'; then
            log "Container is running"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done
    log "ERROR: uptime-kuma container did not start in time"
    return 1
}

wait_for_healthy() {
    local status
    log "Waiting for uptime-kuma to become healthy..."
    for i in $(seq 1 "$MAX_RETRIES"); do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' pi-uptime-kuma 2>/dev/null || true)
        if [ "$status" = "healthy" ]; then
            log "Container is healthy"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done
    log "ERROR: uptime-kuma did not become healthy in time"
    return 1
}

configure_uptime_kuma() {
    local js_script

    log "Configuring Uptime Kuma via Socket.IO (Docker host + monitors)..."

    js_script=$(mktemp /tmp/uptime-kuma-bootstrap-XXXXXX.js)
    trap 'rm -f "$js_script"' EXIT INT TERM

    cat > "$js_script" << 'JSEOF'
'use strict';
const http = require('http');

const PORT          = 3001;
const SOCKET_PATH   = '/var/run/docker.sock';
const CONTAINERS    = [
  'pi-backrest','pi-beszel','pi-beszel-agent','pi-ddns-updater',
  'pi-headplane','pi-headscale','pi-homepage','pi-immich',
  'pi-n8n','pi-nextcloud','pi-ntfy','pi-pihole',
  'pi-portainer','pi-postgres','pi-redis','pi-tailscale',
  'pi-traefik','pi-unbound','pi-uptime-kuma','pi-watchtower',
];

const RS = '\x1e'; // EIO4 packet delimiter
let sid, nextId = 0;
const ackResults = {};
const state = { dockerHostList: null, monitorList: null };

function toList(v) { return Array.isArray(v) ? v : (v ? Object.values(v) : []); }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function httpGet(path) {
  return new Promise((res, rej) => {
    http.get({ host: '127.0.0.1', port: PORT, path }, r => {
      let d = ''; r.on('data', c => d += c); r.on('end', () => res(d));
    }).on('error', rej);
  });
}

function httpPost(path, body) {
  return new Promise((res, rej) => {
    const buf = Buffer.from(body);
    const req = http.request({
      host: '127.0.0.1', port: PORT, path, method: 'POST',
      headers: { 'Content-Type': 'text/plain;charset=UTF-8', 'Content-Length': buf.length },
    }, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => res(d)); });
    req.on('error', rej); req.write(buf); req.end();
  });
}

function processPackets(raw) {
  for (const p of raw.split(RS).filter(Boolean)) {
    if (p === '2') { // EIO PING → PONG
      httpPost(`/socket.io/?EIO=4&transport=polling&sid=${sid}`, '3').catch(() => {});
      continue;
    }
    if (p[0] !== '4') continue; // skip non-MESSAGE EIO packets
    if (p[1] === '2') { // Socket.IO EVENT (server push)
      try {
        const [event, payload] = JSON.parse(p.slice(2));
        if      (event === 'dockerHostList' && !state.dockerHostList) state.dockerHostList = toList(payload);
        else if (event === 'monitorList'   && !state.monitorList)   state.monitorList   = toList(payload);
      } catch (_) {}
    } else if (p[1] === '3') { // Socket.IO ACK: 43<id>[data]
      try {
        const rest = p.slice(2);
        const bi = rest.search(/[\[{]/);
        if (bi >= 0) {
          const parsed = JSON.parse(rest.slice(bi));
          ackResults[+rest.slice(0, bi)] = Array.isArray(parsed) ? parsed[0] : parsed;
        }
      } catch (_) {}
    }
  }
}

const sioPath = () => `/socket.io/?EIO=4&transport=polling&sid=${sid}`;
const poll    = async () => processPackets(await httpGet(sioPath()));

async function emit(event, ...args) {
  const id = nextId++;
  await httpPost(sioPath(), `42${id}${JSON.stringify([event, ...args])}`);
  for (let i = 0; i < 30; i++) {
    if (id in ackResults) return ackResults[id];
    await poll();
    await sleep(150);
  }
  throw new Error(`ACK timeout for '${event}'`);
}

async function main() {
  // ── Handshake ─────────────────────────────────────────────────────────────
  const hs = await httpGet('/socket.io/?EIO=4&transport=polling');
  for (const p of hs.split(RS).filter(Boolean))
    if (p[0] === '0') sid = JSON.parse(p.slice(1)).sid;
  if (!sid) throw new Error('Handshake failed: ' + hs);
  processPackets(hs); // handle 40 (namespace connect) if bundled in response
  await poll();       // ensure namespace connect is received
  // UPTIME_KUMA_DISABLE_AUTH=1 — server auto-authenticates on connect, no login emit needed

  // ── Collect server-pushed state ───────────────────────────────────────────
  for (let i = 0; i < 20 && !(state.dockerHostList && state.monitorList); i++)
    { await poll(); await sleep(200); }
  if (!state.dockerHostList || !state.monitorList)
    throw new Error('Timeout waiting for server state');

  // ── 1. Docker host ────────────────────────────────────────────────────────
  let dockerHostId;
  const existingHost = state.dockerHostList.find(h => h.dockerDaemon === SOCKET_PATH);
  if (existingHost) {
    dockerHostId = existingHost.id;
    console.log(`Docker host already configured (id=${dockerHostId}), skipping`);
  } else {
    const r = await emit('addDockerHost', { name: 'local', dockerType: 'socket', dockerDaemon: SOCKET_PATH }, null);
    if (!r.ok) console.error('Warning: addDockerHost failed: ' + r.msg);
    else { dockerHostId = r.id; console.log(`Docker host added: id=${dockerHostId}`); }
  }

  // ── 3. Container monitors ─────────────────────────────────────────────────
  if (dockerHostId != null) {
    const existing = new Set(state.monitorList.filter(m => m.type === 'docker').map(m => m.dockerContainer));
    let added = 0;
    for (const c of CONTAINERS) {
      if (existing.has(c)) continue;
      const r = await emit('addMonitor', {
        type: 'docker', name: c.replace(/^pi-/, ''), dockerContainer: c,
        dockerDaemon: dockerHostId, interval: 60, retryInterval: 60,
        resendInterval: 0, maxretries: 1, active: true,
      });
      if (r && r.ok) { console.log(`Monitor added: ${c}`); added++; }
      else console.error(`Warning: monitor failed for ${c}: ${r && r.msg}`);
    }
    console.log(`Added ${added} new container monitors`);
  }

  console.log('Bootstrap complete');
}

main().catch(e => { console.error('Error:', e.message || String(e)); process.exit(1); });
JSEOF

    docker exec -i pi-uptime-kuma node - < "$js_script"

    rm -f "$js_script"
    trap - EXIT INT TERM
}

main() {
    log "=== Uptime Kuma Bootstrap ==="

    wait_for_container
    wait_for_healthy
    configure_uptime_kuma

    log "Bootstrap completed successfully"
}

main "$@"
