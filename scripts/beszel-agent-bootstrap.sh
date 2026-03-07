#!/bin/sh
# Auto-initialization script for Beszel Hub + beszel-agent token bootstrap.
# Ensures a permanent universal token exists, persists it to
# config/beszel-agent/agent.env, then
# (re)starts beszel-agent so first boot works out-of-the-box.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="$PROJECT_DIR/.env"
NTFY_ENV_FILE="$PROJECT_DIR/config/ntfy/ntfy.env"
AGENT_ENV_DIR="$PROJECT_DIR/config/beszel-agent"
AGENT_ENV_FILE="$AGENT_ENV_DIR/agent.env"
MAX_RETRIES=90
RETRY_INTERVAL=2
HUB_URL_DOCKER="http://pi-beszel:8090"
CURL_IMAGE="curlimages/curl:8.12.1"
DEFAULT_BESZEL_NTFY_TOPIC="pi"
DEFAULT_BESZEL_TEMP_ALERT_VALUE="70"
DEFAULT_BESZEL_TEMP_ALERT_MIN="5"
DEFAULT_BESZEL_NTFY_SCHEME="http"
CONFIG_UPDATED=0

log() {
    echo "[beszel-bootstrap] $(date '+%H:%M:%S') $*" >&2
}

read_env_value_from_file() {
    # Read the last matching KEY=value from a dotenv-style file.
    local file="$1"
    local key="$2"

    if [ ! -f "$file" ]; then
        return 0
    fi

    grep "^$key=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

get_env_value() {
    read_env_value_from_file "$ENV_FILE" "$1"
}

get_agent_env_value() {
    read_env_value_from_file "$AGENT_ENV_FILE" "$1"
}

get_ntfy_env_value() {
    read_env_value_from_file "$NTFY_ENV_FILE" "$1"
}

upsert_env_value() {
    # Upsert KEY=value in file safely (values may contain '&', '|', etc.).
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp_file

    tmp_file=$(mktemp)
    awk -v k="$key" -v v="$value" '
        BEGIN { done = 0 }
        $0 ~ ("^" k "=") {
            if (!done) {
                print k "=" v
                done = 1
            }
            next
        }
        { print }
        END {
            if (!done) {
                print k "=" v
            }
        }
    ' "$file" > "$tmp_file"

    mv "$tmp_file" "$file"
}

set_agent_env_value() {
    upsert_env_value "$AGENT_ENV_FILE" "$1" "$2"
    chmod 600 "$AGENT_ENV_FILE" 2>/dev/null || true
}

resolve_key_from_env() {
    # Support multiple env names for compatibility.
    # Priority: explicit key vars.
    local value

    value=$(get_env_value BESZEL_AGENT_KEY)
    if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
    fi

    value=$(get_env_value BESZEL_KEY)
    if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
    fi

    value=$(get_env_value KEY)
    if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
    fi
}

docker_curl() {
    docker run --rm --network frontend "$CURL_IMAGE" -fsS "$@"
}

beszel_api_get() {
    local auth_token="$1"
    local path="$2"
    shift 2

    docker_curl -G -H "Authorization: $auth_token" "$@" "$HUB_URL_DOCKER$path"
}

beszel_api_post_json() {
    local auth_token="$1"
    local path="$2"
    local payload="$3"

    docker_curl -X POST \
        -H "Authorization: $auth_token" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$HUB_URL_DOCKER$path"
}

beszel_api_patch_json() {
    local auth_token="$1"
    local path="$2"
    local payload="$3"

    docker_curl -X PATCH \
        -H "Authorization: $auth_token" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$HUB_URL_DOCKER$path"
}

get_hub_public_key() {
    local auth_token response hub_key
    auth_token="$1"

    response=$(docker_curl \
        -H "Authorization: $auth_token" \
        "$HUB_URL_DOCKER/api/beszel/getkey")

    hub_key=$(extract_json_field "$response" key)
    if [ -z "$hub_key" ]; then
        log "ERROR: Failed to retrieve Beszel hub public key"
        return 1
    fi

    printf '%s' "$hub_key"
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
    local status

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

url_encode() {
    _value="$1"

    if ! command -v python3 >/dev/null 2>&1; then
        printf '%s' "$_value"
        return 0
    fi

    python3 - "$_value" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
}

extract_settings_record_id() {
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
s = sys.stdin.read() or "{}"
try:
    data = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)
items = data.get("items") or []
print(items[0].get("id", "") if items else "")'
}

build_user_settings_payload() {
    _webhook_url="$1"

    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
from urllib.parse import urlparse

new_webhook = sys.argv[1]
s = sys.stdin.read() or "{}"
try:
    data = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)
items = data.get("items") or []
if not items:
    print("")
    sys.exit(0)
settings = items[0].get("settings") or {}
webhooks = settings.get("webhooks") or []
target = urlparse(new_webhook)

# remove legacy/duplicate ntfy beszel webhooks targeting the same host/topic
normalized = []
for webhook in webhooks:
    parsed = urlparse(webhook)
    is_same_beszel_ntfy_target = (
        parsed.scheme == "ntfy"
        and (parsed.hostname or "") == (target.hostname or "")
        and (parsed.username or "") == "beszel"
        and (parsed.path or "") == (target.path or "")
    )
    if not is_same_beszel_ntfy_target:
        normalized.append(webhook)

webhooks = normalized
if new_webhook not in webhooks:
    webhooks.append(new_webhook)
settings["webhooks"] = webhooks
print(json.dumps({"settings": settings}, separators=(",", ":")))' "$_webhook_url"
}

