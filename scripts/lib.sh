#!/bin/sh
# Shared library for pi-pcloud scripts.
# Source with: . "$(dirname "$0")/lib.sh"

# --- Project paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0" .sh)}"

# --- Logging ---

log() {
    echo "[$SCRIPT_NAME] $(date '+%H:%M:%S') $*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# --- Environment helpers ---

# Read a KEY=value from a dotenv-style file.
read_env_value_from_file() {
    local file="$1"
    local key="$2"

    if [ ! -f "$file" ]; then
        return 0
    fi

    grep "^$key=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

# Read a value from the project .env file.
get_env_value() {
    read_env_value_from_file "$ENV_FILE" "$1"
}

# --- Data location ---

resolve_data_location_path() {
    local data_location

    data_location="$(get_env_value DATA_LOCATION)"
    [ -n "$data_location" ] || data_location="./data"

    case "$data_location" in
        /*) printf '%s' "$data_location" ;;
        *) printf '%s/%s' "$PROJECT_DIR" "$data_location" ;;
    esac
}

# --- Permissions ---

safe_chmod() {
    local mode="$1"
    local path="$2"
    if ! chmod "$mode" "$path" 2>/dev/null; then
        log "WARNING: could not chmod $mode $path (insufficient permissions?)"
    fi
}

# Fix ownership of a path to match the project directory owner so non-root
# users can still read generated files after a root-run systemd start.
fix_ownership() {
    local _owner
    _owner=$(stat -c '%u:%g' "$PROJECT_DIR" 2>/dev/null || true)
    if [ -n "$_owner" ] && [ "$_owner" != "0:0" ]; then
        chown -R "$_owner" "$1" 2>/dev/null || true
    fi
}

# --- Secret generation ---

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        log "WARNING: openssl not found; falling back to /dev/urandom"
        head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n'
    fi
}

# Hash a plaintext secret using PBKDF2-SHA512 (Authelia's default format).
# Requires python3 with hashlib (stdlib).
hash_pbkdf2() {
    local plaintext="$1"
    python3 -c "
import hashlib, os, base64, sys
pw = sys.argv[1].encode()
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha512', pw, salt, 310000)
s = base64.b64encode(salt).rstrip(b'=').decode().replace('+','.')
d = base64.b64encode(dk).rstrip(b'=').decode().replace('+','.')
print(f'\$pbkdf2-sha512\$310000\${s}\${d}')
" "$plaintext"
}

# --- Container helpers ---

# Wait for a Docker container to appear by name.
# Usage: wait_for_container <name> [max_retries] [interval_seconds]
wait_for_container() {
    local name="$1"
    local max_retries="${2:-120}"
    local interval="${3:-2}"

    log "Waiting for $name container to appear..."
    for i in $(seq 1 "$max_retries"); do
        if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
            log "$name container is running"
            return 0
        fi
        sleep "$interval"
    done
    log "ERROR: $name container did not start in time"
    return 1
}

# Wait for a Docker container to report healthy status.
# Usage: wait_for_health <name> [max_retries] [interval_seconds]
wait_for_health() {
    local name="$1"
    local max_retries="${2:-120}"
    local interval="${3:-2}"
    local status

    log "Waiting for $name health status..."
    for i in $(seq 1 "$max_retries"); do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)
        if [ "$status" = "healthy" ]; then
            log "$name container is healthy"
            return 0
        fi
        sleep "$interval"
    done
    log "ERROR: $name container did not become healthy in time"
    return 1
}

container_is_running() {
    local name="$1"
    docker ps --format '{{.Names}}' | grep -q "^${name}$"
}

# Wait for a Docker container health status, but warn instead of hard-failing logs.
# Usage: wait_for_health_warning <name> [max_retries] [interval_seconds]
wait_for_health_warning() {
    local name="$1"
    local max_retries="${2:-120}"
    local interval="${3:-2}"
    local status

    for i in $(seq 1 "$max_retries"); do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)
        if [ "$status" = "healthy" ]; then
            log "$name container is healthy"
            return 0
        fi
        sleep "$interval"
    done

    log "WARNING: Timed out waiting for $name health"
    return 1
}

authelia_container_has_oidc_materials() {
    local client_id="$1"

    if ! container_is_running "pi-authelia"; then
        return 1
    fi

    (cd "$PROJECT_DIR" && docker compose exec -T authelia sh -ec "[ -r /config/secrets/oidc_${client_id}_secret.txt ] && grep -q \"client_id: ${client_id}\" /config/configuration.yml" >/dev/null 2>&1)
}

# Ensure Authelia OIDC secret + client stanza exist for a client.
# Usage: ensure_authelia_oidc_materials <client_id> <display_name> [max_retries] [interval_seconds]
ensure_authelia_oidc_materials() {
    local client_id="$1"
    local display_name="$2"
    local max_retries="${3:-120}"
    local interval="${4:-2}"
    local data_root config_file secret_file pre_start_script

    [ -n "$client_id" ] || {
        log "ERROR: Missing client_id for ensure_authelia_oidc_materials"
        return 1
    }

    [ -n "$display_name" ] || display_name="$client_id"

    data_root="$(resolve_data_location_path)"
    config_file="$data_root/authelia-config/configuration.yml"
    secret_file="$data_root/authelia-config/secrets/oidc_${client_id}_secret.txt"
    pre_start_script="$PROJECT_DIR/scripts/authelia-pre-start.sh"

    if [ -r "$secret_file" ] && [ -f "$config_file" ] && grep -q "client_id: ${client_id}" "$config_file" 2>/dev/null; then
        return 0
    fi

    if authelia_container_has_oidc_materials "$client_id"; then
        return 0
    fi

    log "Detected missing ${display_name} OIDC materials in Authelia config data"

    if [ ! -f "$pre_start_script" ]; then
        log "WARNING: Missing $pre_start_script; cannot auto-heal Authelia OIDC materials"
        return 1
    fi

    if ! sh "$pre_start_script"; then
        log "WARNING: authelia-pre-start.sh failed while preparing ${display_name} OIDC materials"
        return 1
    fi

    if container_is_running "pi-authelia"; then
        log "Restarting Authelia to apply OIDC client updates"
        if (cd "$PROJECT_DIR" && docker compose restart authelia >/dev/null); then
            wait_for_health_warning "pi-authelia" "$max_retries" "$interval" || true
        else
            log "WARNING: Failed to restart Authelia automatically"
        fi
    fi

    if [ ! -r "$secret_file" ] || [ ! -f "$config_file" ] || ! grep -q "client_id: ${client_id}" "$config_file" 2>/dev/null; then
        if authelia_container_has_oidc_materials "$client_id"; then
            return 0
        fi
        log "WARNING: ${display_name} OIDC materials are still missing after regeneration attempt"
        return 1
    fi

    return 0
}

# --- OIDC secret retrieval ---

# Retrieve an OIDC client secret with 3-method fallback:
#   1. Explicit env var (if env_var_name provided)
#   2. Plaintext file on disk at authelia-config/secrets/
#   3. Docker exec into Authelia container
# Usage: get_oidc_secret <client_name> [env_var_name]
get_oidc_secret() {
    local client_name="$1"
    local env_var_name="${2:-}"
    local secret_value data_root secret_file

    # 1. Explicit env var override
    if [ -n "$env_var_name" ]; then
        secret_value="$(eval "printf '%s' \"\${$env_var_name:-}\"")"
        [ -z "$secret_value" ] && secret_value="$(get_env_value "$env_var_name")"
        if [ -n "$secret_value" ]; then
            printf '%s' "$secret_value"
            return 0
        fi
    fi

    # 2. File on disk
    data_root="$(resolve_data_location_path)"
    secret_file="$data_root/authelia-config/secrets/oidc_${client_name}_secret.txt"
    if [ -r "$secret_file" ]; then
        tr -d '\r\n' < "$secret_file"
        return 0
    fi

    # 3. Docker container fallback
    secret_value="$(cd "$PROJECT_DIR" && docker compose exec -T authelia sh -ec "cat /config/secrets/oidc_${client_name}_secret.txt" 2>/dev/null | tr -d '\r\n')"
    if [ -n "$secret_value" ]; then
        printf '%s' "$secret_value"
        return 0
    fi

    return 1
}

# --- Docker API helpers ---

# Run curl via a temporary Docker container on the frontend network.
docker_curl() {
    local curl_image="${CURL_IMAGE:-curlimages/curl:8.12.1}"
    docker run --rm --network frontend "$curl_image" -fsS "$@"
}

# Wait for an HTTP endpoint reachable from the frontend Docker network.
# Usage: wait_for_http_endpoint <url> <name> [max_retries] [interval_seconds]
wait_for_http_endpoint() {
    local url="$1"
    local name="$2"
    local max_retries="${3:-120}"
    local interval="${4:-2}"

    [ -n "$name" ] || name="$url"

    log "Waiting for $name..."
    for i in $(seq 1 "$max_retries"); do
        if docker_curl "$url" >/dev/null 2>&1; then
            log "$name is reachable"
            return 0
        fi
        sleep "$interval"
    done

    log "ERROR: $name did not become reachable"
    return 1
}

# API helpers for endpoints using cookie-based auth.
# Usage: api_get_with_cookie <base_url> <path> [cookie]
api_get_with_cookie() {
    local base_url="$1"
    local path="$2"
    local cookie="${3:-}"

    if [ -n "$cookie" ]; then
        docker_curl -H "Cookie: $cookie" "$base_url$path"
    else
        docker_curl "$base_url$path"
    fi
}

# Usage: api_post_json_with_cookie <base_url> <path> <payload> [cookie]
api_post_json_with_cookie() {
    local base_url="$1"
    local path="$2"
    local payload="$3"
    local cookie="${4:-}"

    if [ -n "$cookie" ]; then
        docker_curl -X POST \
            -H "Cookie: $cookie" \
            -H 'Content-Type: application/json' \
            -d "$payload" \
            "$base_url$path"
    else
        docker_curl -X POST \
            -H 'Content-Type: application/json' \
            -d "$payload" \
            "$base_url$path"
    fi
}

# Usage: api_put_json_with_cookie <base_url> <path> <payload> [cookie]
api_put_json_with_cookie() {
    local base_url="$1"
    local path="$2"
    local payload="$3"
    local cookie="${4:-}"

    if [ -n "$cookie" ]; then
        docker_curl -X PUT \
            -H "Cookie: $cookie" \
            -H 'Content-Type: application/json' \
            -d "$payload" \
            "$base_url$path"
    else
        docker_curl -X PUT \
            -H 'Content-Type: application/json' \
            -d "$payload" \
            "$base_url$path"
    fi
}

# --- Utilities ---

is_truthy() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

normalize_json() {
    if [ -z "${1:-}" ]; then
        printf '[]'
        return 0
    fi

    printf '%s' "$1" | jq -c 'if type == "array" then sort else . end'
}

# --- Generic service readiness ---

# Wait for a service by retrying an arbitrary check command.
# Usage: wait_for_service <name> <check_cmd> [max_retries] [interval_seconds]
# The check_cmd is evaluated via `eval` and should return 0 when the service is ready.
wait_for_service() {
    local name="$1"
    local check_cmd="$2"
    local max_retries="${3:-120}"
    local interval="${4:-2}"

    log "Waiting for $name to be ready..."
    for _i in $(seq 1 "$max_retries"); do
        if eval "$check_cmd" >/dev/null 2>&1; then
            log "$name is ready"
            return 0
        fi
        sleep "$interval"
    done

    log "ERROR: $name did not become ready in time"
    return 1
}

# --- Username candidate list ---

# Build a space-separated fallback username list from .env (EMAIL, USER, admin).
# Both Portainer and Dockhand use this pattern for authentication attempts.
# Usage: build_username_candidates
# Outputs the list to stdout.
build_username_candidates() {
    local usernames candidate

    usernames="$(get_env_value EMAIL)"
    candidate="$(get_env_value USER)"
    if [ -n "$candidate" ] && [ "$candidate" != "$usernames" ]; then
        usernames="${usernames:+$usernames }$candidate"
    fi
    if [ -z "$usernames" ]; then
        usernames="admin"
    else
        case " $usernames " in
            *" admin "*) ;;
            *) usernames="$usernames admin" ;;
        esac
    fi

    printf '%s' "$usernames"
}

# --- OIDC client setup ---

# One-shot OIDC client setup: ensure Authelia materials exist and return the secret.
# Usage: configure_oidc_client <client_id> <display_name> [env_var_name] [max_retries] [interval]
# Prints the plaintext client secret to stdout.
configure_oidc_client() {
    local client_id="$1"
    local display_name="$2"
    local env_var_name="${3:-}"
    local max_retries="${4:-120}"
    local interval="${5:-2}"

    ensure_authelia_oidc_materials "$client_id" "$display_name" "$max_retries" "$interval" || {
        log "ERROR: Failed to ensure Authelia OIDC materials for $display_name"
        return 1
    }

    get_oidc_secret "$client_id" "$env_var_name" || {
        log "ERROR: Could not retrieve OIDC client secret for $display_name"
        return 1
    }
}

# Generate standard Authelia OIDC endpoint URLs for a given host.
# Sets shell variables: OIDC_ISSUER, OIDC_AUTH_URL, OIDC_TOKEN_URL,
# OIDC_USERINFO_URL, OIDC_LOGOUT_URL, OIDC_DISCOVERY_URL.
# Usage: build_authelia_oidc_urls <host_name>
build_authelia_oidc_urls() {
    local host="$1"
    local auth_base="https://auth.${host}"

    OIDC_ISSUER="$auth_base"
    OIDC_AUTH_URL="${auth_base}/api/oidc/authorization"
    OIDC_TOKEN_URL="${auth_base}/api/oidc/token"
    OIDC_USERINFO_URL="${auth_base}/api/oidc/userinfo"
    OIDC_LOGOUT_URL="${auth_base}/logout"
    OIDC_DISCOVERY_URL="${auth_base}/.well-known/openid-configuration"
}

# --- SMTP configuration ---

# Read SMTP settings from .env into shell variables.
# Sets: SMTP_HOST, SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, SMTP_TLS.
# Returns 1 if SMTP_HOST is not set (SMTP not configured).
# Usage: configure_smtp_env
configure_smtp_env() {
    SMTP_HOST="$(get_env_value SMTP_HOST)"
    [ -n "$SMTP_HOST" ] || return 1

    SMTP_PORT="$(get_env_value SMTP_PORT)"
    SMTP_PORT="${SMTP_PORT:-587}"
    SMTP_USERNAME="$(get_env_value SMTP_USERNAME)"
    SMTP_PASSWORD="$(get_env_value SMTP_PASSWORD)"
    # Implicit TLS on port 465, STARTTLS on 587
    if [ "$SMTP_PORT" = "465" ]; then
        SMTP_TLS="true"
    else
        SMTP_TLS="false"
    fi
}

# --- S3 configuration ---

# Read S3 settings from .env into shell variables.
# Sets: S3_ENDPOINT, S3_BUCKET, S3_REGION, S3_ACCESS_KEY, S3_SECRET_KEY.
# Returns 1 if S3_ENDPOINT or S3_BUCKET is not set.
# Usage: configure_s3_env
configure_s3_env() {
    S3_ENDPOINT="$(get_env_value S3_ENDPOINT)"
    S3_BUCKET="$(get_env_value S3_BUCKET)"
    [ -n "$S3_ENDPOINT" ] && [ -n "$S3_BUCKET" ] || return 1

    S3_REGION="$(get_env_value S3_REGION)"
    S3_ACCESS_KEY="$(get_env_value S3_ACCESS_KEY_ID)"
    S3_SECRET_KEY="$(get_env_value S3_SECRET_ACCESS_KEY)"
}

# --- Ntfy credentials ---

# Read ntfy credentials for a given service from the ntfy env file.
# Usage: get_ntfy_credentials <ntfy_env_file> <service_name> <default_topic>
# Sets: NTFY_SERVICE_PASSWORD, NTFY_SERVICE_TOPIC.
# Returns 1 if the password is not set.
get_ntfy_credentials() {
    local ntfy_env_file="$1"
    local service_name="$2"
    local default_topic="${3:-pi}"
    local password_key topic_key

    if [ ! -f "$ntfy_env_file" ]; then
        log "WARNING: $ntfy_env_file not found"
        return 1
    fi

    password_key="NTFY_$(printf '%s' "$service_name" | tr '[:lower:]' '[:upper:]')_PASSWORD"
    topic_key="NTFY_$(printf '%s' "$service_name" | tr '[:lower:]' '[:upper:]')_TOPIC"

    NTFY_SERVICE_PASSWORD="$(read_env_value_from_file "$ntfy_env_file" "$password_key")"
    [ -n "$NTFY_SERVICE_PASSWORD" ] || return 1

    NTFY_SERVICE_TOPIC="$(read_env_value_from_file "$ntfy_env_file" "$topic_key")"
    [ -n "$NTFY_SERVICE_TOPIC" ] || NTFY_SERVICE_TOPIC="$default_topic"
}
