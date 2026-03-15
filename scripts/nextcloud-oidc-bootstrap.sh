#!/bin/sh
# Configure Nextcloud OIDC provider for Authelia integration.
# Runs as ExecStartPost after docker compose up.
# Safe to run multiple times (idempotent).

set -e

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=60
RETRY_INTERVAL=5
NEXTCLOUD_CONTAINER="${NEXTCLOUD_CONTAINER:-pi-nextcloud}"
OIDC_PROVIDER_ID="${OIDC_PROVIDER_ID:-authelia}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-nextcloud}"

wait_for_occ() {
    log "Waiting for Nextcloud OCC to be ready..."
    for i in $(seq 1 $MAX_RETRIES); do
        if docker exec "$NEXTCLOUD_CONTAINER" php occ status >/dev/null 2>&1; then
            log "Nextcloud OCC is ready"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done

    log "ERROR: Nextcloud OCC did not become ready in time"
    return 1
}

ensure_user_oidc_app() {
    if docker exec "$NEXTCLOUD_CONTAINER" php occ app:list | grep -qE '^[[:space:]]+- user_oidc:'; then
        log "user_oidc app already enabled"
        return 0
    fi

    if docker exec "$NEXTCLOUD_CONTAINER" php occ app:install user_oidc >/dev/null 2>&1; then
        log "Installed and enabled user_oidc app"
        return 0
    fi

    if docker exec "$NEXTCLOUD_CONTAINER" php occ app:enable user_oidc >/dev/null 2>&1; then
        log "Enabled already-installed user_oidc app"
        return 0
    fi

    log "ERROR: Unable to install or enable Nextcloud app 'user_oidc'"
    return 1
}

configure_provider() {
    local client_secret="$1"
    local discovery_uri="https://auth.${HOST_NAME}/.well-known/openid-configuration"

    docker exec \
        -e OIDC_CLIENT_SECRET="$client_secret" \
        "$NEXTCLOUD_CONTAINER" \
        php occ user_oidc:provider "$OIDC_PROVIDER_ID" \
        --clientid="$OIDC_CLIENT_ID" \
        --clientsecret-env=OIDC_CLIENT_SECRET \
        --discoveryuri="$discovery_uri" \
        --scope="openid email profile groups" \
        --mapping-uid="email" \
        --mapping-display-name="name" \
        --mapping-email="email" \
        --mapping-groups="groups" \
        --group-provisioning=1 \
        --group-restrict-login-to-whitelist=0 \
        --unique-uid=0 \
        --resolve-nested-claims=1 \
        --check-bearer=0 \
        --bearer-provisioning=0 \
        >/dev/null

    log "OIDC provider '$OIDC_PROVIDER_ID' configured"
}

verify_provider() {
    docker exec "$NEXTCLOUD_CONTAINER" php occ user_oidc:provider "$OIDC_PROVIDER_ID" --output=json >/dev/null 2>&1
}

main() {
    log "=== Nextcloud OIDC Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        die ".env missing at $ENV_FILE"
    fi

    HOST_NAME="$(get_env_value HOST_NAME)"
    HOST_NAME="${HOST_NAME:-pi.lan}"

    if ! wait_for_container "$NEXTCLOUD_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL"; then
        exit 1
    fi

    if ! wait_for_occ; then
        exit 1
    fi

    ensure_user_oidc_app || exit 1

    OIDC_CLIENT_SECRET="$(get_oidc_secret "nextcloud" "NEXTCLOUD_OIDC_CLIENT_SECRET")" || {
        die "Could not read Nextcloud OIDC client secret"
    }

    if [ -z "$OIDC_CLIENT_SECRET" ]; then
        die "Nextcloud OIDC client secret is empty"
    fi

    configure_provider "$OIDC_CLIENT_SECRET"

    if ! verify_provider; then
        die "OIDC provider verification failed"
    fi

    log "Nextcloud OIDC configured successfully"
}

main "$@"
