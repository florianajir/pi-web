#!/bin/sh
# Point Shelfmark's authentication at Authelia over OIDC.
# A post-start hook (scripts/stack-up.sh). Idempotent: it only writes, and only
# restarts Shelfmark, when the stored settings actually differ.
#
# Shelfmark keeps each settings tab in /config/plugins/<tab>.json
# (shelfmark/core/settings_registry.py), and it has no unauthenticated API to
# set them — which is the chicken-and-egg this script exists to break. The
# client secret goes into that file rather than into the service's environment,
# so it does not end up in `docker inspect` (see docs/SECURITY.md → Secrets).
#
# DISABLE_LOCAL_AUTH is set on the service in compose.yaml instead: Shelfmark
# reads it at import time, before the settings system exists, and it is what
# drops the "a local admin account is required before OIDC can be enabled"
# prerequisite that no unattended install can satisfy.

set -eu

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=120
RETRY_INTERVAL=2
SHELFMARK_CONTAINER="${SHELFMARK_CONTAINER:-pi-shelfmark}"
SHELFMARK_URL_DOCKER="${SHELFMARK_URL_DOCKER:-http://pi-shelfmark:8084}"
SECURITY_PATH="/config/plugins/security.json"
OIDC_ADMIN_GROUP="admin"
PUID=1000
PGID=1000

main() {
    local host_name="" secret="" current="" desired=""

    log "=== Shelfmark OIDC Bootstrap ==="

    [ -f "$ENV_FILE" ] || die ".env missing at $ENV_FILE"

    host_name="$(get_env_value HOST_NAME)"
    host_name="${host_name:-pi.lan}"

    ensure_authelia_oidc_materials "shelfmark" "Shelfmark" "$MAX_RETRIES" "$RETRY_INTERVAL" \
        || die "Shelfmark OIDC prerequisites are missing in Authelia configuration"

    wait_for_container "$SHELFMARK_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL" || exit 1
    wait_for_http_endpoint "$SHELFMARK_URL_DOCKER/api/health" "Shelfmark HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || exit 1

    secret="$(get_oidc_secret "shelfmark")" || die "Could not read Shelfmark OIDC client secret"
    [ -n "$secret" ] || die "Shelfmark OIDC client secret is empty"

    current="$(docker exec "$SHELFMARK_CONTAINER" cat "$SECURITY_PATH" 2>/dev/null || echo '{}')"
    printf '%s' "$current" | jq -e . >/dev/null 2>&1 || current='{}'

    # Merged, not replaced: the tab also holds the proxy-auth and Calibre-Web
    # fields, and a user may have set unrelated ones.
    desired="$(printf '%s' "$current" | jq \
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
         }')"

    if [ "$(printf '%s' "$current" | jq -S .)" = "$(printf '%s' "$desired" | jq -S .)" ]; then
        log "Shelfmark OIDC already configured; nothing to do"
        exit 0
    fi

    docker exec "$SHELFMARK_CONTAINER" mkdir -p "$(dirname "$SECURITY_PATH")" \
        || die "Failed to create $(dirname "$SECURITY_PATH") in $SHELFMARK_CONTAINER"
    printf '%s' "$desired" | docker exec -i "$SHELFMARK_CONTAINER" sh -c "cat > $SECURITY_PATH" \
        || die "Failed to write $SECURITY_PATH in $SHELFMARK_CONTAINER"
    # docker exec runs as root while the app runs as PUID:PGID, so without this
    # Shelfmark could read the file it just got but never save the tab again.
    docker exec "$SHELFMARK_CONTAINER" sh -c \
        "chown ${PUID}:${PGID} '$(dirname "$SECURITY_PATH")' '$SECURITY_PATH' && chmod 600 '$SECURITY_PATH'" \
        || log "WARNING: could not fix ownership of $SECURITY_PATH"

    log "Configured Shelfmark OIDC (issuer=https://auth.${host_name}); restarting to apply"
    compose restart shelfmark >/dev/null || die "Failed to restart Shelfmark after OIDC configuration"

    wait_for_http_endpoint "$SHELFMARK_URL_DOCKER/api/health" "Shelfmark HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || true
    log "Shelfmark OIDC bootstrap configured successfully"
}

main "$@"
