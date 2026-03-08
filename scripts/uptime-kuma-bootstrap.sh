#!/bin/sh
# Auto-initialization script for Uptime Kuma.
# Waits for the container to be healthy, then:
#   1. Creates the admin account on first run (via /api/need-setup + /api/setup)
#   2. Configures ntfy notification using the uptime-kuma-api Python library
# Idempotent: skips setup/notification if already configured.

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

configure_ntfy_notification() {
    local username="$1"
    local password="$2"
    local ntfy_password="$3"
    local ntfy_topic="$4"
    local py_script

    log "Configuring ntfy notification via uptime-kuma-api..."

    py_script=$(mktemp /tmp/uptime-kuma-bootstrap-XXXXXX.py)
    trap 'rm -f "$py_script"' EXIT INT TERM

    cat > "$py_script" << 'PYEOF'
import sys
import os

url = os.environ["UPTIME_KUMA_URL"]
username = os.environ["ADMIN_USERNAME"]
password = os.environ["ADMIN_PASSWORD"]
ntfy_password = os.environ["NTFY_UPTIME_KUMA_PASSWORD"]
ntfy_topic = os.environ["NTFY_TOPIC"]

try:
    from uptime_kuma_api import UptimeKumaApi, NotificationType
except ImportError as e:
    print(f"Import error: {e}", file=sys.stderr)
    sys.exit(1)

api = UptimeKumaApi(url, wait_events=1)

try:
    api.login(username, password)
    print("Logged in to uptime-kuma")
except Exception as e:
    print(f"Login failed: {e}", file=sys.stderr)
    api.disconnect()
    sys.exit(1)

# Check if ntfy notification already configured
try:
    notifications = api.get_notifications()
    existing = [n for n in notifications if n.get("type") == "ntfy"]
    if existing:
        print(f"ntfy notification already configured (id={existing[0]['id']}), skipping")
        api.disconnect()
        sys.exit(0)
except Exception as e:
    print(f"Warning: could not list notifications: {e}", file=sys.stderr)

# Add ntfy notification
try:
    result = api.add_notification(
        type=NotificationType.NTFY,
        name="ntfy",
        isDefault=True,
        applyExisting=True,
        ntfyserverurl="http://ntfy",
        ntfytopic=ntfy_topic,
        ntfyAuthenticationMethod=1,
        ntfyusername="uptime-kuma",
        ntfypassword=ntfy_password,
        ntfyPriority=3,
    )
    print(f"ntfy notification added: id={result.get('id')}")
except Exception as e:
    print(f"Error adding ntfy notification: {e}", file=sys.stderr)
    api.disconnect()
    sys.exit(1)

api.disconnect()
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
        sh -c 'pip install "uptime-kuma-api==1.2.1" -q 2>/dev/null && python3 /bootstrap.py'

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
    configure_ntfy_notification "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "$NTFY_UPTIME_KUMA_PASSWORD" "$NTFY_TOPIC"

    log "Bootstrap completed successfully"
}

main "$@"
