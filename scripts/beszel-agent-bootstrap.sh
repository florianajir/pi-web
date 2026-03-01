#!/bin/sh
# Auto-initialization script for Beszel Hub + beszel-agent token bootstrap.
# Ensures a permanent universal token exists, persists it to
# config/beszel-agent/agent.env, then
# (re)starts beszel-agent so first boot works out-of-the-box.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="$PROJECT_DIR/.env"
AGENT_ENV_DIR="$PROJECT_DIR/config/beszel-agent"
AGENT_ENV_FILE="$AGENT_ENV_DIR/agent.env"
MAX_RETRIES=90
RETRY_INTERVAL=2
HUB_URL_DOCKER="http://pi-beszel:8090"
CURL_IMAGE="curlimages/curl:8.12.1"
CONFIG_UPDATED=0

log() {
    echo "[beszel-bootstrap] $(date '+%H:%M:%S') $*" >&2
}

get_env_value() {
    # Read last matching KEY=value from .env
    # shellcheck disable=SC2002
    cat "$ENV_FILE" 2>/dev/null | grep "^$1=" | tail -n1 | cut -d'=' -f2-
}

get_agent_env_value() {
    # Read last matching KEY=value from agent env file
    cat "$AGENT_ENV_FILE" 2>/dev/null | grep "^$1=" | tail -n1 | cut -d'=' -f2-
}

ensure_agent_env_file() {
    mkdir -p "$AGENT_ENV_DIR"

    if [ ! -f "$AGENT_ENV_FILE" ]; then
        {
            printf '# Managed by scripts/beszel-agent-bootstrap.sh\n'
            printf 'TOKEN=\n'
            printf 'KEY=\n'
        } > "$AGENT_ENV_FILE"
        chmod 600 "$AGENT_ENV_FILE" 2>/dev/null || true
        log "Created $AGENT_ENV_FILE"
    fi
}

wait_for_beszel_container() {
    log "Waiting for Beszel container to appear..."
    for i in $(seq 1 $MAX_RETRIES); do
        if docker ps --format '{{.Names}}' | grep -q '^pi-beszel$'; then
            log "Beszel container is running"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done
    log "ERROR: Beszel container did not start in time"
    return 1
}

wait_for_beszel_health() {
    log "Waiting for Beszel health status..."
    for i in $(seq 1 $MAX_RETRIES); do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' pi-beszel 2>/dev/null || true)
        if [ "$status" = "healthy" ]; then
            log "Beszel container is healthy"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done
    log "ERROR: Beszel container did not become healthy in time"
    return 1
}

