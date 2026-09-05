#!/bin/sh
# Watch the Authelia container log for failed authentication attempts and publish
# them to ntfy. Runs as a long-lived host service (pi-pcloud-authelia-ntfy.service),
# so no extra container is needed.
#
# Authelia has no webhook/event notifier (its notifier is SMTP-only, for user mails),
# so the log stream is the integration point. Matched messages:
#   Unsuccessful <method> authentication attempt by user '<user>'
#   Unsuccessful <method> authentication attempt by user '<user>' and they are banned until <time>
#   Error occurred getting details for user with username input '<user>' which usually
#     indicates they do not exist
#   Access Request failed with error: <reason>
set -eu

. "$(dirname "$0")/lib.sh"

NTFY_ENV_FILE="${NTFY_ENV_FILE:-$PROJECT_DIR/config/ntfy/ntfy.env}"
AUTHELIA_CONTAINER="${AUTHELIA_CONTAINER:-pi-authelia}"
NTFY_CONTAINER="${NTFY_CONTAINER:-pi-ntfy}"
NTFY_USER="${AUTHELIA_NTFY_USER:-authelia}"
# Collapse identical (kind, user, ip) events inside this window to keep a browser
# retry loop or a slow brute-force from turning into a notification storm.
DEDUPE_WINDOW="${AUTHELIA_NTFY_DEDUPE_WINDOW:-60}"
# A client left holding a dead refresh token retries for as long as it is open -
# every few minutes, for days. An hour-wide window keeps that one fault to a
# handful of reminders instead of hundreds.
OIDC_DEDUPE_WINDOW="${AUTHELIA_NTFY_OIDC_DEDUPE_WINDOW:-3600}"
RECONNECT_DELAY="${AUTHELIA_NTFY_RECONNECT_DELAY:-10}"

# --- ntfy publishing ---

# Resolve the ntfy container address on any of its docker networks. Container IPs
# change on recreate, so this is resolved per publish rather than cached.
resolve_ntfy_address() {
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
        "$NTFY_CONTAINER" 2>/dev/null | awk '{print $1}'
}

# Usage: publish <title> <priority> <tags> <message>
publish() {
    _title="$1"
    _priority="$2"
    _tags="$3"
    _message="$4"
    _password="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_AUTHELIA_PASSWORD)"
    _topic="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_AUTHELIA_TOPIC)"
    [ -n "$_topic" ] || _topic="security"

    if [ -z "$_password" ]; then
        log "WARNING: NTFY_AUTHELIA_PASSWORD missing from $NTFY_ENV_FILE; skipping notification"
        return 0
    fi

    if [ -n "${NTFY_URL:-}" ]; then
        _base_url="${NTFY_URL%/}"
    else
        _address="$(resolve_ntfy_address)"
        if [ -z "$_address" ]; then
            log "WARNING: could not resolve $NTFY_CONTAINER address; skipping notification"
            return 0
        fi
        _base_url="http://$_address"
    fi

    # Credentials go in on stdin as a curl config file so they never appear in the
    # process table (unlike -u / -H on the command line).
    if printf 'user = "%s:%s"\n' "$NTFY_USER" "$_password" | curl -fsS -K - \
        --retry 3 --max-time 15 \
        -H "Title: $_title" \
        -H "Priority: $_priority" \
        -H "Tags: $_tags" \
        --data-binary "$_message" \
        "$_base_url/$_topic" >/dev/null 2>&1; then
        return 0
    fi

    log "WARNING: failed to publish notification to ntfy topic '$_topic'"
    return 0
}

# --- Log parsing ---

# Usage: field <sed-expression> <line>
field() {
    printf '%s\n' "$2" | sed -n "$1" | head -n1
}

# Usage: within_window <key> <now> <window> <last-key> <last-time>
within_window() {
    _w_key="$1"
    _w_now="$2"
    _w_window="$3"
    _w_last_key="$4"
    _w_last_time="$5"

    [ "$_w_key" = "$_w_last_key" ] || return 1
    [ $((_w_now - _w_last_time)) -lt "$_w_window" ]
}

