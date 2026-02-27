#!/bin/sh
# Auto-initialization script for Headscale + Tailscale + Headplane
# Runs automatically on first start, creates user and performs one-time Tailscale bootstrap with a short-lived preauthkey, then initializes Headplane config with a long-lived reusable preauthkey.

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
        grep "\"name\": \"${HEADSCALE_USER}\"" -B 1 | grep '"id"' | sed 's/[^0-9]*\([0-9]\+\).*/\1/' | head -1
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

init_headplane_config() {
    local user_id="$1"
    local config_dir="$PROJECT_DIR/config/headplane"
    local template="$config_dir/config.yaml.template"
    local config="$config_dir/config.yaml"

    if [ -f "$config" ] && [ -s "$config" ]; then
        log "Headplane config already exists, skipping"
        return 0
    fi

    log "Initializing Headplane config from template..."

    # Generate 32-char cookie secret (16 bytes = 32 hex chars)
    COOKIE_SECRET=$(openssl rand -hex 16)

    HEADSCALE_URL="https://headscale.${HOST_NAME}"

    # Create a reusable, long-lived preauthkey for the Headplane agent
    log "Creating preauthkey for Headplane agent (reusable, expires in 1 year)..."
    HEADPLANE_AUTHKEY=$(docker exec pi-headscale "$HEADSCALE_BIN" preauthkeys create \
        --user "$user_id" \
        --reusable \
        --expiration 8760h \
        --output json 2>/dev/null | \
        grep -o '"key": *"[^"]*"' | sed 's/"key": *"\([^"]*\)"/\1/')

    if [ -z "$HEADPLANE_AUTHKEY" ]; then
        log "ERROR: Failed to create Headplane agent preauthkey"
        return 1
    fi

    sed \
        -e "s|__COOKIE_SECRET__|${COOKIE_SECRET}|g" \
        -e "s|__HEADSCALE_URL__|${HEADSCALE_URL}|g" \
        -e "s|__HEADPLANE_AGENT__PRE_AUTHKEY__|${HEADPLANE_AUTHKEY}|g" \
        "$template" > "$config"

    log "Headplane config written to $config"

    log "Restarting Headplane container to apply new config..."
    docker restart pi-headplane
    log "Headplane restarted"
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
        HOST_NAME=$(grep "^HOST_NAME=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '\r' | tail -n1)
        EMAIL=$(grep "^EMAIL=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '\r' | tail -n1)
    fi
    HOST_NAME="${HOST_NAME:-pi.lan}"
    HEADSCALE_USER="${EMAIL:-admin}"
    if [ -z "$HEADSCALE_USER" ]; then
        log "ERROR: HEADSCALE_USER (EMAIL) is not set."
        exit 1
    fi

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

    # Initialize Headplane config if not already done
    init_headplane_config "$USER_ID"

    # Wait for Tailscale container to start (first boot can be slow)
    if ! wait_for_tailscale_container; then
        log "Tailscale container did not become ready"
        exit 1
    fi

    # Bootstrap Tailscale if not connected (key is never persisted)
    connect_tailscale_if_needed "$USER_ID"
}

main "$@"
