#!/bin/sh
# Generate Authelia secrets and render configuration from template.
# Idempotent: existing secrets and configuration are preserved.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="$PROJECT_DIR/.env"
CONFIG_TEMPLATE="$PROJECT_DIR/config/authelia/configuration.yml.template"
IMMICH_OAUTH_TEMPLATE="$PROJECT_DIR/config/immich/oauth-config.yaml.template"

log() {
    echo "[authelia-pre-start] $(date '+%H:%M:%S') $*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

safe_chmod() {
    local mode="$1"
    local path="$2"
    if ! chmod "$mode" "$path" 2>/dev/null; then
        log "WARNING: could not chmod $mode $path (insufficient permissions?)"
    fi
}

# Fix ownership of a path to match the project directory owner so non-root
# users can still read the generated files after a root-run systemd start.
_fix_ownership() {
    _owner=$(stat -c '%u:%g' "$PROJECT_DIR" 2>/dev/null || true)
    if [ -n "$_owner" ] && [ "$_owner" != "0:0" ]; then
        chown -R "$_owner" "$1" 2>/dev/null || true
    fi
}

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        log "WARNING: openssl not found; falling back to /dev/urandom for secret generation"
        head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n'
    fi
}

generate_rsa_key() {
    local keyfile="$1"
    if ! command -v openssl >/dev/null 2>&1; then
        die "openssl is required to generate the OIDC RSA private key. Please install openssl."
    fi
    openssl genrsa -out "$keyfile" 2048 2>/dev/null
    log "Generated RSA private key at $keyfile"
}