notify_event() {
    _kind="$1"
    _user="$2"
    _ip="$3"
    _method="$4"
    _path="$5"
    _time="$6"
    _detail="$7"

    [ -n "$_user" ] || _user="<unknown>"
    [ -n "$_ip" ] || _ip="<unknown>"

    # Deduplicate repeats of the same event within the window for its kind. The
    # two families keep separate slots: with one shared slot, a login failure
    # landing mid-loop would flush the hour-wide OIDC suppression and re-notify.
    _key="$_kind|$_user|$_ip"
    _now="$(date +%s)"
    case "$_kind" in
        oidc_grant)
            if within_window "$_key" "$_now" "$OIDC_DEDUPE_WINDOW" "${last_oidc_key:-}" "${last_oidc_time:-0}"; then
                log "Suppressed duplicate event ($_kind) within ${OIDC_DEDUPE_WINDOW}s window"
                return 0
            fi
            last_oidc_key="$_key"
            last_oidc_time="$_now"
            ;;
        *)
            if within_window "$_key" "$_now" "$DEDUPE_WINDOW" "${last_key:-}" "${last_time:-0}"; then
                log "Suppressed duplicate event ($_kind) within ${DEDUPE_WINDOW}s window"
                return 0
            fi
            last_key="$_key"
            last_time="$_now"
            ;;
    esac

    # A rejected grant has no resolved subject, so Authelia logs no username on
    # that line: the client IP is all the alert can lead with.
    if [ "$_kind" = oidc_grant ]; then
        _message="IP: $_ip"
    else
        _message="User: $_user
IP: $_ip"
    fi
    [ -z "$_method" ] || _message="$_message
Method: $_method"
    [ -z "$_path" ] || _message="$_message
Endpoint: $_path"
    [ -z "$_time" ] || _message="$_message
Time: $_time"

    case "$_kind" in
        banned)
            _message="$_message
Banned until: $_detail"
            publish "Authelia: user banned" high "lock,rotating_light" "$_message"
            ;;
        unknown_user)
            publish "Authelia: unknown user login attempt" default "warning,detective" "$_message"
            ;;
        oidc_grant)
            _message="$_message
Reason: $_detail"
            publish "Authelia: OIDC grant rejected" default "key,warning" "$_message"
            ;;
        *)
            publish "Authelia: failed login" default "warning" "$_message"
            ;;
    esac
}

process_line() {
    _line="$1"

    case "$_line" in
        *'Unsuccessful '*' authentication attempt by user '*) ;;
        *'username input '*'which usually indicates they do not exist'*) ;;
        *'Access Request failed with error'*) ;;
        *) return 0 ;;
    esac

    _ip="$(field 's|.* remote_ip=\([^ ]*\).*|\1|p' "$_line")"
    _path="$(field 's|.* path=\([^ ]*\).*|\1|p' "$_line")"
    _time="$(field 's|^time="\([^"]*\)".*|\1|p' "$_line")"

    case "$_line" in
        *'Access Request failed with error'*)
            _reason="$(field 's|.*Access Request failed with error: \(.*\)" method=.*|\1|p' "$_line")"
            # Drop the RFC 6749 boilerplate that prefixes every invalid_grant so
            # the alert leads with the part that differs between causes.
            _reason="$(printf '%s' "$_reason" | sed 's|.*was issued to another client\. ||')"
            [ -n "$_reason" ] || _reason="<unparsed>"
            notify_event oidc_grant "" "$_ip" "" "$_path" "$_time" "$_reason"
            return 0
            ;;
    esac

    case "$_line" in
        *'which usually indicates they do not exist'*)
            _user="$(field "s|.*username input '\([^']*\)'.*|\1|p" "$_line")"
            notify_event unknown_user "$_user" "$_ip" "" "$_path" "$_time" ""
            return 0
            ;;
    esac

    _user="$(field "s|.*authentication attempt by user '\([^']*\)'.*|\1|p" "$_line")"
    _method="$(field 's|.*Unsuccessful \([^ ]*\) authentication attempt.*|\1|p' "$_line")"

    # A nonexistent username yields an empty user here, immediately followed by the
    # "username input '<user>'" line that carries the attempted name - notify on that
    # one instead so the alert is not anonymous.
    if [ -z "$_user" ]; then
        return 0
    fi

    case "$_line" in
        *'and they are banned until '*)
            _banned_until="$(field 's|.*banned until \([^"]*\)".*|\1|p' "$_line")"
            notify_event banned "$_user" "$_ip" "$_method" "$_path" "$_time" "$_banned_until"
            ;;
        *)
            notify_event failed "$_user" "$_ip" "$_method" "$_path" "$_time" ""
            ;;
    esac
}

# --- Main loop ---

watch_stream() {
    # --tail 0 follows only new lines: a watcher restart never replays old attempts.
    docker logs -f --tail 0 "$AUTHELIA_CONTAINER" 2>&1 | while IFS= read -r line; do
        process_line "$line" || true
    done
}

main() {
    log "Watching $AUTHELIA_CONTAINER for failed authentication attempts"

    while :; do
        if container_is_running "$AUTHELIA_CONTAINER"; then
            watch_stream || true
            log "Log stream ended; reconnecting in ${RECONNECT_DELAY}s"
        fi
        sleep "$RECONNECT_DELAY"
    done
}

main "$@"
