#!/bin/sh
# Bring Audiobookshelf up to a usable state without anyone touching its setup
# wizard: create the root account, point it at Authelia over OIDC, and add the
# audiobook library.
#
# A post-start hook (scripts/stack-up.sh). Idempotent and best-effort: every step
# checks the current state first, and a failure warns rather than failing the
# stack start.
#
# Audiobookshelf keeps all of this in its own SQLite database and exposes no way
# to seed it from the environment or a config file, so the API is the only door -
# and the API needs an account, which is why /init comes first.

set -eu

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=60
RETRY_INTERVAL=2
ABS_CONTAINER="${ABS_CONTAINER:-pi-audiobookshelf}"
ABS_URL="${ABS_URL:-http://pi-audiobookshelf}"
AUTHELIA_CONTAINER="${AUTHELIA_CONTAINER:-pi-authelia}"
LIBRARY_NAME="Audiobooks"
LIBRARY_PATH="/audiobooks"

abs_get() {
    docker_curl -H "Authorization: Bearer $TOKEN" "$ABS_URL$1"
}

# abs_send <method> <path> ; JSON body on stdin.
abs_send() {
    docker_curl_stdin -X "$1" \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        "$ABS_URL$2"
}

# --- Root account -----------------------------------------------------------

# /init is the only unauthenticated write in the whole API, and it refuses to run
# once a root user exists - so this is safe to call blind, but /status says so
# without a write attempt.
ensure_root_user() {
    local status="" user="" password=""

    status="$(docker_curl "$ABS_URL/status" 2>/dev/null)" || {
        log "WARNING: could not read Audiobookshelf /status; skipping"
        return 1
    }

    if [ "$(printf '%s' "$status" | jq -r '.isInit // false')" = "true" ]; then
        return 0
    fi

    user="$(get_env_value ADMIN_USER)"
    password="$(get_env_value PASSWORD)"
    [ -n "$user" ] && [ -n "$password" ] || {
        log "WARNING: ADMIN_USER/PASSWORD not set; cannot create the Audiobookshelf root account"
        return 1
    }

    jq -cn --arg u "$user" --arg p "$password" '{newRoot: {username: $u, password: $p}}' \
        | docker_curl_stdin -X POST -H 'Content-Type: application/json' "$ABS_URL/init" >/dev/null 2>&1 || {
        log "WARNING: Audiobookshelf /init failed"
        return 1
    }

    log "Created the Audiobookshelf root account '$user'"
}

# The root account is created with a username and a password and nothing else, so
# it carries no email - and email is what OIDC logins are matched against below.
# Without this the admin would sign in through Authelia and land on a *second*,
# plain-user account instead of the one that can reach the settings pages.
ensure_root_email() {
    local email="" me="" id="" current=""

    email="$(get_env_value EMAIL)"
    [ -n "$email" ] || return 0

    me="$(abs_get "/api/me" 2>/dev/null)" || return 0
    id="$(printf '%s' "$me" | jq -r '.id // empty')"
    current="$(printf '%s' "$me" | jq -r '.email // empty')"
    [ -n "$id" ] || return 0

    [ "$current" = "$email" ] && return 0

    jq -cn --arg e "$email" '{email: $e}' | abs_send PATCH "/api/users/$id" >/dev/null 2>&1 \
        || { log "WARNING: could not set the root account's email"; return 0; }
    log "Set the Audiobookshelf root account's email to $email"
}

# --- OIDC -------------------------------------------------------------------

# Authelia's own discovery document, so a path it moves is followed rather than
# guessed. Read from inside the container over loopback: the URLs it returns are
# built from the forwarded host, and a plain call to :9091 would answer with none
# at all. Falls back to the documented paths, which have not moved in years.
authelia_endpoints() {
    local host_name="$1" discovery=""

    discovery="$(docker exec "$AUTHELIA_CONTAINER" sh -c \
        "wget -qO- --header='X-Forwarded-Proto: https' --header='X-Forwarded-Host: auth.${host_name}' http://127.0.0.1:9091/.well-known/openid-configuration" 2>/dev/null)" || discovery=""

    if printf '%s' "$discovery" | jq -e '.issuer and .authorization_endpoint and .token_endpoint and .userinfo_endpoint and .jwks_uri' >/dev/null 2>&1; then
        printf '%s' "$discovery"
        return 0
    fi

    log "WARNING: could not read Authelia's discovery document; using the default endpoint paths"
    jq -cn --arg base "https://auth.${host_name}" '{
        issuer: $base,
        authorization_endpoint: ($base + "/api/oidc/authorization"),
        token_endpoint: ($base + "/api/oidc/token"),
        userinfo_endpoint: ($base + "/api/oidc/userinfo"),
        jwks_uri: ($base + "/jwks.json")
    }'
}

