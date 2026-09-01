#!/bin/sh
# Configure the Shelfmark settings that live in its own config files rather than
# in its environment: the Authelia OIDC client, the proxy that puts direct
# downloads on the VPN, and the Anna's Archive mirror list.
# A post-start hook (scripts/stack-up.sh). Idempotent: it writes, and restarts
# Shelfmark, only when something actually differs.
#
# Shelfmark keeps each settings tab in /config/plugins/<tab>.json
# (shelfmark/core/settings_registry.py) and resolves a setting from the
# environment first, then from that file. It has no unauthenticated API to set
# them, which is the chicken-and-egg this script exists to break. Everything
# that can safely be an env var already is one, on the service in compose.yaml;
# what lands here does so for a reason, noted per section below.

set -eu

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=120
RETRY_INTERVAL=2
SHELFMARK_CONTAINER="${SHELFMARK_CONTAINER:-pi-shelfmark}"
SHELFMARK_URL_DOCKER="${SHELFMARK_URL_DOCKER:-http://pi-shelfmark:8084}"
PLUGINS_DIR="/config/plugins"
OIDC_ADMIN_GROUP="admin"
GLUETUN_HTTP_PROXY="http://gluetun:8888"
# Verified reachable and serving the real site on 2026-09-02. Upstream's readme
# calls out annas-archive.is as not working as a source, and annas-archive.li
# answers with a 1 KB holding page, so neither is seeded.
AA_MIRROR_URL="https://annas-archive.gl"
PUID=1000
PGID=1000

CHANGED=0

read_json() {
    # read_json <path> ; echoes the file, or {} when absent or unparseable.
    local raw=""
    raw="$(docker exec "$SHELFMARK_CONTAINER" cat "$1" 2>/dev/null || true)"
    printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || raw='{}'
    printf '%s' "$raw"
}

write_json() {
    # write_json <path> <json> ; writes as root, then hands the file back to the
    # app's uid - docker exec runs as root while Shelfmark runs as PUID:PGID, so
    # without the chown it could read the file but never save that tab again.
    # The mkdir is belt and braces: Shelfmark creates the directory during the
    # startup this script has already waited for, but a `cat >` into a missing
    # directory would fail the whole hook, and a tolerant hook failing here
    # means no OIDC - with no password login to fall back on.
    local path="$1" body="$2"
    docker exec "$SHELFMARK_CONTAINER" sh -c \
        "mkdir -p '$PLUGINS_DIR' && chown ${PUID}:${PGID} '$PLUGINS_DIR'" \
        || return 1
    printf '%s' "$body" | docker exec -i "$SHELFMARK_CONTAINER" sh -c "cat > $path" \
        || return 1
    docker exec "$SHELFMARK_CONTAINER" sh -c \
        "chown ${PUID}:${PGID} '$path' && chmod 600 '$path'" \
        || log "WARNING: could not fix ownership of $path"
}

# apply <tab> <jq filter> [jq args...] ; reads the tab, applies the filter, and
# writes it back when the result differs. Sets CHANGED so one restart covers
# every tab this run touched.
apply() {
    local tab="$1"
    shift
    local path="$PLUGINS_DIR/$tab.json" current="" desired=""

    current="$(read_json "$path")"
    desired="$(printf '%s' "$current" | jq "$@")" || die "Failed to build $tab.json"

    if [ "$(printf '%s' "$current" | jq -S .)" = "$(printf '%s' "$desired" | jq -S .)" ]; then
        log "$tab settings already current"
        return 0
    fi

    write_json "$path" "$desired" || die "Failed to write $path in $SHELFMARK_CONTAINER"
    log "Updated $tab settings"
    CHANGED=1
}

