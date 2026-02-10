#!/bin/bash
# Auto-initialization script for Headscale + Tailscale
# Runs automatically on first start, creates user and preauthkey

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
MAX_RETRIES=60
RETRY_INTERVAL=2

log() {
    echo "[headscale-init] $(date '+%H:%M:%S') $*" >&2
}

check_headscale_ready() {
    docker exec pi-headscale headscale users list >/dev/null 2>&1
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

user_exists() {
    docker exec pi-headscale headscale users list 2>/dev/null | grep -q "default"
}

get_user_id() {
    # Extract the id field from JSON for user "default"
    docker exec pi-headscale headscale users list --output json 2>/dev/null | \
        grep -B 1 '"name": "default"' | grep '"id"' | grep -o '[0-9]\+' | head -1
}

create_user() {
    if user_exists; then
        log "User 'default' already exists"
    else
        log "Creating user 'default'..."
        docker exec pi-headscale headscale users create default
        log "User created"
    fi
}

get_valid_preauthkey() {
    local user_id="$1"
    # Check if there's already a valid reusable preauthkey using JSON output
    docker exec pi-headscale headscale preauthkeys list --user "$user_id" --output json 2>/dev/null | \
        grep -o '"key": *"[^"]*"' | head -1 | sed 's/"key": *"\([^"]*\)"/\1/'
}

current_key_is_valid() {
    local user_id="$1"
    local key="$2"

    if [ -z "$key" ]; then
        return 1
    fi

    docker exec pi-headscale headscale preauthkeys list --user "$user_id" --output json 2>/dev/null | \
        grep -q "\"key\": *\"${key}\""
}

create_preauthkey() {
    local user_id="$1"
    local existing_key
    existing_key=$(get_valid_preauthkey "$user_id")
    
    if [ -n "$existing_key" ]; then
        log "Valid preauthkey already exists"
        echo "$existing_key"
        return 0
    fi
    
    log "Creating new preauthkey (expires in 1 year)..."
    docker exec pi-headscale headscale preauthkeys create --user "$user_id" --reusable --expiration 8760h --output json 2>/dev/null | \
        grep -o '"key": *"[^"]*"' | sed 's/"key": *"\([^"]*\)"/\1/'
}

update_env_if_needed() {
    local key="$1"
    
    if [ -z "$key" ]; then
        log "ERROR: No preauthkey provided"
        return 1
    fi
    
    # Check current value in .env
    local current_key=""
    if [ -f "$ENV_FILE" ]; then
        current_key=$(grep "^TS_AUTHKEY=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "")
    fi
    
    if [ "$current_key" = "$key" ]; then
        log "TS_AUTHKEY already set correctly"
        return 0
    fi
    
    log "Updating TS_AUTHKEY in .env..."
    if [ -f "$ENV_FILE" ]; then
        if grep -q "^TS_AUTHKEY=" "$ENV_FILE"; then
            sed -i "s|^TS_AUTHKEY=.*|TS_AUTHKEY=${key}|" "$ENV_FILE"
        else
            echo "TS_AUTHKEY=${key}" >> "$ENV_FILE"
        fi
    fi
    
    log "TS_AUTHKEY updated"
    return 0
}

restart_tailscale_if_needed() {
    local key="$1"
    
    # Check if tailscale is already connected
    if docker exec pi-tailscale tailscale status --peers=false >/dev/null 2>&1; then
        log "Tailscale already connected"
        return 0
    fi
    
    log "Restarting Tailscale with new authkey..."
    
    # Update the container's environment and restart
    docker stop pi-tailscale 2>/dev/null || true
    sleep 2
    
    # The container will pick up the new TS_AUTHKEY from .env on restart
    cd "$PROJECT_DIR"
    docker compose up -d tailscale
    
    log "Tailscale restarted"
}

main() {
    log "=== Headscale Auto-Init ==="
    
    # Load HOST_NAME from .env
    if [ -f "$ENV_FILE" ]; then
        HOST_NAME=$(grep "^HOST_NAME=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "pi.lan")
    fi
    HOST_NAME="${HOST_NAME:-pi.lan}"
    
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
    
    # Decide which auth key to use (refresh if reset invalidated current key)
    CURRENT_KEY=""
    if [ -f "$ENV_FILE" ]; then
        CURRENT_KEY=$(grep "^TS_AUTHKEY=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "")
    fi

    if current_key_is_valid "$USER_ID" "$CURRENT_KEY"; then
        log "Existing TS_AUTHKEY is still valid"
        PREAUTHKEY="$CURRENT_KEY"
    else
        # Get or create preauthkey
        PREAUTHKEY=$(create_preauthkey "$USER_ID")
    fi
    
    if [ -z "$PREAUTHKEY" ]; then
        log "ERROR: Failed to get/create preauthkey"
        exit 1
    fi
    
    log "Preauthkey: $PREAUTHKEY"
    
    # Update .env file
    update_env_if_needed "$PREAUTHKEY"
    
    # Restart Tailscale if not connected
    restart_tailscale_if_needed "$PREAUTHKEY"
    
    log "=== Init Complete ==="
    log ""
    log "To connect external clients (with self-signed cert):"
    log "  sudo TS_INSECURE_SKIP_VERIFY=1 tailscale up --login-server=https://headscale.${HOST_NAME} --authkey=$PREAUTHKEY"
    log ""
    log "Note: TS_INSECURE_SKIP_VERIFY=1 bypasses TLS certificate validation for LAN-only setups"
}

main "$@"
