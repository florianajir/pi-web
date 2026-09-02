#!/bin/sh
# Bootstrap Prowlarr (idempotent, best-effort — warns, never fails the start):
#   1. register qBittorrent as a download client
#   2. register FlareSolverr as an indexer proxy (Cloudflare solver) with a tag
# Prowlarr shares gluetun's network namespace, so qBittorrent (localhost:8080),
# FlareSolverr (localhost:8191) and the Prowlarr API (localhost:9696) are all reachable
# from inside the container. The API key is read straight from config.xml
# (rendered by prowlarr-pre-start.sh). A post-start hook, so it runs after compose up.

set -eu

. "$(dirname "$0")/lib.sh"

PROWLARR_CONTAINER="${PROWLARR_CONTAINER:-pi-prowlarr}"
QB_CLIENT_NAME="qBittorrent"
QB_HOST="gluetun"
QB_PORT="8080"
# Per-release category mapping on the download client: Prowlarr resolves the
# qBittorrent category as `GetCategoryForRelease(release) ?? Settings.Category`, and
# matches parent categories too. Anything unmapped falls back to the client default
# and stays out of Kavita's library.
# newznab has no manga category - manga ships as 7030 Books/Comics, the same id as
# comics - so 7030 goes to manga here and comics come from Kapowarr instead, which
# imports into its own root folder and never touches these categories.
# Audiobooks are 3030 Audio/Audiobook, a sibling of the music ids under 3000 rather
# than a Books subcategory; mapped on its own so 3010 MP3 and 3040 Lossless keep
# falling through to the client default. Shelfmark's own grabs bypass this map - it
# adds them to qBittorrent itself, under QBITTORRENT_CATEGORY_AUDIOBOOK.
QB_CATEGORY_MAP='[
  {"clientCategory":"manga","categories":[7030]},
  {"clientCategory":"books","categories":[7010,7020,7040,7050,7060]},
  {"clientCategory":"audiobooks","categories":[3030]}
]'
FLARESOLVERR_NAME="FlareSolverr"
FLARESOLVERR_TAG="flaresolverr"
FLARESOLVERR_HOST="http://flaresolverr:8191/"
NTFY_ENV_FILE="$PROJECT_DIR/config/ntfy/ntfy.env"
NTFY_URL="http://ntfy"
NTFY_TOPIC="downloads"
NTFY_NOTIFICATION_NAME="ntfy"
API="http://localhost:9696/api/v1"
MAX_RETRIES=60
RETRY_INTERVAL=5

px_curl() {
    docker exec "$PROWLARR_CONTAINER" curl -sS "$@"
}

px_post() {
    # px_post <path> ; JSON body on stdin. Echoes the HTTP status code.
    # docker exec needs -i so curl's --data @- actually receives the piped body.
    local path="$1"
    docker exec -i "$PROWLARR_CONTAINER" curl -sS -o /dev/null -w '%{http_code}' \
        -X POST -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
        --data @- "$API/$path"
}

px_put() {
    # px_put <path> ; JSON body on stdin. Echoes the HTTP status code.
    local path="$1"
    docker exec -i "$PROWLARR_CONTAINER" curl -sS -o /dev/null -w '%{http_code}' \
        -X PUT -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
        --data @- "$API/$path"
}

px_post_body() {
    # px_post_body <path> ; JSON body on stdin. Echoes the response body.
    local path="$1"
    docker exec -i "$PROWLARR_CONTAINER" curl -sS \
        -X POST -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
        --data @- "$API/$path"
}

get_api_key() {
    docker exec "$PROWLARR_CONTAINER" sh -c "grep -oE '<ApiKey>[^<]+</ApiKey>' /config/config.xml" 2>/dev/null \
        | sed -e 's|<ApiKey>||' -e 's|</ApiKey>||' | tr -d '\r\n'
}

wait_for_prowlarr() {
    log "Waiting for Prowlarr API..."
    if wait_for_cmd "$MAX_RETRIES" "$RETRY_INTERVAL" px_curl -f -H "X-Api-Key: $KEY" "$API/system/status"; then
        log "Prowlarr API is ready"
        return 0
    fi
    log "WARNING: Prowlarr API did not become ready in time"
    return 1
}