count_system_records() {
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
s = sys.stdin.read() or "{}"
try:
    data = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)
items = data.get("items") or []
print(len(items))'
}

build_temperature_alert_payload() {
    _value="$1"
    _min="$2"
    _overwrite="$3"

    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
value_arg = sys.argv[1]
min_arg = sys.argv[2]
overwrite_arg = sys.argv[3].strip().lower()
try:
    value = float(value_arg)
except ValueError:
    value = 70.0
try:
    min_minutes = int(float(min_arg))
except ValueError:
    min_minutes = 5
overwrite = overwrite_arg in ("1", "true", "yes", "on")
s = sys.stdin.read() or "{}"
try:
    data = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)
systems = [item.get("id") for item in (data.get("items") or []) if item.get("id")]
payload = {"name": "Temperature", "value": value, "min": min_minutes, "systems": systems, "overwrite": overwrite}
print(json.dumps(payload, separators=(",", ":")))' "$_value" "$_min" "$_overwrite"
}

login_and_get_auth_token() {
    local email_escaped pass_escaped payload response token
    email_escaped=$(escape_json "$EMAIL")
    pass_escaped=$(escape_json "$PASSWORD")
    payload=$(printf '{"identity":"%s","password":"%s"}' "$email_escaped" "$pass_escaped")

    response=$(docker_curl \
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

    current_json=$(beszel_api_get "$auth_token" "/api/beszel/universal-token")

    token=$(extract_json_field "$current_json" token)
    active=$(extract_json_bool "$current_json" active)
    permanent=$(extract_json_bool "$current_json" permanent)

    if [ -n "$token" ] && [ "$active" = "true" ] && [ "$permanent" = "true" ]; then
        printf '%s' "$token"
        return 0
    fi

    created_json=$(beszel_api_get "$auth_token" "/api/beszel/universal-token" \
        --data-urlencode "enable=1" \
        --data-urlencode "permanent=1" \
        --data-urlencode "token=$token" \
    )

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
    local hub_key="$2"
    local current_token=""
    local current_key=""
    local sourced_key=""
    local target_key=""
    local updated=0

    if [ ! -f "$AGENT_ENV_FILE" ]; then
        log "ERROR: agent env file not found at $AGENT_ENV_FILE"
        return 1
    fi

    current_token=$(get_agent_env_value TOKEN)

    if [ "$current_token" != "$token" ]; then
        set_agent_env_value TOKEN "$token"
        updated=1
        log "Updated TOKEN in $AGENT_ENV_FILE"
    else
        log "TOKEN already up to date in $AGENT_ENV_FILE"
    fi

    # Ensure KEY contains Beszel hub public key expected by beszel-agent.
    current_key=$(get_agent_env_value KEY)
    if [ -n "$hub_key" ]; then
        target_key="$hub_key"
    else
        sourced_key=$(resolve_key_from_env)
        target_key="$sourced_key"
    fi

    if [ -z "$target_key" ]; then
        log "ERROR: KEY is required but no hub key (or override key) is available"
        return 1
    fi

    if [ "$current_key" != "$target_key" ]; then
        set_agent_env_value KEY "$target_key"
        updated=1
        log "Updated KEY in $AGENT_ENV_FILE"
    else
        log "KEY already up to date in $AGENT_ENV_FILE"
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

configure_ntfy_webhook_and_temperature_alerts() {
    local auth_token="$1"
    local beszel_password beszel_topic
    local password_encoded topic_encoded webhook_url
    local settings_response settings_record_id settings_payload
    local systems_response systems_count alert_value alert_min alert_overwrite alerts_payload

    if ! command -v python3 >/dev/null 2>&1; then
        log "WARNING: python3 not found; skipping Beszel notifications bootstrap"
        return 0
    fi

    if [ ! -f "$NTFY_ENV_FILE" ]; then
        log "WARNING: $NTFY_ENV_FILE not found; skipping Beszel notifications bootstrap"
        return 0
    fi

    beszel_password=$(get_ntfy_env_value NTFY_BESZEL_PASSWORD)
    beszel_topic=$(get_ntfy_env_value NTFY_BESZEL_TOPIC)

    if [ -z "$beszel_password" ]; then
        log "WARNING: NTFY_BESZEL_PASSWORD missing; skipping Beszel notifications bootstrap"
        return 0
    fi

    [ -n "$beszel_topic" ] || beszel_topic="$DEFAULT_BESZEL_NTFY_TOPIC"

    password_encoded=$(url_encode "$beszel_password")
    topic_encoded=$(url_encode "$beszel_topic")
    webhook_url="ntfy://beszel:${password_encoded}@ntfy/${topic_encoded}?scheme=${DEFAULT_BESZEL_NTFY_SCHEME}"

    log "Ensuring Beszel notification webhook is configured"
    settings_response=$(beszel_api_get "$auth_token" "/api/collections/user_settings/records" \
        --data-urlencode "page=1" \
        --data-urlencode "perPage=1" \
    )

    settings_record_id=$(printf '%s' "$settings_response" | extract_settings_record_id)
    if [ -z "$settings_record_id" ]; then
        log "WARNING: Could not find user_settings record; skipping notifications bootstrap"
        return 0
    fi

    settings_payload=$(printf '%s' "$settings_response" | build_user_settings_payload "$webhook_url")
    if [ -n "$settings_payload" ]; then
        beszel_api_patch_json \
            "$auth_token" \
            "/api/collections/user_settings/records/$settings_record_id" \
            "$settings_payload" >/dev/null
    fi

    log "Ensuring default temperature alerts are configured"
    systems_response=$(beszel_api_get "$auth_token" "/api/collections/systems/records" \
        --data-urlencode "page=1" \
        --data-urlencode "perPage=500" \
        --data-urlencode "fields=id" \
    )

    systems_count=$(printf '%s' "$systems_response" | count_system_records)
    if [ -z "$systems_count" ] || [ "$systems_count" -eq 0 ]; then
        log "No systems found yet; skipping temperature alert bootstrap"
        return 0
    fi

    alert_value=$(get_env_value BESZEL_TEMP_ALERT_VALUE)
    alert_min=$(get_env_value BESZEL_TEMP_ALERT_MIN)
    alert_overwrite=$(get_env_value BESZEL_TEMP_ALERT_OVERWRITE)

    [ -n "$alert_value" ] || alert_value="$DEFAULT_BESZEL_TEMP_ALERT_VALUE"
    [ -n "$alert_min" ] || alert_min="$DEFAULT_BESZEL_TEMP_ALERT_MIN"
    [ -n "$alert_overwrite" ] || alert_overwrite="false"

    alerts_payload=$(printf '%s' "$systems_response" | build_temperature_alert_payload "$alert_value" "$alert_min" "$alert_overwrite")
    beszel_api_post_json "$auth_token" "/api/beszel/user-alerts" "$alerts_payload" >/dev/null
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
    HUB_PUBLIC_KEY=$(get_hub_public_key "$AUTH_TOKEN")

    if [ -z "$UNIVERSAL_TOKEN" ]; then
        log "ERROR: Could not obtain universal token"
        exit 1
    fi

    if [ -z "$HUB_PUBLIC_KEY" ]; then
        log "ERROR: Could not obtain Beszel hub public key"
        exit 1
    fi

    persist_agent_config "$UNIVERSAL_TOKEN" "$HUB_PUBLIC_KEY"
    restart_agent_if_needed
    configure_ntfy_webhook_and_temperature_alerts "$AUTH_TOKEN"

    log "Bootstrap completed successfully"
}

main "$@"
