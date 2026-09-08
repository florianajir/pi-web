#!/bin/sh
set -eu

# Keeps WAN_HAIRPIN_IP in .env, and the running Traefik, equal to this line's
# current public IPv4. What that entry admits and why it is needed at all:
# docs/NETWORKING.md, docs/SECURITY.md.
#
# A timer rather than a one-off because the entry expires with the line's
# address, and a stale one keeps allowlisting whoever inherits it.
#
# The address comes from `tailscale netcheck` - a STUN observation of what the
# line presents *now*, which is exactly what the router SNATs a hairpinned
# connection to. ddns-updater's state file is the obvious source and the wrong
# one: it records what was last *published*, and is only rewritten when that
# changes, so it reports agreement forever once publishing has broken.

. "$(dirname "$0")/lib.sh"

TRAEFIK_CONTAINER="pi-traefik"
LAN_RANGE_LABEL="traefik.http.middlewares.lan.ipallowlist.sourcerange"

# A shared or private address must never be allowlisted: on a CGNAT line that
# /32 is every other subscriber's source address too, and 100.64.0.0/10 is
# already in ALLOW_IP_RANGES for the tailnet.
is_globally_routable() {
    case "$1" in
        0.*|10.*|127.*|169.254.*|192.168.*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
    esac
    return 0
}

# Nothing to apply a change to, and .env is rendered into labels at the next
# stack start anyway, so a stopped Traefik means there is nothing useful to do.
container_is_running "$TRAEFIK_CONTAINER" || exit 0

WAN_IP="$(
    timeout 40 tailscale netcheck --format=json 2>/dev/null \
        | jq -r '.GlobalV4 // empty' 2>/dev/null \
        | cut -d: -f1 \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
)" || WAN_IP=""

if [ -z "$WAN_IP" ]; then
    log "WARNING: tailscale netcheck returned no public IPv4, leaving WAN_HAIRPIN_IP as it is"
    exit 0
fi

if ! is_globally_routable "$WAN_IP"; then
    log "WARNING: $WAN_IP is CGNAT or private, not a source worth allowlisting - leaving WAN_HAIRPIN_IP as it is"
    exit 0
fi

DESIRED="$WAN_IP/32"
ENV_CURRENT="$(get_env_value_clean WAN_HAIRPIN_IP)"

# Compared against the *running* label, not just .env: a compose call that failed
# last time leaves the two out of step, and keying off .env alone would then
# short-circuit every later run and leave the stale range live indefinitely.
APPLIED="$(docker inspect "$TRAEFIK_CONTAINER" \
    --format "{{index .Config.Labels \"$LAN_RANGE_LABEL\"}}" 2>/dev/null || true)"
applied_matches=false
case "$APPLIED" in
    *",$DESIRED") applied_matches=true ;;
esac

if [ "$ENV_CURRENT" = "$DESIRED" ] && [ "$applied_matches" = true ]; then
    exit 0
fi

if [ "$ENV_CURRENT" != "$DESIRED" ]; then
    # Through a copy, not in place: a sed that dies midway leaves a truncated
    # .env, and every interpolated value in compose.yaml with it. .env.tmp* is
    # gitignored, and `cp -p` carries the 0600 mode and owner across so the mv
    # cannot widen them.
    TMP_ENV="$ENV_FILE.tmp.$$"
    trap 'rm -f "$TMP_ENV" "$TMP_ENV.a" "$TMP_ENV.b"' EXIT INT TERM
    cp -p "$ENV_FILE" "$TMP_ENV" || die "could not copy $ENV_FILE"

    if grep -q '^WAN_HAIRPIN_IP=' "$TMP_ENV"; then
        sed -i "s|^WAN_HAIRPIN_IP=.*|WAN_HAIRPIN_IP=$(sed_escape "$DESIRED")|" "$TMP_ENV" \
            || die "could not rewrite WAN_HAIRPIN_IP"
    else
        # An .env predating this variable: append, so the next run has a line to
        # rewrite rather than appending a second one.
        printf 'WAN_HAIRPIN_IP=%s\n' "$DESIRED" >> "$TMP_ENV" \
            || die "could not append WAN_HAIRPIN_IP"
    fi

    [ "$(unquote_env_value "$(read_env_value_from_file "$TMP_ENV" WAN_HAIRPIN_IP)")" = "$DESIRED" ] \
        || die "WAN_HAIRPIN_IP did not land as $DESIRED, leaving $ENV_FILE untouched"

    # rotate-password.sh and rotate-secret.sh edit .env in place. Replacing the
    # file wholesale would silently revert a rotation that landed since the copy
    # above, so refuse unless everything except this one line still matches.
    grep -v '^WAN_HAIRPIN_IP=' "$ENV_FILE" > "$TMP_ENV.a" || true
    grep -v '^WAN_HAIRPIN_IP=' "$TMP_ENV" > "$TMP_ENV.b" || true
    cmp -s "$TMP_ENV.a" "$TMP_ENV.b" \
        || die "$ENV_FILE changed while this ran - leaving it alone, the next run retries"

    mv "$TMP_ENV" "$ENV_FILE" || die "could not replace $ENV_FILE"
    trap - EXIT INT TERM
    rm -f "$TMP_ENV.a" "$TMP_ENV.b"
    safe_chmod 600 "$ENV_FILE"
    # The timer runs this as root, whose mv would otherwise leave the file
    # unreadable to the account that owns the checkout.
    fix_ownership "$ENV_FILE"
    log "WAN_HAIRPIN_IP: ${ENV_CURRENT:-<unset>} -> $DESIRED"
fi

# --no-deps so this touches Traefik and nothing else, and `up` rather than
# `restart` because Traefik reads middleware definitions from container labels,
# which are fixed at creation.
compose up -d --no-deps traefik || die "could not apply $DESIRED to traefik"
log "Applied $DESIRED to the lan allowlist"
