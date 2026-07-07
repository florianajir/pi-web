#!/bin/sh
# Bootstrap Prowlarr: register qBittorrent as a download client (idempotent).
# Prowlarr shares gluetun's network namespace, so qBittorrent is reachable at
# localhost:8080 and the Prowlarr API at localhost:9696 from inside the container.
# The API key is read straight from config.xml (rendered by prowlarr-pre-start.sh).
# Runs as ExecStartPost after docker compose up. Best-effort (warns, never fails start).

set -e

. "$(dirname "$0")/lib.sh"

PROWLARR_CONTAINER="${PROWLARR_CONTAINER:-pi-prowlarr}"
QB_CLIENT_NAME="qBittorrent"
API="http://localhost:9696/api/v1"
MAX_RETRIES=60
RETRY_INTERVAL=5

px_curl() {
    docker exec "$PROWLARR_CONTAINER" curl -sS "$@"
}

get_api_key() {
    docker exec "$PROWLARR_CONTAINER" sh -c "grep -oE '<ApiKey>[^<]+</ApiKey>' /config/config.xml" 2>/dev/null \
        | sed -e 's|<ApiKey>||' -e 's|</ApiKey>||' | tr -d '\r\n'
}

wait_for_prowlarr() {
    local key="$1"
    log "Waiting for Prowlarr API..."
    for i in $(seq 1 $MAX_RETRIES); do
        if px_curl -f -H "X-Api-Key: $key" "$API/system/status" >/dev/null 2>&1; then
            log "Prowlarr API is ready"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done
    log "WARNING: Prowlarr API did not become ready in time"
    return 1
}

main() {
    container_is_running "$PROWLARR_CONTAINER" || { log "Prowlarr not running, skipping"; return 0; }

    local key user password schema payload existing code
    key="$(get_api_key)"
    [ -n "$key" ] || { log "WARNING: could not read Prowlarr API key from config.xml"; return 0; }

    wait_for_prowlarr "$key" || return 0

    existing="$(px_curl -H "X-Api-Key: $key" "$API/downloadclient" 2>/dev/null)"
    if printf '%s' "$existing" | jq -e --arg n "$QB_CLIENT_NAME" '.[]? | select(.name==$n)' >/dev/null 2>&1; then
        log "qBittorrent download client already present, skipping"
        return 0
    fi

    user="$(get_env_value USER)"
    password="$(get_env_value PASSWORD)"
    [ -n "$user" ] && [ -n "$password" ] || { log "WARNING: USER/PASSWORD not set; skipping download client"; return 0; }

    # Build the create body from the live schema so field names track the Prowlarr version.
    schema="$(px_curl -H "X-Api-Key: $key" "$API/downloadclient/schema" 2>/dev/null)"
    payload="$(printf '%s' "$schema" | jq -c \
        --arg name "$QB_CLIENT_NAME" --arg user "$user" --arg pass "$password" '
        (.[] | select(.implementation == "QBittorrent"))
        | .name = $name
        | .enable = true
        | .fields = ([.fields[]
            | if   .name == "host"     then .value = "localhost"
              elif .name == "port"     then .value = 8080
              elif .name == "username" then .value = $user
              elif .name == "password" then .value = $pass
              elif .name == "useSsl"   then .value = false
              else . end])
    ' 2>/dev/null)"
    [ -n "$payload" ] && [ "$payload" != "null" ] || { log "WARNING: could not build qBittorrent payload from schema"; return 0; }

    code="$(printf '%s' "$payload" | docker exec -i "$PROWLARR_CONTAINER" curl -sS -o /dev/null -w '%{http_code}' \
        -X POST -H "X-Api-Key: $key" -H "Content-Type: application/json" --data @- "$API/downloadclient")"
    case "$code" in
        20*) log "Added qBittorrent download client to Prowlarr" ;;
        *)   log "WARNING: Prowlarr downloadclient POST returned HTTP $code" ;;
    esac
}

main "$@"
