#!/bin/sh
# Wire Kavita's OpenID Connect settings (Authelia) into its appsettings.json.
# A post-start hook (scripts/stack-up.sh). Safe to run multiple times: it only touches the
# OpenIdConnectSettings block and restarts Kavita only when something changed.
#
# NOTE: auto-provisioning and role-sync are stored in Kavita's DB, not appsettings —
# they are a one-time toggle in the admin UI (Settings > OpenID Connect).

set -eu

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=120
RETRY_INTERVAL=2
KAVITA_CONTAINER="${KAVITA_CONTAINER:-pi-kavita}"
KAVITA_URL_DOCKER="${KAVITA_URL_DOCKER:-http://pi-kavita:5000}"
APPSETTINGS_PATH="/config/appsettings.json"

main() {
    local enabled host_name authority secret current desired

    log "=== Kavita OIDC Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        die ".env missing at $ENV_FILE"
    fi

    enabled="$(get_env_value KAVITA_OIDC_ENABLED)"
    [ -n "$enabled" ] || enabled="true"
    if ! is_truthy "$enabled"; then
        log "KAVITA_OIDC_ENABLED is disabled, skipping bootstrap"
        exit 0
    fi

    host_name="$(get_env_value HOST_NAME)"
    host_name="${host_name:-pi.lan}"
    authority="https://auth.${host_name}"

    ensure_authelia_oidc_materials "kavita" "Kavita" "$MAX_RETRIES" "$RETRY_INTERVAL" || {
        die "Kavita OIDC prerequisites are missing in Authelia configuration"
    }

    wait_for_container "$KAVITA_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL" || exit 1
    # Kavita writes appsettings.json during startup; wait until its HTTP API answers.
    wait_for_http_endpoint "$KAVITA_URL_DOCKER/api/health" "Kavita HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || exit 1

    secret="$(get_oidc_secret "kavita")" || die "Could not read Kavita OIDC client secret"
    [ -n "$secret" ] || die "Kavita OIDC client secret is empty"

    current="$(docker exec "$KAVITA_CONTAINER" cat "$APPSETTINGS_PATH" 2>/dev/null || echo '{}')"

    desired="$(printf '%s' "$current" | jq \
        --arg authority "$authority" \
        --arg secret "$secret" \
        '.OpenIdConnectSettings = ((.OpenIdConnectSettings // {}) + {
            Authority: $authority,
            ClientId: "kavita",
            Secret: $secret,
            CustomScopes: ["groups"],
            Enabled: true
         })')"

    if [ "$(printf '%s' "$current" | jq -S .)" = "$(printf '%s' "$desired" | jq -S .)" ]; then
        log "Kavita OIDC already configured; nothing to do"
        exit 0
    fi

    # Write the patched file back into the container, then restart so Kavita loads it.
    printf '%s' "$desired" | docker exec -i "$KAVITA_CONTAINER" sh -c "cat > $APPSETTINGS_PATH" || {
        die "Failed to write $APPSETTINGS_PATH in $KAVITA_CONTAINER"
    }

    log "Configured Kavita OIDC (authority=$authority); restarting to apply"
    (cd "$PROJECT_DIR" && docker compose restart kavita >/dev/null) || {
        die "Failed to restart Kavita after OIDC configuration"
    }

    wait_for_http_endpoint "$KAVITA_URL_DOCKER/api/health" "Kavita HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || true
    log "Kavita OIDC bootstrap configured successfully"
}

main "$@"
