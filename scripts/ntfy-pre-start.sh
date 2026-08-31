#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"

OUTPUT_FILE="${PROJECT_DIR}/config/ntfy/ntfy.env"
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
NTFY_IMAGE="${NTFY_IMAGE:-binwiederhier/ntfy:v2.17.0}"
# One topic per reading mode, so each can be muted, scheduled or given its own
# do-not-disturb rule on the phone independently. Publishers only ever get
# access to the topic they belong to (see AUTH_ACCESS_VALUE below).
#   monitoring - service health: uptime-kuma, beszel, dockhand, backrest
#   downloads  - grabs and completed downloads: prowlarr, qbittorrent
#   security   - authelia failed logins and regulation bans
NTFY_MONITORING_TOPIC="monitoring"
NTFY_DOWNLOADS_TOPIC="downloads"
NTFY_SECURITY_TOPIC="security"

hash_password() {
    _password="$1"
    printf '%s\n%s\n' "$_password" "$_password" | \
    docker run -i --rm --entrypoint sh "$NTFY_IMAGE" -lc 'ntfy user hash'
}

generate_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -d '\r\n'
        return
    fi

    head -c 24 /dev/urandom | base64 | tr -d '\r\n'
}

generate_token() {
    docker run --rm --entrypoint sh "$NTFY_IMAGE" -c 'ntfy token generate'
}

escape_compose_env_value() {
    printf '%s' "$1" | sed 's/[$]/$$/g'
}

