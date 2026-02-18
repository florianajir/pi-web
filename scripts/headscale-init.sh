#!/bin/sh
# Auto-initialization script for Headscale + Tailscale
# Runs automatically on first start, creates user and performs one-time Tailscale bootstrap

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}" 
ENV_FILE="$PROJECT_DIR/.env"
MAX_RETRIES=60
RETRY_INTERVAL=2
HEADSCALE_BIN="/ko-app/headscale"

log() {
    echo "[headscale-init] $(date '+%H:%M:%S') $*" >&2
}

check_headscale_ready() {
    docker exec pi-headscale "$HEADSCALE_BIN" users list >/dev/null 2>&1
}

wait_for_headscale_container() {
    log "Waiting for Headscale container to appear..."
    for i in $(seq 1 $MAX_RETRIES); do
        if docker ps --format '{{.Names}}' | grep -q '^pi-headscale$'; then
            log "Headscale container is running"
            return 0
        fi
        sleep $RETRY_INTERVAL
    done
    log "ERROR: Headscale container did not start in time"
    return 1
}

wait_for_headscale() {
    log "Waiting for Headscale to be ready..."
    for i in $(seq 1 $MAX_RETRIES); do
        if check_headscale_ready; then
            log "Headscale is ready"
            return 0
        fi
        sleep $RETRY_INTERVAL
    done
    log "ERROR: Headscale did not become ready in time"
    return 1
}

wait_for_tailscale_container() {
    log "Waiting for Tailscale container to appear..."
    for i in $(seq 1 $MAX_RETRIES); do
        if docker ps --format '{{.Names}}' | grep -q '^pi-tailscale$'; then
            log "Tailscale container is running"
            return 0
        fi
        sleep $RETRY_INTERVAL
    done
    log "ERROR: Tailscale container did not start in time"
    return 1
}

user_exists() {
    docker exec pi-headscale "$HEADSCALE_BIN" users list --output json 2>/dev/null | \
        grep -q "\"name\": \"${HEADSCALE_USER}\""
}

get_user_id() {
    # Extract the id field from JSON for the configured user
    docker exec pi-headscale "$HEADSCALE_BIN" users list --output json 2>/dev/null | \
        grep -B 1 "\"name\": \"${HEADSCALE_USER}\"" | grep '"id"' | grep -o '[0-9]\+' | head -1
}

create_user() {
    if user_exists; then
        log "User '${HEADSCALE_USER}' already exists"
    else
        log "Creating user '${HEADSCALE_USER}'..."
        docker exec pi-headscale "$HEADSCALE_BIN" users create "$HEADSCALE_USER"
        log "User created"
    fi
}

create_preauthkey() {
    local user_id="$1"

    # One-time, short-lived key for bootstrap only; long-term identity lives in tailscale_state.
    log "Creating one-time preauthkey (expires in 30m) with tag:router..."
    docker exec pi-headscale "$HEADSCALE_BIN" preauthkeys create --user "$user_id" --expiration 30m --tags tag:router --output json 2>/dev/null | \
        grep -o '"key": *"[^"]*"' | sed 's/"key": *"\([^"]*\)"/\1/'
}

connect_tailscale_if_needed() {
    local user_id="$1"
    local key=""

    # Check if tailscale is already connected
    if docker exec pi-tailscale tailscale status --peers=false >/dev/null 2>&1; then
        log "Tailscale already connected"
        return 0
    fi

    key=$(create_preauthkey "$user_id")

    if [ -z "$key" ]; then
        log "ERROR: Failed to create one-time preauthkey"
        return 1
    fi

    log "Bootstrapping Tailscale with one-time auth key..."
    docker exec pi-tailscale tailscale up \
        --login-server="https://headscale.${HOST_NAME}" \
        --auth-key="$key" \
        --accept-dns=true \
        --advertise-exit-node \
        --advertise-routes=192.168.1.0/24 \
        --accept-routes \
        --hostname="tailscale.${HOST_NAME}"

    if docker exec pi-tailscale tailscale status --peers=false >/dev/null 2>&1; then
        log "Tailscale bootstrap successful"
        return 0
    fi

    log "ERROR: Tailscale bootstrap failed"
    return 1
}

main() {
    log "=== Headscale Auto-Init ==="
    
    # Load HOST_NAME/EMAIL from .env
    if [ -f "$ENV_FILE" ]; then
        HOST_NAME=$(grep "^HOST_NAME=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "pi.lan")
        EMAIL=$(grep "^EMAIL=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "")
    fi
    HOST_NAME="${HOST_NAME:-pi.lan}"
    HEADSCALE_USER="${EMAIL:-admin}"

    # Wait for Headscale container to start (first boot can be slow)
    if ! wait_for_headscale_container; then
        log "Headscale container did not become ready"
        exit 1
    fi
    
    # Wait for Headscale to be healthy
    if ! wait_for_headscale; then
        log "Failed to connect to Headscale"
        exit 1
    fi
    
    # Create user if needed
    create_user
    
    # Get user ID
    USER_ID=$(get_user_id)
    if [ -z "$USER_ID" ]; then
        log "ERROR: Failed to get user ID"
        exit 1
    fi
    log "Using user ID: $USER_ID"

    # Wait for Tailscale container to start (first boot can be slow)
    if ! wait_for_tailscale_container; then
        log "Tailscale container did not become ready"
        exit 1
    fi

    # Bootstrap Tailscale if not connected (key is never persisted)
    connect_tailscale_if_needed "$USER_ID"
    
    log "=== Init Complete ==="
    log ""
    log "To connect external clients:"
    log "  sudo tailscale up --login-server=https://headscale.${HOST_NAME} --auth-key=<one-time-key> --accept-dns=true --accept-routes"
}

main "$@"
