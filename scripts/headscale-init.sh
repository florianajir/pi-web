#!/bin/sh
# Auto-initialization script for Headscale + Tailscale
# Runs automatically on first start, creates user and preauthkey

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

get_valid_preauthkey() {
    local user_id="$1"
    # Check if there's already a valid reusable preauthkey using JSON output
    docker exec pi-headscale "$HEADSCALE_BIN" preauthkeys list --output json 2>/dev/null | \
        awk -v user="$HEADSCALE_USER" '
            /"name":/ {
                user_match = ($0 ~ "\"name\": \"" user "\"")
            }
            /"key":/ {
                if (user_match) {
                    if (match($0, /"key": "[^"]+"/)) {
                        current_key = substr($0, RSTART + 8, RLENGTH - 9)
                        current_key_len = length(current_key)
                    }
                } else {
                    current_key = ""
                    current_key_len = 0
                }
            }
            /"tag:router"/ {
                if (current_key != "" && current_key_len >= 88) {
                    print current_key
                    exit
                }
            }
        '
}

current_key_is_valid() {
    local user_id="$1"
    local key="$2"

    if [ -z "$key" ]; then
        return 1
    fi

    docker exec pi-headscale "$HEADSCALE_BIN" preauthkeys list --output json 2>/dev/null | \
        awk -v key="$key" '
            /"key":/ {
                if (match($0, /"key": "[^"]+"/)) {
                    current_key = substr($0, RSTART + 8, RLENGTH - 9)
                    key_match = (current_key == key)
                    key_len = length(current_key)
                }
            }
            /"tag:router"/ {
                if (key_match && key_len >= 88) {
                    exit 0
                }
            }
            END { exit 1 }
        '
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
    
    log "Creating new preauthkey (expires in 1 year) with tag:router..."
    docker exec pi-headscale "$HEADSCALE_BIN" preauthkeys create --user "$user_id" --reusable --expiration 8760h --tags tag:router --output json 2>/dev/null | \
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
    local project_name=""
    
    # Check if tailscale is already connected
    if docker exec pi-tailscale tailscale status --peers=false >/dev/null 2>&1; then
        log "Tailscale already connected"
        return 0
    fi
    
    log "Recreating Tailscale to pick up updated TS_AUTHKEY..."

    if [ -f "$PROJECT_DIR/compose.yaml" ]; then
        project_name=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' pi-tailscale 2>/dev/null || true)
        if [ -z "$project_name" ]; then
            project_name="pi-web"
        fi

        docker compose --project-name "$project_name" -f "$PROJECT_DIR/compose.yaml" \
            up -d --no-deps --force-recreate tailscale
    else
        log "ERROR: compose.yaml not found at $PROJECT_DIR/compose.yaml"
        return 1
    fi

    log "Tailscale recreated"
}

main() {
    log "=== Headscale Auto-Init ==="
    
    # Load HOST_NAME/EMAIL from .env
    if [ -f "$ENV_FILE" ]; then
        HOST_NAME=$(grep "^HOST_NAME=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "pi.lan")
        EMAIL=$(grep "^EMAIL=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "")
    fi
    HOST_NAME="${HOST_NAME:-pi.lan}"
    HEADSCALE_USER="$EMAIL"

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
    log "  sudo tailscale up --login-server=https://headscale.${HOST_NAME} --auth-key=$PREAUTHKEY --accept-dns=true --accept-routes"
}

main "$@"
