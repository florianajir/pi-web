#!/bin/sh
# Auto-initialization script for Uptime Kuma.
# Waits for the container to be healthy, then:
#   1. Configures ntfy notification, Docker host, and container monitors via Socket.IO
# Uses docker exec to run Node.js inside the Uptime Kuma container — no external image needed.
# Idempotent: each step is skipped if already configured.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="$PROJECT_DIR/.env"
NTFY_ENV_FILE="$PROJECT_DIR/config/ntfy/ntfy.env"
MAX_RETRIES=90
RETRY_INTERVAL=2
DEFAULT_NTFY_TOPIC="pi"

log() {
    echo "[uptime-kuma-bootstrap] $(date '+%H:%M:%S') $*" >&2
}

read_env_value_from_file() {
    local file="$1"
    local key="$2"
    if [ ! -f "$file" ]; then return 0; fi
    grep "^$key=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

get_env_value() { read_env_value_from_file "$ENV_FILE" "$1"; }
get_ntfy_env_value() { read_env_value_from_file "$NTFY_ENV_FILE" "$1"; }

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
    local ntfy_password="$1"
    local ntfy_topic="$2"
    local js_script

    log "Configuring Uptime Kuma via Socket.IO (ntfy + Docker host + monitors)..."

    js_script=$(mktemp /tmp/uptime-kuma-bootstrap-XXXXXX.js)
    trap 'rm -f "$js_script"' EXIT INT TERM

    cat > "$js_script" << 'JSEOF'
'use strict';
const http = require('http');

const PORT          = 3001;
const NTFY_PASSWORD = process.env.NTFY_UPTIME_KUMA_PASSWORD;
const NTFY_TOPIC    = process.env.NTFY_TOPIC || 'pi';
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
const state = { notificationList: null, dockerHostList: null, monitorList: null };

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
        if      (event === 'notificationList' && !state.notificationList) state.notificationList = toList(payload);
        else if (event === 'dockerHostList'   && !state.dockerHostList)   state.dockerHostList   = toList(payload);
        else if (event === 'monitorList'      && !state.monitorList)      state.monitorList      = toList(payload);
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

  // ── Login (auth disabled — empty creds accepted unconditionally) ──────────
  const login = await emit('login', { username: '', password: '', token: '' });
  if (!login || !login.ok) throw new Error('Login failed: ' + JSON.stringify(login));
  console.log('Login ok');

  // ── Collect server-pushed state ───────────────────────────────────────────
  for (let i = 0; i < 20 && !(state.notificationList && state.dockerHostList && state.monitorList); i++)
    { await poll(); await sleep(200); }
  if (!state.notificationList || !state.dockerHostList || !state.monitorList)
    throw new Error('Timeout waiting for server state');

  // ── 1. ntfy notification ──────────────────────────────────────────────────
  const existingNtfy = state.notificationList.find(n => n.type === 'ntfy');
  if (existingNtfy) {
    console.log(`ntfy already configured (id=${existingNtfy.id}), skipping`);
  } else {
    const r = await emit('addNotification', {
      id: null, name: 'ntfy', type: 'ntfy', isDefault: true, applyExisting: true,
      ntfyserverurl: 'http://ntfy', ntfytopic: NTFY_TOPIC,
      ntfyAuthenticationMethod: 'usernamePassword',
      ntfyusername: 'uptime-kuma', ntfypassword: NTFY_PASSWORD, ntfyPriority: 3,
    }, null);
    if (!r.ok) throw new Error('addNotification failed: ' + r.msg);
    console.log(`ntfy notification added: id=${r.id}`);
  }

  // ── 2. Docker host ────────────────────────────────────────────────────────
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

    docker exec -i \
        -e NTFY_UPTIME_KUMA_PASSWORD="$ntfy_password" \
        -e NTFY_TOPIC="$ntfy_topic" \
        pi-uptime-kuma node - < "$js_script"

    rm -f "$js_script"
    trap - EXIT INT TERM
}

main() {
    log "=== Uptime Kuma Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        log "ERROR: .env missing at $ENV_FILE"
        exit 1
    fi

    if [ ! -f "$NTFY_ENV_FILE" ]; then
        log "WARNING: $NTFY_ENV_FILE not found; skipping bootstrap"
        exit 0
    fi

    NTFY_UPTIME_KUMA_PASSWORD=$(get_ntfy_env_value NTFY_UPTIME_KUMA_PASSWORD)
    NTFY_TOPIC=$(get_ntfy_env_value NTFY_BESZEL_TOPIC)

    if [ -z "$NTFY_UPTIME_KUMA_PASSWORD" ]; then
        log "NTFY_UPTIME_KUMA_PASSWORD not in ntfy.env; running ntfy-pre-start.sh to update..."
        sh "$SCRIPT_DIR/ntfy-pre-start.sh"
        NTFY_UPTIME_KUMA_PASSWORD=$(get_ntfy_env_value NTFY_UPTIME_KUMA_PASSWORD)
        if [ -z "$NTFY_UPTIME_KUMA_PASSWORD" ]; then
            log "ERROR: NTFY_UPTIME_KUMA_PASSWORD still missing after ntfy-pre-start.sh"
            exit 1
        fi
    fi

    [ -n "$NTFY_TOPIC" ] || NTFY_TOPIC="$DEFAULT_NTFY_TOPIC"

    wait_for_container
    wait_for_healthy
    configure_uptime_kuma "$NTFY_UPTIME_KUMA_PASSWORD" "$NTFY_TOPIC"

    log "Bootstrap completed successfully"
}

main "$@"