ensure_config_target_is_file() {
    local target="$1"
    if [ -d "$target" ]; then
        if [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
            rmdir "$target"
            log "Removed empty directory at $target to restore file path"
        else
            backup_dir="${target}.dir.bak.$(date +%Y%m%d-%H%M%S)"
            mv "$target" "$backup_dir"
            log "Moved directory $target to $backup_dir to restore file path"
        fi
    fi
}

main() {
    # Load .env if variables are not already set
    if [ -f "$ENV_FILE" ]; then
        HOST_NAME="${HOST_NAME:-$(grep '^HOST_NAME=' "$ENV_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '\r' || true)}"
        DATA_LOCATION="${DATA_LOCATION:-$(grep '^DATA_LOCATION=' "$ENV_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '\r' || true)}"
        PASSWORD="${PASSWORD:-$(grep '^PASSWORD=' "$ENV_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '\r' || true)}"
    fi

    HOST_NAME="${HOST_NAME:-pi.lan}"
    DATA_LOCATION="${DATA_LOCATION:-./data}"
    # Resolve DATA_LOCATION relative to PROJECT_DIR
    case "$DATA_LOCATION" in
        /*) : ;;
        *)  DATA_LOCATION="$PROJECT_DIR/$DATA_LOCATION" ;;
    esac

    if [ -z "$PASSWORD" ]; then
        die "PASSWORD is not set in .env"
    fi

    AUTHELIA_DATA_DIR="$DATA_LOCATION/authelia-config"
    CONFIG_FILE="$AUTHELIA_DATA_DIR/configuration.yml"
    SECRETS_DIR="$DATA_LOCATION/authelia-config/secrets"
    mkdir -p "$AUTHELIA_DATA_DIR"
    mkdir -p "$SECRETS_DIR"
    safe_chmod 700 "$SECRETS_DIR"

    # Generate Authelia secrets (idempotent: skip if file already exists)
    for secret in jwt_secret session_secret storage_encryption_key oidc_hmac_secret; do
        if [ ! -f "$SECRETS_DIR/$secret" ]; then
            generate_secret > "$SECRETS_DIR/$secret"
            safe_chmod 600 "$SECRETS_DIR/$secret"
            log "Generated $secret"
        fi
    done

    # LDAP bind password = lldap admin password = PASSWORD
    if [ ! -f "$SECRETS_DIR/ldap_password" ]; then
        printf '%s' "$PASSWORD" > "$SECRETS_DIR/ldap_password"
        safe_chmod 600 "$SECRETS_DIR/ldap_password"
        log "Written ldap_password"
    fi

    # Authelia postgres password = PASSWORD
    if [ ! -f "$SECRETS_DIR/db_password" ]; then
        printf '%s' "$PASSWORD" > "$SECRETS_DIR/db_password"
        safe_chmod 600 "$SECRETS_DIR/db_password"
        log "Written db_password"
    fi

    # Generate OIDC RSA private key
    if [ ! -f "$SECRETS_DIR/oidc_private_key.pem" ]; then
        generate_rsa_key "$SECRETS_DIR/oidc_private_key.pem"
        safe_chmod 600 "$SECRETS_DIR/oidc_private_key.pem"
    fi

    # Generate OIDC client secrets
    if [ ! -f "$SECRETS_DIR/oidc_nextcloud_secret.txt" ]; then
        generate_secret > "$SECRETS_DIR/oidc_nextcloud_secret.txt"
        safe_chmod 600 "$SECRETS_DIR/oidc_nextcloud_secret.txt"
        log "Generated oidc_nextcloud_secret"
    fi

    if [ ! -f "$SECRETS_DIR/oidc_immich_secret.txt" ]; then
        generate_secret > "$SECRETS_DIR/oidc_immich_secret.txt"
        safe_chmod 600 "$SECRETS_DIR/oidc_immich_secret.txt"
        log "Generated oidc_immich_secret"
    fi

    if [ ! -f "$SECRETS_DIR/oidc_beszel_secret.txt" ]; then
        generate_secret > "$SECRETS_DIR/oidc_beszel_secret.txt"
        safe_chmod 600 "$SECRETS_DIR/oidc_beszel_secret.txt"
        log "Generated oidc_beszel_secret"
    fi

    if [ ! -f "$SECRETS_DIR/oidc_headplane_secret.txt" ]; then
        generate_secret > "$SECRETS_DIR/oidc_headplane_secret.txt"
        safe_chmod 600 "$SECRETS_DIR/oidc_headplane_secret.txt"
        log "Generated oidc_headplane_secret"
    fi

    # Generate lldap JWT secret (stored in lldap data dir for lldap service)
    LLDAP_DATA_DIR="$DATA_LOCATION/lldap"
    mkdir -p "$LLDAP_DATA_DIR"
    LLDAP_ENV_FILE="$LLDAP_DATA_DIR/lldap.env"
    if [ ! -f "$LLDAP_ENV_FILE" ]; then
        LLDAP_JWT_SECRET=$(generate_secret)
        printf 'LLDAP_JWT_SECRET=%s\n' "$LLDAP_JWT_SECRET" > "$LLDAP_ENV_FILE"
        safe_chmod 600 "$LLDAP_ENV_FILE"
        log "Generated lldap JWT secret at $LLDAP_ENV_FILE"
    fi

    # Render configuration.yml from template
    if [ ! -f "$CONFIG_TEMPLATE" ]; then
        die "Authelia config template not found at $CONFIG_TEMPLATE"
    fi

    ensure_config_target_is_file "$CONFIG_FILE"

    TMP_RENDERED="$(mktemp)"
    TMP_KEY_INDENTED="$(mktemp)"
    trap 'rm -f "$TMP_RENDERED" "$TMP_KEY_INDENTED"' EXIT INT TERM

    sed -e "s|__HOST_NAME__|$HOST_NAME|g" "$CONFIG_TEMPLATE" > "$TMP_RENDERED"
    sed 's/^/          /' "$SECRETS_DIR/oidc_private_key.pem" > "$TMP_KEY_INDENTED"

    RENDERED=$(awk -v key_file="$TMP_KEY_INDENTED" '
        $0 == "__OIDC_PRIVATE_KEY__" {
            while ((getline line < key_file) > 0) print line
            close(key_file)
            next
        }
        { print }
    ' "$TMP_RENDERED")

    rm -f "$TMP_RENDERED" "$TMP_KEY_INDENTED"
    trap - EXIT INT TERM

    if [ -f "$CONFIG_FILE" ] && [ "$RENDERED" = "$(cat "$CONFIG_FILE")" ]; then
        log "configuration.yml already up to date"
    else
        printf '%s\n' "$RENDERED" > "$CONFIG_FILE"
        log "Rendered configuration.yml to $CONFIG_FILE"
    fi

    if [ ! -f "$IMMICH_OAUTH_TEMPLATE" ]; then
        die "Immich OAuth config template not found at $IMMICH_OAUTH_TEMPLATE"
    fi

    IMMICH_OAUTH_CONFIG_FILE="$AUTHELIA_DATA_DIR/immich-oauth-config.yaml"
    IMMICH_OAUTH_SECRET="$(cat "$SECRETS_DIR/oidc_immich_secret.txt")"
    IMMICH_OAUTH_RENDERED=$(sed \
        -e "s|__HOST_NAME__|$HOST_NAME|g" \
        -e "s|__OIDC_IMMICH_SECRET__|$IMMICH_OAUTH_SECRET|g" \
        "$IMMICH_OAUTH_TEMPLATE")

    if [ -f "$IMMICH_OAUTH_CONFIG_FILE" ] && [ "$IMMICH_OAUTH_RENDERED" = "$(cat "$IMMICH_OAUTH_CONFIG_FILE")" ]; then
        log "immich-oauth-config.yaml already up to date"
    else
        printf '%s\n' "$IMMICH_OAUTH_RENDERED" > "$IMMICH_OAUTH_CONFIG_FILE"
        safe_chmod 600 "$IMMICH_OAUTH_CONFIG_FILE"
        log "Rendered immich-oauth-config.yaml to $IMMICH_OAUTH_CONFIG_FILE"
    fi

    _fix_ownership "$SECRETS_DIR"
    _fix_ownership "$AUTHELIA_DATA_DIR"
    _fix_ownership "$LLDAP_DATA_DIR"

    log "Authelia pre-start complete"
}

main "$@"