main() {
    if [ ! -f "$ENV_FILE" ]; then
        die ".env not found at $ENV_FILE"
    fi

    USER_VALUE=$(get_env_value ADMIN_USER)
    PASSWORD_VALUE=$(get_env_value PASSWORD)
    NTFY_BACKREST_PASSWORD_VALUE=""
    NTFY_BESZEL_PASSWORD_VALUE=""
    NTFY_DOCKHAND_PASSWORD_VALUE=""
    NTFY_UPTIME_KUMA_PASSWORD_VALUE=""
    NTFY_UPTIME_KUMA_TOKEN_VALUE=""
    UPTIME_KUMA_ADMIN_PASSWORD_VALUE=""
    NTFY_PROWLARR_PASSWORD_VALUE=""
    NTFY_QBITTORRENT_PASSWORD_VALUE=""
    NTFY_QBITTORRENT_TOKEN_VALUE=""
    NTFY_AUTHELIA_PASSWORD_VALUE=""

    if [ -f "$OUTPUT_FILE" ]; then
        NTFY_BACKREST_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_BACKREST_PASSWORD)
        if [ -z "$NTFY_BACKREST_PASSWORD_VALUE" ]; then
            NTFY_BACKREST_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_PASSWORD)
        fi

        NTFY_BESZEL_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_BESZEL_PASSWORD)
        NTFY_DOCKHAND_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_DOCKHAND_PASSWORD)
        NTFY_UPTIME_KUMA_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_UPTIME_KUMA_PASSWORD)
        NTFY_UPTIME_KUMA_TOKEN_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_UPTIME_KUMA_TOKEN)
        UPTIME_KUMA_ADMIN_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" UPTIME_KUMA_ADMIN_PASSWORD)
        NTFY_PROWLARR_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_PROWLARR_PASSWORD)
        NTFY_QBITTORRENT_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_QBITTORRENT_PASSWORD)
        NTFY_QBITTORRENT_TOKEN_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_QBITTORRENT_TOKEN)
        NTFY_AUTHELIA_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_AUTHELIA_PASSWORD)
    fi

    if [ -z "$USER_VALUE" ]; then
        die "ADMIN_USER is not set in .env"
    fi

    if [ -z "$PASSWORD_VALUE" ]; then
        die "PASSWORD is not set in .env"
    fi

    if [ -z "$NTFY_BACKREST_PASSWORD_VALUE" ]; then
        NTFY_BACKREST_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_BACKREST_PASSWORD for backrest ntfy user"
    fi

    if [ -z "$NTFY_BESZEL_PASSWORD_VALUE" ]; then
        NTFY_BESZEL_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_BESZEL_PASSWORD for beszel ntfy user"
    fi

    if [ -z "$NTFY_DOCKHAND_PASSWORD_VALUE" ]; then
        NTFY_DOCKHAND_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_DOCKHAND_PASSWORD for dockhand ntfy user"
    fi

    if [ -z "$NTFY_UPTIME_KUMA_PASSWORD_VALUE" ]; then
        NTFY_UPTIME_KUMA_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_UPTIME_KUMA_PASSWORD for uptime-kuma ntfy user"
    fi

    if [ -z "$NTFY_UPTIME_KUMA_TOKEN_VALUE" ]; then
        NTFY_UPTIME_KUMA_TOKEN_VALUE="$(generate_token)"
        log "Generated NTFY_UPTIME_KUMA_TOKEN for uptime-kuma ntfy user"
    fi

    if [ -z "$UPTIME_KUMA_ADMIN_PASSWORD_VALUE" ]; then
        UPTIME_KUMA_ADMIN_PASSWORD_VALUE="$(generate_password)"
        log "Generated UPTIME_KUMA_ADMIN_PASSWORD for uptime-kuma admin account"
    fi

    if [ -z "$NTFY_PROWLARR_PASSWORD_VALUE" ]; then
        NTFY_PROWLARR_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_PROWLARR_PASSWORD for prowlarr ntfy user"
    fi

    if [ -z "$NTFY_QBITTORRENT_PASSWORD_VALUE" ]; then
        NTFY_QBITTORRENT_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_QBITTORRENT_PASSWORD for qbittorrent ntfy user"
    fi

    if [ -z "$NTFY_QBITTORRENT_TOKEN_VALUE" ]; then
        NTFY_QBITTORRENT_TOKEN_VALUE="$(generate_token)"
        log "Generated NTFY_QBITTORRENT_TOKEN for qbittorrent ntfy user"
    fi

    if [ -z "$NTFY_AUTHELIA_PASSWORD_VALUE" ]; then
        NTFY_AUTHELIA_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_AUTHELIA_PASSWORD for authelia ntfy user"
    fi

    log "Generating bcrypt hashes for ntfy predefined users"
    USER_HASH="$(hash_password "$PASSWORD_VALUE")"
    BACKREST_HASH="$(hash_password "$NTFY_BACKREST_PASSWORD_VALUE")"
    BESZEL_HASH="$(hash_password "$NTFY_BESZEL_PASSWORD_VALUE")"
    DOCKHAND_HASH="$(hash_password "$NTFY_DOCKHAND_PASSWORD_VALUE")"
    UPTIME_KUMA_HASH="$(hash_password "$NTFY_UPTIME_KUMA_PASSWORD_VALUE")"
    PROWLARR_HASH="$(hash_password "$NTFY_PROWLARR_PASSWORD_VALUE")"
    QBITTORRENT_HASH="$(hash_password "$NTFY_QBITTORRENT_PASSWORD_VALUE")"
    AUTHELIA_HASH="$(hash_password "$NTFY_AUTHELIA_PASSWORD_VALUE")"

    mkdir -p "$OUTPUT_DIR"

    AUTH_USERS_VALUE="${USER_VALUE}:${USER_HASH}:admin,backrest:${BACKREST_HASH}:user,beszel:${BESZEL_HASH}:user,dockhand:${DOCKHAND_HASH}:user,uptime-kuma:${UPTIME_KUMA_HASH}:user,prowlarr:${PROWLARR_HASH}:user,qbittorrent:${QBITTORRENT_HASH}:user,authelia:${AUTHELIA_HASH}:user"
    AUTH_ACCESS_VALUE="backrest:${NTFY_MONITORING_TOPIC}:rw,beszel:${NTFY_MONITORING_TOPIC}:rw,dockhand:${NTFY_MONITORING_TOPIC}:rw,uptime-kuma:${NTFY_MONITORING_TOPIC}:rw,prowlarr:${NTFY_DOWNLOADS_TOPIC}:rw,qbittorrent:${NTFY_DOWNLOADS_TOPIC}:rw,authelia:${NTFY_SECURITY_TOPIC}:rw"
    AUTH_TOKENS_VALUE="uptime-kuma:${NTFY_UPTIME_KUMA_TOKEN_VALUE}:Uptime Kuma notification token,qbittorrent:${NTFY_QBITTORRENT_TOKEN_VALUE}:qBittorrent download notifications"

    {
        printf '# Managed by scripts/ntfy-pre-start.sh\n'
        printf 'NTFY_BACKREST_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_BACKREST_PASSWORD_VALUE")"
        printf 'NTFY_BESZEL_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_BESZEL_PASSWORD_VALUE")"
        printf 'NTFY_DOCKHAND_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_DOCKHAND_PASSWORD_VALUE")"
        printf 'NTFY_UPTIME_KUMA_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_UPTIME_KUMA_PASSWORD_VALUE")"
        printf 'NTFY_UPTIME_KUMA_TOKEN=%s\n' "$(escape_compose_env_value "$NTFY_UPTIME_KUMA_TOKEN_VALUE")"
        printf 'NTFY_PROWLARR_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_PROWLARR_PASSWORD_VALUE")"
        printf 'NTFY_QBITTORRENT_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_QBITTORRENT_PASSWORD_VALUE")"
        printf 'NTFY_QBITTORRENT_TOKEN=%s\n' "$(escape_compose_env_value "$NTFY_QBITTORRENT_TOKEN_VALUE")"
        printf 'NTFY_AUTHELIA_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_AUTHELIA_PASSWORD_VALUE")"
        printf 'NTFY_MONITORING_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_MONITORING_TOPIC")"
        printf 'NTFY_DOWNLOADS_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_DOWNLOADS_TOPIC")"
        printf 'NTFY_SECURITY_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_SECURITY_TOPIC")"
        printf 'NTFY_AUTHELIA_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_SECURITY_TOPIC")"
        printf 'NTFY_BESZEL_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_MONITORING_TOPIC")"
        printf 'NTFY_DOCKHAND_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_MONITORING_TOPIC")"
        # Read by scripts/backrest-post-hook.sh inside the backrest container,
        # which loads this file through the service's env_file.
        printf 'BACKREST_NTFY_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_MONITORING_TOPIC")"
        printf 'NTFY_AUTH_USERS=%s\n' "$(escape_compose_env_value "$AUTH_USERS_VALUE")"
        printf 'NTFY_AUTH_ACCESS=%s\n' "$(escape_compose_env_value "$AUTH_ACCESS_VALUE")"
        printf 'NTFY_AUTH_TOKENS=%s\n' "$(escape_compose_env_value "$AUTH_TOKENS_VALUE")"
        printf 'UPTIME_KUMA_ADMIN_PASSWORD=%s\n' "$(escape_compose_env_value "$UPTIME_KUMA_ADMIN_PASSWORD_VALUE")"
    } > "$OUTPUT_FILE"

    chmod 600 "$OUTPUT_FILE"
    log "Rendered ntfy env to $OUTPUT_FILE"
}

main "$@"
