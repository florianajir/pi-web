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

# Docker Compose's .env parser mangles more than `$VAR` interpolation: a
# trailing backslash escapes the newline, an unquoted value is truncated at
# whitespace-then-`#` (inline comment), surrounding quotes are stripped and
# leading/trailing whitespace is trimmed — while these scripts read .env
# verbatim (read_env_value_from_file below), so any of those would hand the
# services and the scripts two different values. install.sh refuses them at
# the prompt and the Makefile's check-env re-checks the file; both call this
# function so the two cannot drift. A mid-value backslash is fine (Compose
# passes it through verbatim), only a trailing one escapes the newline.
# Newlines can only arrive from a pre-exported value; ENV_LF is a literal
# newline because $(...) strips trailing ones.
ENV_LF='
'
# shellcheck disable=SC2034 # read by install.sh and the Makefile's check-env
ENV_VALUE_RULES="must not contain '\$', a newline or ' #', must not end with '\\', and must not start or end with a quote or whitespace (Docker Compose's .env parser mangles these)"

# shellcheck disable=SC1003 # '\' is a literal backslash pattern, not an escaped quote
env_value_is_safe() {
    case "$1" in
        *'$'* | *[[:space:]]'#'* | *'\' | \"* | *\" | \'* | *\' | *"$ENV_LF"*) return 1 ;;
        [[:space:]]* | *[[:space:]]) return 1 ;;
        *) return 0 ;;
    esac
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
    read_env_value_from_file "$ENV_FILE" "$1"
}

# Strip a trailing CR (a .env edited from Windows over Samba) and one layer of
# surrounding quotes — what Compose, systemd and run-if-enabled.sh all do to a
# value, and what get_env_value deliberately does not. Reading a list verbatim
# and writing it back is how a CR or a quote ends up *mid*-value, where it
# matches no profile at all while --remove-orphans deletes the containers.
unquote_env_value() {
    local value=""
    value="$(printf '%s' "$1" | tr -d '\r')"
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf '%s' "$value"
}

