#!/bin/sh
# The stack's start sequence: pre-start hooks, `docker compose up -d`, then the
# bootstraps. pi-pcloud.service runs it as its ExecStart and `make update` runs
# it directly, so an update applies changes without stopping anything first and
# the two cannot drift. Takes no arguments, so neither caller can ask for a
# different start than the other.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

[ "$#" -eq 0 ] || die "takes no arguments (got: $*)"

# systemd supplies COMPOSE_PROFILES (EnvironmentFile=.env, falling back to its
# own Environment=all for installs predating per-service profiles). Under make
# there is no such wrapper, so both rules are reproduced here. Empty stays
# empty: that means core-only, not everything.
if [ -z "${COMPOSE_PROFILES+x}" ]; then
    if grep -qE '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null; then
        # Compose, systemd and run-if-enabled.sh all strip quotes and CR;
        # get_env_value reads verbatim. Left in, `"stremio"` would match no
        # profile while --remove-orphans deleted the optional containers.
        COMPOSE_PROFILES="$(get_env_value_clean COMPOSE_PROFILES)"
    else
        COMPOSE_PROFILES=all
    fi
    export COMPOSE_PROFILES
fi

# `stremio` and `stremio-lan` are one server in two networking modes, sharing a
# single data volume and the same Traefik host rules. Compose cannot express
# mutual exclusion, so refuse the combination before anything starts. The pair
# is spelled out here rather than read from compose.yaml's
# pi-pcloud.conflicts-with label (which is what services.sh and the picker use),
# so the boot path stays a plain string check.
profiles_have() {
    case ",$(printf '%s' "${COMPOSE_PROFILES:-}" | tr -d ' \r')," in
        *",$1,"*) return 0 ;;
    esac
    return 1
}

# "all" covers stremio and deliberately not stremio-lan, so `all,stremio-lan`
# is the same conflict spelled differently and must not slip through.
if profiles_have stremio-lan && { profiles_have stremio || profiles_have all; }; then
    die "COMPOSE_PROFILES lists both stremio and stremio-lan: same server, two networking modes, one data volume - keep only one"
fi

# --- The sequence ---
#
# An entry is "script.sh", or "service:script.sh" to gate it on that optional
# service being selected.

# Blocking: nothing should start against a half-written configuration.
PRE_START_HOOKS='
authelia-pre-start.sh
headscale-pre-start.sh
backrest-pre-start.sh
ntfy-pre-start.sh
cloudflared:cloudflared-pre-start.sh
vaultwarden:vaultwarden-pre-start.sh
qbittorrent:qbittorrent-pre-start.sh
prowlarr:prowlarr-pre-start.sh
kapowarr:kapowarr-pre-start.sh
kavita:kavita-pre-start.sh
shelfmark:shelfmark-pre-start.sh
audiobookshelf:audiobookshelf-pre-start.sh
nextcloud:nextcloud-pre-start.sh
llama-cpp:llama-cpp-pre-start.sh
stremio-lan:stremio-lan-pre-start.sh
'

# Best-effort: these need their service answering, and a slow one must not fail
# the start. All idempotent, so the next run picks up whatever was missed.
POST_START_HOOKS='
postgres-bootstrap.sh
headscale-init.sh
beszel-agent:beszel-agent-bootstrap.sh
dockhand:dockhand-oidc-bootstrap.sh
nextcloud:nextcloud-oidc-bootstrap.sh
pihole-bootstrap.sh
qbittorrent:qbittorrent-bootstrap.sh
prowlarr:prowlarr-bootstrap.sh
kapowarr:kapowarr-bootstrap.sh
uptime-kuma:uptime-kuma-bootstrap.sh
kavita:kavita-oidc-bootstrap.sh
kavita:kavita-library-bootstrap.sh
shelfmark:shelfmark-settings-bootstrap.sh
audiobookshelf:audiobookshelf-bootstrap.sh
open-webui:open-webui-bootstrap.sh
homepage-widgets-bootstrap.sh
'

# run_hooks <blocking|tolerant> <list>
run_hooks() {
    _mode="$1"
    _list="$2"

    # Word splitting on the list is the parse; no entry contains whitespace.
    # shellcheck disable=SC2086
    for _entry in $_list; do
        _service=""
        _script="$_entry"
        case "$_entry" in
            *:*)
                _service="${_entry%%:*}"
                _script="${_entry#*:}"
                ;;
        esac

        # Gate before the script is looked at: the unit's `run-if-enabled.sh
        # <svc> <cmd>` returned 0 for a disabled service without reaching it.
        if [ -n "$_service" ] && ! /bin/sh "$SCRIPT_DIR/run-if-enabled.sh" "$_service"; then
            log "$_script skipped ($_service disabled)"
            continue
        fi

        if [ ! -f "$SCRIPT_DIR/$_script" ]; then
            hook_problem "$_script is missing"
            continue
        fi

        run_hook /bin/sh "$SCRIPT_DIR/$_script"
    done
}

# Both read the enclosing run_hooks' mode — the `-` prefix the unit's Exec*
# lines carried, now carried by which list a hook is in.
hook_problem() {
    [ "$_mode" = tolerant ] || die "$1"
    log "warning: $1 (continuing)"
}

run_hook() {
    "$@" || hook_problem "$_script failed"
}

# `up -d` refuses when a network or volume *definition* changed: compose can
# only apply that by removing the object, which needs the stack down. Without
# the fallback an update aborts here, images pulled and host files applied.
#
# The output is captured rather than streamed: a pipeline into tee reports
# tee's status, and dash has no pipefail, so streaming would mean carrying
# compose's own status out of a subshell — and losing it there would report a
# failure that never happened, which under systemd means ExecStop tearing down
# a healthy stack.
start_containers() {
    if _out="$(compose up -d --remove-orphans 2>&1)"; then
        printf '%s\n' "$_out"
        return 0
    fi
    printf '%s\n' "$_out" >&2

    case "$_out" in
        *"has incorrect"* | *"needs to be recreated"*) ;;
        *) die "docker compose up failed" ;;
    esac

    log "A network or volume definition changed; that one needs the stack down"
    compose down --remove-orphans
    compose up -d --remove-orphans
}

# --- Run ---

log "Preparing configuration..."
run_hooks blocking "$PRE_START_HOOKS"

log "Starting containers (only what changed is recreated)..."
start_containers

log "Running bootstraps..."
run_hooks tolerant "$POST_START_HOOKS"

log "Stack is up"