# The client secret is kept out of the environment so `docker inspect` does not
# print it - see docs/SECURITY.md. DISABLE_LOCAL_AUTH stays an env var because
# Shelfmark reads it at import, before this file is ever loaded.
configure_oidc() {
    local host_name="" secret=""

    host_name="$(get_env_value HOST_NAME)"
    host_name="${host_name:-pi.lan}"

    ensure_authelia_oidc_materials "shelfmark" "Shelfmark" "$MAX_RETRIES" "$RETRY_INTERVAL" \
        || die "Shelfmark OIDC prerequisites are missing in Authelia configuration"

    secret="$(get_oidc_secret "shelfmark")" || die "Could not read Shelfmark OIDC client secret"
    [ -n "$secret" ] || die "Shelfmark OIDC client secret is empty"

    # Merged, not replaced: the tab also carries the proxy-auth and Calibre-Web
    # fields, and a user may have set unrelated ones.
    apply security \
        --arg discovery "https://auth.${host_name}/.well-known/openid-configuration" \
        --arg secret "$secret" \
        --arg group "$OIDC_ADMIN_GROUP" \
        '. + {
            AUTH_METHOD: "oidc",
            OIDC_DISCOVERY_URL: $discovery,
            OIDC_CLIENT_ID: "shelfmark",
            OIDC_CLIENT_SECRET: $secret,
            OIDC_GROUP_CLAIM: "groups",
            OIDC_ADMIN_GROUP: $group,
            OIDC_USE_ADMIN_GROUP: true,
            OIDC_AUTO_PROVISION: true
         }'
}

# Direct downloads are plain HTTPS from this container, so unlike the torrents
# they would leave on the residential IP. Routing them through gluetun's proxy
# puts them back on the tunnel.
#
# In this file rather than in `environment:` on purpose: HTTP_PROXY and NO_PROXY
# are also the names requests/urllib read straight out of the environment, so
# setting them there would silently proxy every other outbound call too - the
# Prowlarr API, the FlareSolverr hand-off, the OIDC token exchange - against a
# matcher whose syntax differs from Shelfmark's. Here they reach only the
# release-source and download paths, which are the ones that read
# download/network.py get_proxies(). Nothing else breaks when gluetun is down.
configure_proxy() {
    local host_name="" no_proxy=""

    host_name="$(get_env_value HOST_NAME)"
    host_name="${host_name:-pi.lan}"
    # Matched with fnmatch, so the glob is the right shape here.
    no_proxy="localhost,127.0.0.1,gluetun,prowlarr,flaresolverr,ntfy,*.${host_name}"

    apply network \
        --arg proxy "$GLUETUN_HTTP_PROXY" \
        --arg noproxy "$no_proxy" \
        '. + {PROXY_MODE: "http", HTTP_PROXY: $proxy, NO_PROXY: $noproxy}'
}

# Seeded, not reconciled: mirror availability moves on its own schedule and the
# list is the user's to curate in Settings -> Mirrors. Only an empty list is
# filled, so an edited one is left alone.
seed_mirrors() {
    apply mirrors \
        --arg mirror "$AA_MIRROR_URL" \
        'if (.AA_MIRROR_URLS // []) == [] then .AA_MIRROR_URLS = [$mirror] else . end'
}

main() {
    log "=== Shelfmark Settings Bootstrap ==="

    [ -f "$ENV_FILE" ] || die ".env missing at $ENV_FILE"

    wait_for_container "$SHELFMARK_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL" || exit 1
    wait_for_http_endpoint "$SHELFMARK_URL_DOCKER/api/health" "Shelfmark HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || exit 1

    configure_oidc
    configure_proxy
    seed_mirrors

    if [ "$CHANGED" = "0" ]; then
        log "Shelfmark settings already configured; nothing to do"
        exit 0
    fi

    log "Restarting Shelfmark to apply"
    compose restart shelfmark >/dev/null || die "Failed to restart Shelfmark"
    wait_for_http_endpoint "$SHELFMARK_URL_DOCKER/api/health" "Shelfmark HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || true
    log "Shelfmark settings bootstrap complete"
}

main "$@"