get_env_value_clean() {
    unquote_env_value "$(get_env_value "$1")"
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

# Run a generator and put its output at $1 only if it succeeded and produced
# something. `cmd > "$file"` truncates the target *before* cmd runs, so a
# generator that fails (missing python3, missing openssl, full disk) leaves an
# empty file behind — and every `[ ! -f "$file" ]` guard in this repo then
# treats that empty file as already generated, forever. The temp file is made
# next to the destination so the mv is atomic and inherits its directory mode.
# Usage: write_file_atomic <dest> <cmd> [args...]
write_file_atomic() {
    local dest="$1"
    shift
    local tmp=""
    # Docker creates a *directory* at a missing bind-mount source; mv into it
    # would succeed while the caller believes it wrote a file (the same trap
    # ensure_config_target_is_file exists for). Refuse it explicitly.
    if [ -d "$dest" ]; then
        log "ERROR: $dest is a directory (created by a bind mount?) - refusing to write a file there"
        return 1
    fi
    tmp="$(mktemp "${dest}.XXXXXX")" || return 1
    if "$@" > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$dest"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

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
# Passed through the environment rather than argv: argv is world-readable in
# the host's process table for the lifetime of the python3 call.
hash_pbkdf2() {
    PBKDF2_PLAINTEXT="$1" python3 -c "
import hashlib, os, base64
pw = os.environ['PBKDF2_PLAINTEXT'].encode()
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha512', pw, salt, 310000)
s = base64.b64encode(salt).rstrip(b'=').decode().replace('+','.')
d = base64.b64encode(dk).rstrip(b'=').decode().replace('+','.')
print(f'\$pbkdf2-sha512\$310000\${s}\${d}')
"
}

# --- Container helpers ---

compose() {
    (cd "$PROJECT_DIR" && docker compose "$@")
}

# Silent generic retry loop; the caller logs around it.
# Usage: wait_for_cmd <max_retries> <interval_seconds> <command...>
wait_for_cmd() {
    local max_retries="$1"
    local interval="$2"
    shift 2

    for i in $(seq 1 "$max_retries"); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
    done
    return 1
}

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

# Mint a 1-year Headscale API key. Headscale's json output moved the key
# between a bare string and an object across versions, hence the two parses.
create_headscale_api_key() {
    local raw_output api_key
    raw_output=$(docker exec pi-headscale "${HEADSCALE_BIN:-headscale}" apikeys create --expiration 8760h --output json 2>/dev/null | tr -d '\r\n')
    api_key=$(printf '%s' "$raw_output" | sed -n -E 's/^"([^"]+)"$/\1/p')
    if [ -z "$api_key" ]; then
        api_key=$(printf '%s' "$raw_output" | grep -oE '"(api_key|apiKey|key)"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/')
    fi
    printf '%s' "$api_key"
}

# Like wait_for_health, but a timeout is a warning rather than an error.
# Usage: wait_for_health_warning <name> [max_retries] [interval_seconds]
# Echo a Kavita admin's API key, or nothing. Read from kavita.db rather than the API
# because our own OIDC config sets DisablePasswordAuthentication, so there is no
# credential a script could log in with - and the one endpoint that works without a
# password (/api/Plugin/authenticate) needs this very key. Copied out with docker cp
# because the volume is not host-readable without root; the -wal file comes too, or a
# key created since the last checkpoint would be missed.
kavita_admin_api_key() {
    _kak_container="${1:-pi-kavita}"
    container_is_running "$_kak_container" || return 0

    _kak_tmp="$(mktemp -d)" || return 0
    docker cp "$_kak_container:/config/kavita.db" "$_kak_tmp/kavita.db" >/dev/null 2>&1 || {
        rm -rf "$_kak_tmp"
        return 0
    }
    docker cp "$_kak_container:/config/kavita.db-wal" "$_kak_tmp/kavita.db-wal" >/dev/null 2>&1 || true

    KAVITA_DB="$_kak_tmp/kavita.db" python3 - <<'PY' 2>/dev/null || true
import os, sqlite3, sys

# Kavita 0.9.x keeps API keys in AppUserAuthKey, not AspNetUsers.ApiKey (always NULL).
# Guard the whole thing: the schema is not stable across Kavita majors, and a widget
# key is never worth failing a boot over.
try:
    db = sqlite3.connect(f"file:{os.environ['KAVITA_DB']}?mode=ro", uri=True)
    row = db.execute("""
        select k.Key from AppUserAuthKey k
        join AspNetUserRoles ur on ur.UserId = k.AppUserId
        join AspNetRoles r on r.Id = ur.RoleId
        where r.Name = 'Admin' and k.Name = 'opds'
        order by k.AppUserId limit 1
    """).fetchone()
except Exception:
    sys.exit(0)

if row and row[0]:
    print(row[0], end="")
PY
    rm -rf "$_kak_tmp"
}

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

    compose exec -T authelia sh -ec "[ -r /config/secrets/oidc_${client_id}_secret.txt ] && grep -q \"client_id: ${client_id}\" /config/configuration.yml" >/dev/null 2>&1
}

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
        if compose restart authelia >/dev/null; then
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

# Falls back from the env var to the secret file on disk to a docker exec, so it
# works before the file exists on a fresh install and after the stack is up.
# Usage: get_oidc_secret <client_name> [env_var_name]
get_oidc_secret() {
    local client_name="$1"
    local env_var_name="${2:-}"
    local secret_value data_root secret_file

    if [ -n "$env_var_name" ]; then
        secret_value="$(eval "printf '%s' \"\${$env_var_name:-}\"")"
        [ -z "$secret_value" ] && secret_value="$(get_env_value "$env_var_name")"
        if [ -n "$secret_value" ]; then
            printf '%s' "$secret_value"
            return 0
        fi
    fi

    data_root="$(resolve_data_location_path)"
    secret_file="$data_root/authelia-config/secrets/oidc_${client_name}_secret.txt"
    if [ -r "$secret_file" ]; then
        tr -d '\r\n' < "$secret_file"
        return 0
    fi

    secret_value="$(compose exec -T authelia sh -ec "cat /config/secrets/oidc_${client_name}_secret.txt" 2>/dev/null | tr -d '\r\n')"
    if [ -n "$secret_value" ]; then
        printf '%s' "$secret_value"
        return 0
    fi

    return 1
}

# --- Docker API helpers ---

# A throwaway container, so no service needs curl installed to be probed.
docker_curl() {
    local curl_image="${CURL_IMAGE:-curlimages/curl:8.12.1}"
    docker run --rm --network frontend "$curl_image" -fsS "$@"
}

# Usage: wait_for_http_endpoint <url> <name> [max_retries] [interval_seconds]
wait_for_http_endpoint() {
    local url="$1"
    local name="$2"
    local max_retries="${3:-120}"
    local interval="${4:-2}"

    [ -n "$name" ] || name="$url"

    log "Waiting for $name..."
    # shellcheck disable=SC2034 # a countdown, the body does not need the index
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

# Escape a value for use as the replacement in a `sed "s|…|…|g"` render: a
# literal \, & or | would otherwise be interpreted (or terminate the
# expression) and corrupt the rendered config. Values read via get_env_value
# cannot contain newlines (it is line-based), so those need no handling.
sed_escape() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

is_truthy() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# Deduped, in the given priority order, always ending with "admin".
# Usage: build_candidate_usernames "$EMAIL" "$ADMIN_USER"
build_candidate_usernames() {
    local result="" candidate
    for candidate in "$@"; do
        [ -n "$candidate" ] || continue
        case " $result " in
            *" $candidate "*) ;;
            *) result="${result:+$result }$candidate" ;;
        esac
    done
    [ -n "$result" ] || result="admin"
    case " $result " in
        *" admin "*) ;;
        *) result="$result admin" ;;
    esac
    printf '%s' "$result"
}

normalize_json() {
    if [ -z "${1:-}" ]; then
        printf '[]'
        return 0
    fi

    printf '%s' "$1" | jq -c 'if type == "array" then sort else . end'
}
