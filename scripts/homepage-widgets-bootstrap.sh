#!/bin/sh
# Bootstrap Homepage service widgets: extracts/creates the API keys that
# gethomepage.dev's built-in widgets need, and writes them as single-line
# secret files under config/homepage/secrets/. That directory is already
# visible inside the homepage container at /app/config/secrets (it's a
# subpath of the existing ./config/homepage:/app/config mount), and is
# referenced from compose.yaml via HOMEPAGE_FILE_* env vars, which Homepage
# substitutes as {{HOMEPAGE_FILE_x}} in widget labels.
#
# Runs last in the ExecStartPost chain (after Prowlarr/Headscale are already
# bootstrapped by their own scripts). Idempotent: only (re)writes a secret
# file if the value changed, and only restarts homepage if something did.

set -eu

. "$(dirname "$0")/lib.sh"

SECRETS_DIR="$PROJECT_DIR/config/homepage/secrets"
CHANGED=0

# Write $2 to file $1 if different from its current content. Sets CHANGED=1 on write.
write_secret() {
    file="$1"
    value="$2"
    current=""

    [ -n "$value" ] || return 1

    if [ -f "$file" ]; then
        current="$(tr -d '\r\n' < "$file")"
    fi

    if [ "$current" = "$value" ]; then
        return 0
    fi

    printf '%s' "$value" > "$file"
    safe_chmod 600 "$file"
    CHANGED=1
}

# --- Prowlarr: read the API key already generated in its config.xml ---
sync_prowlarr_key() {
    if ! container_is_running "pi-prowlarr"; then
        log "WARNING: pi-prowlarr not running; skipping Prowlarr widget key"
        return 0
    fi

    key=$(docker exec pi-prowlarr sh -c "grep -oE '<ApiKey>[^<]+</ApiKey>' /config/config.xml" 2>/dev/null \
        | sed -e 's|<ApiKey>||' -e 's|</ApiKey>||' | tr -d '\r\n')

    if [ -z "$key" ]; then
        log "WARNING: Could not read Prowlarr API key from config.xml"
        return 1
    fi

    write_secret "$SECRETS_DIR/prowlarr_api_key" "$key"
    log "Prowlarr API key ready for Homepage widget"
}

# --- Headscale: dedicated API key (can't be re-read once created, so only
# make one the first time) + the tailscale client's node ID (can change if
# the node re-registers, so refresh it every run). ---
sync_headscale() {
    if ! container_is_running "pi-headscale"; then
        log "WARNING: pi-headscale not running; skipping Headscale widget key"
        return 0
    fi

    key_file="$SECRETS_DIR/headscale_api_key"
    key=""
    [ -f "$key_file" ] && key="$(tr -d '\r\n' < "$key_file")"

    if [ -z "$key" ]; then
        log "Creating dedicated Headscale API key for the Homepage widget (expires in 1 year)..."
        key="$(create_headscale_api_key)"
        if [ -z "$key" ]; then
            log "WARNING: Failed to create Headscale API key for Homepage widget"
        else
            write_secret "$key_file" "$key"
            log "Headscale API key ready for Homepage widget"
        fi
    fi

    node_id=$(docker exec pi-headscale headscale nodes list --output json 2>/dev/null \
        | jq -r '.[] | select(.name=="tailscale") | .id' | head -1)
    if [ -n "$node_id" ]; then
        write_secret "$SECRETS_DIR/headscale_node_id" "$node_id"
        log "Headscale node ID ($node_id) ready for Homepage widget"
    else
        log "WARNING: Could not find Headscale node 'tailscale' to read its node ID"
    fi
}

main() {
    log "=== Homepage Widgets Bootstrap ==="
    mkdir -p "$SECRETS_DIR"

    wait_for_container "pi-homepage" 60 2 || log "WARNING: pi-homepage did not appear in time"

    sync_prowlarr_key || true
    sync_headscale || true

    fix_ownership "$SECRETS_DIR"

    if [ "$CHANGED" -eq 1 ] && container_is_running "pi-homepage"; then
        log "Secret(s) changed; restarting Homepage to pick them up..."
        docker restart pi-homepage >/dev/null 2>&1 || log "WARNING: Failed to restart Homepage"
    fi

    log "Homepage widgets bootstrap completed"
}

main "$@"
