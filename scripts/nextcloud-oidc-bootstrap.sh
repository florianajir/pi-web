#!/bin/sh
# Configure Nextcloud OIDC provider for Authelia integration.
# Runs as ExecStartPost after docker compose up.
# Safe to run multiple times (idempotent).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="$PROJECT_DIR/.env"
MAX_RETRIES=60
RETRY_INTERVAL=5
NEXTCLOUD_CONTAINER="${NEXTCLOUD_CONTAINER:-pi-nextcloud}"
AUTHELIA_CONTAINER="${AUTHELIA_CONTAINER:-pi-authelia}"
OIDC_PROVIDER_ID="${OIDC_PROVIDER_ID:-authelia}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-nextcloud}"

log() {
    echo "[nextcloud-oidc-bootstrap] $(date '+%H:%M:%S') $*" >&2
}

read_env_value_from_file() {
    local file="$1"
    local key="$2"

    if [ ! -f "$file" ]; then
        return 0
    fi

    grep "^$key=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

get_env_value() {
    local key="$1"
    local value=""

    value="$(eval "printf '%s' \"\${$key}\"")"
    if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
    fi

    read_env_value_from_file "$ENV_FILE" "$key"
}

resolve_data_location_path() {
    local data_location

    data_location="$(get_env_value DATA_LOCATION)"
    [ -n "$data_location" ] || data_location="./data"

    case "$data_location" in
        /*) printf '%s' "$data_location" ;;
        *) printf '%s/%s' "$PROJECT_DIR" "$data_location" ;;
    esac
}

wait_for_nextcloud_container() {
    log "Waiting for Nextcloud container to appear..."
    for i in $(seq 1 $MAX_RETRIES); do
        if docker ps --format '{{.Names}}' | grep -q "^${NEXTCLOUD_CONTAINER}$"; then
            log "Nextcloud container is running"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done

    log "ERROR: Nextcloud container did not start in time"
    return 1
}

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

get_oidc_client_secret() {
    local explicit_secret data_root secret_file secret_value

    explicit_secret="$(get_env_value NEXTCLOUD_OIDC_CLIENT_SECRET)"
    if [ -n "$explicit_secret" ]; then
        printf '%s' "$explicit_secret"
        return 0
    fi

    data_root="$(resolve_data_location_path)"
    secret_file="$data_root/authelia-config/secrets/oidc_nextcloud_secret.txt"

    if [ -r "$secret_file" ]; then
        tr -d '\r\n' < "$secret_file"
        return 0
    fi

    # Fallback: read from Authelia container
    secret_value="$(docker exec "$AUTHELIA_CONTAINER" sh -ec 'cat /config/secrets/oidc_nextcloud_secret.txt' 2>/dev/null | tr -d '\r\n')"
    if [ -n "$secret_value" ]; then
        printf '%s' "$secret_value"
        return 0
    fi

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
        log "ERROR: .env missing at $ENV_FILE"
        exit 1
    fi

    HOST_NAME="$(get_env_value HOST_NAME)"
    HOST_NAME="${HOST_NAME:-pi.lan}"

    if ! wait_for_nextcloud_container; then
        exit 1
    fi

    if ! wait_for_occ; then
        exit 1
    fi

    ensure_user_oidc_app || exit 1

    OIDC_CLIENT_SECRET="$(get_oidc_client_secret)" || {
        log "ERROR: Could not read Nextcloud OIDC client secret"
        exit 1
    }

    if [ -z "$OIDC_CLIENT_SECRET" ]; then
        log "ERROR: Nextcloud OIDC client secret is empty"
        exit 1
    fi

    configure_provider "$OIDC_CLIENT_SECRET"

    if ! verify_provider; then
        log "ERROR: OIDC provider verification failed"
        exit 1
    fi

    log "Nextcloud OIDC configured successfully"
}

main "$@"
