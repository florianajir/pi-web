#!/bin/sh
# Configure Nextcloud OIDC provider for Authelia in a non-interactive, idempotent way.

set -eu

NEXTCLOUD_CONTAINER="${NEXTCLOUD_CONTAINER:-pi-nextcloud}"
AUTHELIA_CONTAINER="${AUTHELIA_CONTAINER:-pi-authelia}"
HOST_NAME="${HOST_NAME:-pi.lan}"

OIDC_PROVIDER_ID="${OIDC_PROVIDER_ID:-authelia}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-nextcloud}"
OIDC_DISCOVERY_URI="${OIDC_DISCOVERY_URI:-https://auth.${HOST_NAME}/.well-known/openid-configuration}"
OIDC_SCOPE="${OIDC_SCOPE:-openid email profile groups}"

log() {
    echo "[nextcloud-oidc-configure] $(date '+%H:%M:%S') $*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

wait_for_occ() {
    max_attempts="${1:-60}"
    attempt=1

    while [ "$attempt" -le "$max_attempts" ]; do
        if docker exec "$NEXTCLOUD_CONTAINER" php occ status >/dev/null 2>&1; then
            log "Nextcloud OCC is ready"
            return 0
        fi

        log "Waiting for Nextcloud OCC to be ready (attempt ${attempt}/${max_attempts})"
        attempt=$((attempt + 1))
        sleep 5
    done

    return 1
}

get_client_secret() {
    if [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
        printf '%s' "$OIDC_CLIENT_SECRET"
        return 0
    fi

    docker exec "$AUTHELIA_CONTAINER" sh -ec 'cat /config/secrets/oidc_nextcloud_secret.txt'
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

    die "Unable to install or enable Nextcloud app 'user_oidc'"
}

configure_provider() {
    client_secret="$1"

    docker exec \
        -e OIDC_CLIENT_SECRET="$client_secret" \
        "$NEXTCLOUD_CONTAINER" \
        php occ user_oidc:provider "$OIDC_PROVIDER_ID" \
        --clientid="$OIDC_CLIENT_ID" \
        --clientsecret-env=OIDC_CLIENT_SECRET \
        --discoveryuri="$OIDC_DISCOVERY_URI" \
        --scope="$OIDC_SCOPE" \
        --mapping-uid="preferred_username" \
        --mapping-display-name="name" \
        --mapping-email="email" \
        --mapping-groups="groups" \
        --group-provisioning=1 \
        --group-restrict-login-to-whitelist=0 \
        --unique-uid=1 \
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
    command -v docker >/dev/null 2>&1 || die "docker CLI is required"

    wait_for_occ || die "Nextcloud did not become ready in time"
    ensure_user_oidc_app

    client_secret="$(get_client_secret || true)"
    [ -n "$client_secret" ] || die "Unable to read OIDC client secret from Authelia"

    configure_provider "$client_secret"
    verify_provider || die "OIDC provider verification failed"

    log "Nextcloud OIDC bootstrap complete"
}

main "$@"