extract_json_field() {
    # Best-effort extraction for simple JSON string fields.
    # Usage: extract_json_field "$json" token
    printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

extract_json_bool() {
    # Usage: extract_json_bool "$json" active  -> true/false/empty
    printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p"
}

escape_json() {
    # Escape backslashes and double quotes for JSON strings.
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

login_and_get_auth_token() {
    local email_escaped pass_escaped payload response token
    email_escaped=$(escape_json "$EMAIL")
    pass_escaped=$(escape_json "$PASSWORD")
    payload=$(printf '{"identity":"%s","password":"%s"}' "$email_escaped" "$pass_escaped")

    response=$(docker run --rm --network frontend \
        "$CURL_IMAGE" \
        -fsS \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$HUB_URL_DOCKER/api/collections/users/auth-with-password")

    token=$(extract_json_field "$response" token)
    if [ -z "$token" ]; then
        log "ERROR: Failed to authenticate to Beszel (no token returned)"
        return 1
    fi
    printf '%s' "$token"
}

get_or_create_permanent_universal_token() {
    local auth_token current_json token active permanent created_json
    auth_token="$1"

    current_json=$(docker run --rm --network frontend \
        "$CURL_IMAGE" \
        -fsS \
        -G \
        -H "Authorization: $auth_token" \
        "$HUB_URL_DOCKER/api/beszel/universal-token")

    token=$(extract_json_field "$current_json" token)
    active=$(extract_json_bool "$current_json" active)
    permanent=$(extract_json_bool "$current_json" permanent)

    if [ -n "$token" ] && [ "$active" = "true" ] && [ "$permanent" = "true" ]; then
        printf '%s' "$token"
        return 0
    fi

    created_json=$(docker run --rm --network frontend \
        "$CURL_IMAGE" \
        -fsS \
        -G \
        -H "Authorization: $auth_token" \
        --data-urlencode "enable=1" \
        --data-urlencode "permanent=1" \
        --data-urlencode "token=$token" \
        "$HUB_URL_DOCKER/api/beszel/universal-token")

    token=$(extract_json_field "$created_json" token)
    active=$(extract_json_bool "$created_json" active)
    permanent=$(extract_json_bool "$created_json" permanent)

    if [ -z "$token" ] || [ "$active" != "true" ] || [ "$permanent" != "true" ]; then
        log "ERROR: Failed to create permanent universal token"
        return 1
    fi

    printf '%s' "$token"
}

persist_agent_config() {
    local token="$1"
    local current_token=""
    local current_key=""
    local legacy_key=""
    local updated=0

    if [ ! -f "$AGENT_ENV_FILE" ]; then
        log "ERROR: agent env file not found at $AGENT_ENV_FILE"
        return 1
    fi

    current_token=$(get_agent_env_value TOKEN)

    if [ "$current_token" != "$token" ]; then
        if grep -q '^TOKEN=' "$AGENT_ENV_FILE"; then
            sed -i "s|^TOKEN=.*|TOKEN=$token|" "$AGENT_ENV_FILE"
        else
            printf '\nTOKEN=%s\n' "$token" >> "$AGENT_ENV_FILE"
        fi
        updated=1
        log "Updated TOKEN in $AGENT_ENV_FILE"
    else
        log "TOKEN already up to date in $AGENT_ENV_FILE"
    fi

    # One-time migration for legacy BESZEL_AGENT_KEY in root .env
    current_key=$(get_agent_env_value KEY)
    legacy_key=$(get_env_value BESZEL_AGENT_KEY)
    if [ -z "$current_key" ] && [ -n "$legacy_key" ]; then
        if grep -q '^KEY=' "$AGENT_ENV_FILE"; then
            sed -i "s|^KEY=.*|KEY=$legacy_key|" "$AGENT_ENV_FILE"
        else
            printf 'KEY=%s\n' "$legacy_key" >> "$AGENT_ENV_FILE"
        fi
        updated=1
        log "Migrated legacy BESZEL_AGENT_KEY from .env into $AGENT_ENV_FILE"
    fi

    CONFIG_UPDATED=$updated
}

agent_is_running() {
    docker ps --format '{{.Names}}' | grep -q '^beszel-agent$'
}

restart_agent_if_needed() {
    if [ "$CONFIG_UPDATED" = "0" ] && agent_is_running; then
        log "Agent config unchanged and beszel-agent already running, skipping restart"
        return 0
    fi

    log "Applying beszel-agent configuration..."
    (
        cd "$PROJECT_DIR"
        docker compose up -d beszel-agent >/dev/null
    )
    log "beszel-agent is up"
}

main() {
    log "=== Beszel Agent Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        log "ERROR: .env missing at $ENV_FILE"
        exit 1
    fi

    ensure_agent_env_file

    EMAIL=$(get_env_value EMAIL)
    PASSWORD=$(get_env_value PASSWORD)

    if [ -z "$EMAIL" ] || [ -z "$PASSWORD" ]; then
        log "ERROR: EMAIL and PASSWORD must be set in .env"
        exit 1
    fi

    wait_for_beszel_container
    wait_for_beszel_health

    AUTH_TOKEN=$(login_and_get_auth_token)
    UNIVERSAL_TOKEN=$(get_or_create_permanent_universal_token "$AUTH_TOKEN")

    if [ -z "$UNIVERSAL_TOKEN" ]; then
        log "ERROR: Could not obtain universal token"
        exit 1
    fi

    persist_agent_config "$UNIVERSAL_TOKEN"
    restart_agent_if_needed

    log "Bootstrap completed successfully"
}

main "$@"