ensure_download_client() {
    local user password schema payload code existing current id updated
    user="$(get_env_value ADMIN_USER)"
    password="$(get_env_value PASSWORD)"
    [ -n "$user" ] && [ -n "$password" ] || { log "WARNING: ADMIN_USER/PASSWORD not set; skipping download client"; return 0; }

    existing="$(px_curl -H "X-Api-Key: $KEY" "$API/downloadclient" 2>/dev/null)"
    current="$(printf '%s' "$existing" | jq -c --arg n "$QB_CLIENT_NAME" '.[]? | select(.name==$n)' 2>/dev/null)"

    if [ -n "$current" ] && [ "$current" != "null" ]; then
        # Reconcile the two fields this script owns: the host (migrating an older
        # localhost:8080 install after Prowlarr moved off the VPN) and the category
        # map. Comparing the re-serialised object rather than each field keeps the
        # "nothing to do" case quiet without a check per field; jq assignment keeps
        # existing keys in place, so both sides serialise in the same order.
        id="$(printf '%s' "$current" | jq -r '.id')"
        updated="$(printf '%s' "$current" | jq -c --arg h "$QB_HOST" --argjson cats "$QB_CATEGORY_MAP" \
            '.fields = ([.fields[] | if .name=="host" then .value=$h else . end])
             | .categories = $cats')"
        if [ "$updated" = "$current" ]; then
            log "qBittorrent download client already present, skipping"
            return 0
        fi
        code="$(printf '%s' "$updated" | px_put "downloadclient/$id")"
        case "$code" in
            20*) log "Updated qBittorrent download client (host $QB_HOST, library category map)" ;;
            *)   log "WARNING: qBittorrent downloadclient PUT returned HTTP $code" ;;
        esac
        return 0
    fi

    # Build the create body from the live schema so field names track the Prowlarr version.
    schema="$(px_curl -H "X-Api-Key: $KEY" "$API/downloadclient/schema" 2>/dev/null)"
    payload="$(printf '%s' "$schema" | jq -c \
        --arg name "$QB_CLIENT_NAME" --arg host "$QB_HOST" --argjson port "$QB_PORT" \
        --arg user "$user" --arg pass "$password" --argjson cats "$QB_CATEGORY_MAP" '
        (.[] | select(.implementation == "QBittorrent"))
        | .name = $name
        | .enable = true
        | .categories = $cats
        | .fields = ([.fields[]
            | if   .name == "host"     then .value = $host
              elif .name == "port"     then .value = $port
              elif .name == "username" then .value = $user
              elif .name == "password" then .value = $pass
              elif .name == "useSsl"   then .value = false
              else . end])
    ' 2>/dev/null)"
    [ -n "$payload" ] && [ "$payload" != "null" ] || { log "WARNING: could not build qBittorrent payload from schema"; return 0; }

    code="$(printf '%s' "$payload" | px_post "downloadclient")"
    case "$code" in
        20*) log "Added qBittorrent download client to Prowlarr (host: $QB_HOST)" ;;
        *)   log "WARNING: Prowlarr downloadclient POST returned HTTP $code" ;;
    esac
}

# Return the id of the FlareSolverr tag, creating it if needed. Empty on failure.
ensure_tag() {
    local tags id
    tags="$(px_curl -H "X-Api-Key: $KEY" "$API/tag" 2>/dev/null)"
    id="$(printf '%s' "$tags" | jq -r --arg l "$FLARESOLVERR_TAG" '.[]? | select(.label==$l) | .id' 2>/dev/null)"
    if [ -n "$id" ] && [ "$id" != "null" ]; then
        printf '%s' "$id"
        return 0
    fi
    printf '{"label":"%s"}' "$FLARESOLVERR_TAG" | px_post_body "tag" 2>/dev/null \
        | jq -r '.id // empty' 2>/dev/null
}

# Wait until FlareSolverr answers, else Prowlarr's connection test on save fails
# (Chrome needs ~45s to init on a fresh boot).
wait_for_flaresolverr() {
    wait_for_cmd "$MAX_RETRIES" "$RETRY_INTERVAL" px_curl -f "${FLARESOLVERR_HOST%/}/health"
}

