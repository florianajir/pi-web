#!/bin/sh
# Auto-initialization script for Uptime Kuma.
# Waits for the container to be healthy, then:
#   1. Creates the admin account on first run (via /api/need-setup + /api/setup)
#   2. Configures ntfy notification, Docker host, and container monitors via Socket.IO
# Idempotent: each step is skipped if already configured.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="$PROJECT_DIR/.env"
NTFY_ENV_FILE="$PROJECT_DIR/config/ntfy/ntfy.env"
UPTIME_KUMA_URL_DOCKER="http://pi-uptime-kuma:3001"
PYTHON_IMAGE="python:3.12-alpine"
CURL_IMAGE="curlimages/curl:8.12.1"
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

docker_curl() {
    docker run --rm --network frontend "$CURL_IMAGE" -fsS "$@"
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

setup_admin_if_needed() {
    local username="$1"
    local password="$2"
    local response need_setup

    response=$(docker_curl "$UPTIME_KUMA_URL_DOCKER/api/need-setup" 2>/dev/null || true)
    need_setup=$(printf '%s' "$response" | tr -d '\n' | sed -n 's/.*"needSetup"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')

    if [ "$need_setup" = "true" ]; then
        log "First run detected — creating admin account..."
        docker_curl \
            -X POST \
            -H 'Content-Type: application/json' \
            -d "{\"username\":\"$(printf '%s' "$username" | sed 's/\\/\\\\/g; s/"/\\"/g')\",\"password\":\"$(printf '%s' "$password" | sed 's/\\/\\\\/g; s/"/\\"/g')\"}" \
            "$UPTIME_KUMA_URL_DOCKER/api/setup" >/dev/null
        log "Admin account created"
    else
        log "Admin account already exists, skipping setup"
    fi
}

configure_uptime_kuma() {
    local username="$1"
    local password="$2"
    local ntfy_password="$3"
    local ntfy_topic="$4"
    local py_script

    log "Configuring Uptime Kuma via Socket.IO (ntfy + Docker host + monitors)..."

    py_script=$(mktemp /tmp/uptime-kuma-bootstrap-XXXXXX.py)
    trap 'rm -f "$py_script"' EXIT INT TERM

    cat > "$py_script" << 'PYEOF'
import sys, os, threading
import socketio

url           = os.environ["UPTIME_KUMA_URL"]
username      = os.environ["ADMIN_USERNAME"]
password      = os.environ["ADMIN_PASSWORD"]
ntfy_password = os.environ["NTFY_UPTIME_KUMA_PASSWORD"]
ntfy_topic    = os.environ["NTFY_TOPIC"]

DOCKER_SOCKET = "/var/run/docker.sock"
DOCKER_CONTAINERS = [
    "pi-backrest", "pi-beszel", "pi-beszel-agent", "pi-ddns-updater",
    "pi-headplane", "pi-headscale", "pi-homepage", "pi-immich",
    "pi-n8n", "pi-nextcloud", "pi-ntfy", "pi-pihole",
    "pi-portainer", "pi-postgres", "pi-redis", "pi-tailscale",
    "pi-traefik", "pi-unbound", "pi-uptime-kuma", "pi-watchtower",
]

sio = socketio.Client(logger=False, engineio_logger=False)

# State received from server after login
_state      = {"notificationList": None, "dockerHostList": None, "monitorList": None}
_state_lock = threading.Lock()
_all_received = threading.Event()
_login_done   = threading.Event()
_login_ok     = [False]
error         = [None]

def _as_list(data):
    if isinstance(data, dict):
        return list(data.values())
    return data if isinstance(data, list) else []

def _mark(key, value):
    with _state_lock:
        if _state[key] is None:
            _state[key] = value
            if all(v is not None for v in _state.values()):
                _all_received.set()

@sio.on("notificationList")
def on_notification_list(data):
    _mark("notificationList", _as_list(data))

@sio.on("dockerHostList")
def on_docker_host_list(data):
    _mark("dockerHostList", _as_list(data))

@sio.on("monitorList")
def on_monitor_list(data):
    _mark("monitorList", _as_list(data))

def emit_sync(event, data, timeout=30):
    result = [{}]
    ev = threading.Event()
    def cb(*args):
        result[0] = args[0] if args else {}
        ev.set()
    sio.emit(event, data, callback=cb)
    if not ev.wait(timeout=timeout):
        raise TimeoutError(f"No ack for '{event}' within {timeout}s")
    return result[0]

def on_login_cb(data):
    _login_ok[0] = data.get("ok", False)
    if not _login_ok[0]:
        error[0] = f"Login failed: {data.get('msg', 'unknown')}"
        _all_received.set()  # unblock main thread
    else:
        print("Logged in to uptime-kuma")
    _login_done.set()

@sio.event
def connect():
    sio.emit("login", {"username": username, "password": password, "token": ""}, callback=on_login_cb)

@sio.event
def connect_error(e):
    error[0] = f"Connection failed: {e}"
    _login_done.set()
    _all_received.set()

try:
    sio.connect(url, transports=["polling", "websocket"])
except Exception as e:
    print(f"Failed to connect to {url}: {e}", file=sys.stderr)
    sys.exit(1)

if not _login_done.wait(timeout=30):
    print("Timeout waiting for login", file=sys.stderr)
    sio.disconnect(); sys.exit(1)

if error[0]:
    print(f"Error: {error[0]}", file=sys.stderr)
    sio.disconnect(); sys.exit(1)

if not _all_received.wait(timeout=30):
    print("Timeout waiting for server state after login", file=sys.stderr)
    sio.disconnect(); sys.exit(1)

notifications = _state["notificationList"]
docker_hosts  = _state["dockerHostList"]
monitors      = _state["monitorList"]

# ── 1. ntfy notification ────────────────────────────────────────────────────
existing_ntfy = [n for n in notifications if n.get("type") == "ntfy"]
if existing_ntfy:
    print(f"ntfy notification already configured (id={existing_ntfy[0]['id']}), skipping")
else:
    r = emit_sync("addNotification", ({
        "id": None, "name": "ntfy", "type": "ntfy",
        "isDefault": True, "applyExisting": True,
        "ntfyserverurl": "http://ntfy", "ntfytopic": ntfy_topic,
        "ntfyAuthenticationMethod": "usernamePassword",
        "ntfyusername": "uptime-kuma", "ntfypassword": ntfy_password,
        "ntfyPriority": 3,
    }, None))
    if not r.get("ok"):
        print(f"Error adding ntfy notification: {r.get('msg')}", file=sys.stderr)
        sio.disconnect(); sys.exit(1)
    print(f"ntfy notification added: id={r.get('id')}")

# ── 2. Docker host ──────────────────────────────────────────────────────────
local_host = next((h for h in docker_hosts if h.get("dockerDaemon") == DOCKER_SOCKET), None)
if local_host:
    docker_host_id = local_host["id"]
    print(f"Docker host already configured (id={docker_host_id}), skipping")
else:
    r = emit_sync("addDockerHost", (
        {"name": "local", "dockerType": "socket", "dockerDaemon": DOCKER_SOCKET}, None
    ))
    if not r.get("ok"):
        print(f"Warning: failed to add Docker host: {r.get('msg')}", file=sys.stderr)
        docker_host_id = None
    else:
        docker_host_id = r.get("id")
        print(f"Docker host added: id={docker_host_id}")

# ── 3. Container monitors ───────────────────────────────────────────────────
if docker_host_id is not None:
    existing = {m.get("dockerContainer") for m in monitors if m.get("type") == "docker"}
    added = 0
    for container in DOCKER_CONTAINERS:
        if container in existing:
            continue
        r = emit_sync("addMonitor", {
            "type": "docker",
            "name": container.removeprefix("pi-"),
            "dockerContainer": container,
            "dockerDaemon": docker_host_id,
            "interval": 60,
            "retryInterval": 60,
            "resendInterval": 0,
            "maxretries": 1,
            "active": True,
        })
        if r.get("ok"):
            print(f"Monitor added for {container}: id={r.get('monitorID')}")
            added += 1
        else:
            print(f"Warning: failed to add monitor for {container}: {r.get('msg')}", file=sys.stderr)
    print(f"Added {added} new container monitors")

sio.disconnect()
print("Bootstrap complete")
PYEOF

    docker run --rm \
        --network frontend \
        -v "$py_script:/bootstrap.py:ro" \
        -e UPTIME_KUMA_URL="$UPTIME_KUMA_URL_DOCKER" \
        -e ADMIN_USERNAME="$username" \
        -e ADMIN_PASSWORD="$password" \
        -e NTFY_UPTIME_KUMA_PASSWORD="$ntfy_password" \
        -e NTFY_TOPIC="$ntfy_topic" \
        "$PYTHON_IMAGE" \
        sh -c 'pip install "python-socketio[client]" "websocket-client" -q && python3 /bootstrap.py'

    rm -f "$py_script"
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

    ADMIN_USERNAME=$(get_env_value USER)
    ADMIN_PASSWORD=$(get_env_value PASSWORD)
    NTFY_UPTIME_KUMA_PASSWORD=$(get_ntfy_env_value NTFY_UPTIME_KUMA_PASSWORD)
    NTFY_TOPIC=$(get_ntfy_env_value NTFY_BESZEL_TOPIC)

    if [ -z "$ADMIN_USERNAME" ] || [ -z "$ADMIN_PASSWORD" ]; then
        log "ERROR: USER and PASSWORD must be set in .env"
        exit 1
    fi

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
    setup_admin_if_needed "$ADMIN_USERNAME" "$ADMIN_PASSWORD"
    configure_uptime_kuma "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "$NTFY_UPTIME_KUMA_PASSWORD" "$NTFY_TOPIC"

    log "Bootstrap completed successfully"
}

main "$@"