configure_oidc() {
    local host_name="" secret="" endpoints="" current="" desired=""

    host_name="$(get_env_value HOST_NAME)"
    host_name="${host_name:-pi.lan}"

    ensure_authelia_oidc_materials "audiobookshelf" "Audiobookshelf" "$MAX_RETRIES" "$RETRY_INTERVAL" || {
        log "WARNING: Audiobookshelf OIDC prerequisites are missing in Authelia; skipping"
        return 0
    }

    secret="$(get_oidc_secret "audiobookshelf")" || {
        log "WARNING: could not read the Audiobookshelf OIDC client secret; skipping"
        return 0
    }
    [ -n "$secret" ] || { log "WARNING: the Audiobookshelf OIDC client secret is empty; skipping"; return 0; }

    endpoints="$(authelia_endpoints "$host_name")"

    current="$(abs_get "/api/auth-settings" 2>/dev/null)" || {
        log "WARNING: could not read Audiobookshelf auth settings; skipping"
        return 0
    }

    # authOpenIDSubfolderForRedirectURLs is the empty string on purpose, not
    # merely absent: Audiobookshelf interpolates it into the redirect_uri
    # unguarded, so leaving it undefined builds "undefined/auth/openid/callback"
    # and every login fails on a redirect_uri mismatch.
    #
    # authOpenIDGroupClaim stays empty for the reason spelled out beside the
    # Authelia client: the claim is read as a role, and a user in none of
    # admin/user/guest is denied outright. Only `admin` exists in this stack.
    desired="$(printf '%s' "$current" | jq -c \
        --argjson e "$endpoints" \
        --arg secret "$secret" \
        '. + {
            authActiveAuthMethods: ["local", "openid"],
            authOpenIDIssuerURL: $e.issuer,
            authOpenIDAuthorizationURL: $e.authorization_endpoint,
            authOpenIDTokenURL: $e.token_endpoint,
            authOpenIDUserInfoURL: $e.userinfo_endpoint,
            authOpenIDJwksURL: $e.jwks_uri,
            authOpenIDLogoutURL: ($e.end_session_endpoint // null),
            authOpenIDClientID: "audiobookshelf",
            authOpenIDClientSecret: $secret,
            authOpenIDTokenSigningAlgorithm: "RS256",
            authOpenIDButtonText: "Sign in with SSO",
            authOpenIDAutoRegister: true,
            authOpenIDMatchExistingBy: "email",
            authOpenIDSubfolderForRedirectURLs: "",
            authOpenIDGroupClaim: "",
            authOpenIDAdvancedPermsClaim: ""
         }')"

    if [ "$(printf '%s' "$current" | jq -S .)" = "$(printf '%s' "$desired" | jq -S .)" ]; then
        log "Audiobookshelf OIDC already configured"
        return 0
    fi

    printf '%s' "$desired" | abs_send PATCH "/api/auth-settings" >/dev/null 2>&1 || {
        log "WARNING: updating Audiobookshelf auth settings failed"
        return 0
    }
    log "Configured Audiobookshelf OIDC against https://auth.${host_name}"
}

# --- Library ----------------------------------------------------------------

# Audible is the only metadata source here that actually carries audio editions
# (narrator, runtime, chapters), and it is regional - a French catalogue is
# invisible from audible.com. Derived from DEFAULT_LANGUAGE so moving the stack
# to another language needs no Audiobookshelf knowledge; anything with no Audible
# storefront falls back to the .com one.
audible_provider() {
    local tag="" lang="" region=""

    tag="$(get_env_value DEFAULT_LANGUAGE)"
    lang="$(printf '%s' "${tag%%-*}" | tr '[:upper:]' '[:lower:]')"
    region="$(printf '%s' "${tag#*-}" | tr '[:lower:]' '[:upper:]')"

    case "$lang" in
        fr) printf 'audible.fr' ;;
        de) printf 'audible.de' ;;
        it) printf 'audible.it' ;;
        es) printf 'audible.es' ;;
        ja) printf 'audible.jp' ;;
        en)
            case "$region" in
                GB|UK) printf 'audible.uk' ;;
                CA)    printf 'audible.ca' ;;
                AU)    printf 'audible.au' ;;
                IN)    printf 'audible.in' ;;
                *)     printf 'audible' ;;
            esac
            ;;
        *) printf 'audible' ;;
    esac
}

# Seeded, not reconciled: the folder list, the scanner settings and the metadata
# provider are all things the owner is expected to tune in the UI afterwards, and
# rewriting them on every boot would undo that.
ensure_library() {
    local libraries="" existing=""

    libraries="$(abs_get "/api/libraries" 2>/dev/null)" || {
        log "WARNING: could not list Audiobookshelf libraries; skipping"
        return 0
    }

    existing="$(printf '%s' "$libraries" | jq -r --arg p "$LIBRARY_PATH" \
        '.libraries[]? | select([.folders[]?.fullPath] | index($p)) | .name' 2>/dev/null || true)"
    if [ -n "$existing" ]; then
        log "Audiobookshelf library '$existing' already covers $LIBRARY_PATH"
        return 0
    fi

    jq -cn --arg name "$LIBRARY_NAME" --arg path "$LIBRARY_PATH" --arg provider "$(audible_provider)" \
        '{name: $name, folders: [{fullPath: $path}], mediaType: "book", provider: $provider, icon: "audiobookshelf"}' \
        | abs_send POST "/api/libraries" >/dev/null 2>&1 || {
        log "WARNING: creating the Audiobookshelf library failed"
        return 0
    }
    log "Created the Audiobookshelf library '$LIBRARY_NAME' on $LIBRARY_PATH ($(audible_provider))"
}

main() {
    log "=== Audiobookshelf Bootstrap ==="

    [ -f "$ENV_FILE" ] || die ".env missing at $ENV_FILE"

    container_is_running "$ABS_CONTAINER" || { log "Audiobookshelf is not running; skipping"; return 0; }
    wait_for_http_endpoint "$ABS_URL/healthcheck" "Audiobookshelf HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || return 0

    ensure_root_user || return 0

    TOKEN="$(audiobookshelf_token "$ABS_URL" || true)"
    [ -n "${TOKEN:-}" ] || { log "WARNING: could not log in to Audiobookshelf; skipping the rest"; return 0; }

    ensure_root_email
    configure_oidc
    ensure_library

    log "Audiobookshelf bootstrap complete"
}

main "$@"