ensure_flaresolverr_proxy() {
    local existing current current_host id tag_id schema payload code updated
    existing="$(px_curl -H "X-Api-Key: $KEY" "$API/indexerproxy" 2>/dev/null)"
    current="$(printf '%s' "$existing" | jq -c --arg n "$FLARESOLVERR_NAME" '.[]? | select(.name==$n)' 2>/dev/null)"

    if [ -n "$current" ] && [ "$current" != "null" ]; then
        current_host="$(printf '%s' "$current" | jq -r '.fields[]? | select(.name=="host") | .value' 2>/dev/null)"
        [ "$current_host" = "$FLARESOLVERR_HOST" ] && { log "FlareSolverr proxy already present, skipping"; return 0; }
    fi

    if ! wait_for_flaresolverr; then
        log "WARNING: FlareSolverr not reachable at $FLARESOLVERR_HOST; skipping proxy (will retry next start)"
        return 0
    fi

    if [ -n "$current" ] && [ "$current" != "null" ]; then
        # Migrate the host (e.g. localhost:8191 -> flaresolverr:8191 after moving off the VPN).
        id="$(printf '%s' "$current" | jq -r '.id')"
        updated="$(printf '%s' "$current" | jq -c --arg h "$FLARESOLVERR_HOST" \
            '.fields = ([.fields[] | if .name=="host" then .value=$h else . end])')"
        code="$(printf '%s' "$updated" | px_put "indexerproxy/$id")"
        case "$code" in
            20*) log "Updated FlareSolverr proxy host to $FLARESOLVERR_HOST" ;;
            *)   log "WARNING: FlareSolverr proxy PUT returned HTTP $code" ;;
        esac
        return 0
    fi

    tag_id="$(ensure_tag)"
    [ -n "$tag_id" ] || { log "WARNING: could not obtain '$FLARESOLVERR_TAG' tag; skipping FlareSolverr proxy"; return 0; }

    schema="$(px_curl -H "X-Api-Key: $KEY" "$API/indexerproxy/schema" 2>/dev/null)"
    payload="$(printf '%s' "$schema" | jq -c \
        --arg name "$FLARESOLVERR_NAME" --arg host "$FLARESOLVERR_HOST" --argjson tag "$tag_id" '
        (.[] | select(.implementation == "FlareSolverr"))
        | .name = $name
        | .tags = [$tag]
        | .fields = ([.fields[] | if .name=="host" then .value=$host else . end])
    ' 2>/dev/null)"
    [ -n "$payload" ] && [ "$payload" != "null" ] || { log "WARNING: could not build FlareSolverr payload from schema"; return 0; }

    code="$(printf '%s' "$payload" | px_post "indexerproxy")"
    case "$code" in
        20*) log "Added FlareSolverr proxy to Prowlarr (host: $FLARESOLVERR_HOST, tag: $FLARESOLVERR_TAG)" ;;
        *)   log "WARNING: Prowlarr indexerproxy POST returned HTTP $code" ;;
    esac
}

ensure_ntfy_notification() {
    local pw existing schema payload code
    pw="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_PROWLARR_PASSWORD)"
    [ -n "$pw" ] || { log "WARNING: NTFY_PROWLARR_PASSWORD not found in $NTFY_ENV_FILE; skipping ntfy notification"; return 0; }

    existing="$(px_curl -H "X-Api-Key: $KEY" "$API/notification" 2>/dev/null)"
    if printf '%s' "$existing" | jq -e --arg n "$NTFY_NOTIFICATION_NAME" '.[]? | select(.name==$n)' >/dev/null 2>&1; then
        log "ntfy notification already present, skipping"
        return 0
    fi

    # Prowlarr posts a test notification to ntfy on save, so ntfy must be reachable with
    # the prowlarr user's credentials by then (it is, once ntfy-pre-start ran + ntfy recreated).
    schema="$(px_curl -H "X-Api-Key: $KEY" "$API/notification/schema" 2>/dev/null)"
    payload="$(printf '%s' "$schema" | jq -c \
        --arg name "$NTFY_NOTIFICATION_NAME" --arg url "$NTFY_URL" --arg topic "$NTFY_TOPIC" \
        --arg user "prowlarr" --arg pass "$pw" '
        (.[] | select(.implementation == "Ntfy"))
        | .name = $name
        | .onGrab = true
        | .onHealthIssue = true
        | .onHealthRestored = true
        | .onApplicationUpdate = true
        | .fields = ([.fields[]
            | if   .name == "serverUrl" then .value = $url
              elif .name == "userName"  then .value = $user
              elif .name == "password"  then .value = $pass
              elif .name == "topics"    then .value = [$topic]
              else . end])
    ' 2>/dev/null)"
    [ -n "$payload" ] && [ "$payload" != "null" ] || { log "WARNING: could not build ntfy payload from schema"; return 0; }

    code="$(printf '%s' "$payload" | px_post "notification")"
    case "$code" in
        20*) log "Added ntfy notification to Prowlarr (topic: $NTFY_TOPIC)" ;;
        *)   log "WARNING: Prowlarr notification POST returned HTTP $code" ;;
    esac
}

main() {
    container_is_running "$PROWLARR_CONTAINER" || { log "Prowlarr not running, skipping"; return 0; }

    KEY="$(get_api_key)"
    [ -n "$KEY" ] || { log "WARNING: could not read Prowlarr API key from config.xml"; return 0; }

    wait_for_prowlarr || return 0

    ensure_download_client
    ensure_flaresolverr_proxy
    ensure_ntfy_notification
}

main "$@"
