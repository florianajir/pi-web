#!/bin/sh
# Manage optional pi-pcloud services through Docker Compose profiles.
#
# Every optional service in compose.yaml carries a profile named after itself
# (plus the catch-all "all"); COMPOSE_PROFILES in .env selects which run. A
# missing line means everything (pre-profiles installs); an explicitly empty
# value means core-only, matching what docker compose does with it.
# Enabled-ness is computed with `docker compose config --services` under the
# current selection, which is authoritative and handles coupled profiles
# (e.g. stremio auto-enabling gluetun) for free.
#
# Subcommands:
#   list               List optional services and whether each is enabled
#   enable <service>   Add to COMPOSE_PROFILES, start it, run its init hooks
#   disable <service>  Remove from COMPOSE_PROFILES, stop and remove it
#   config             Interactive picker (scripts/services-picker.py)
#   pick               Same picker, printing the chosen COMPOSE_PROFILES value
#                      instead of applying it (used by install.sh)
#
# enable (and config, for newly-enabled services) runs the same per-service
# hooks the systemd unit runs around `docker compose up`:
#   scripts/<svc>-pre-start.sh                      before starting
#   scripts/<svc>-bootstrap.sh, <svc>-oidc-bootstrap.sh   after starting
# Hooks are found by filename convention, never hardcoded, so future services
# get theirs automatically. Post hooks tolerate failure, like the systemd
# unit's `-` prefix does.
#
# DRY_RUN=1 prints the docker/hook commands and the would-be .env line
# instead of executing/writing anything. ENV_FILE=<path> (honored by lib.sh)
# points at another env file, mainly for tests; the effective selection is
# always passed to `docker compose up` explicitly so it never depends on
# which .env compose happens to read.
#
# Host-only: this script is never mounted into containers, so sourcing
# lib.sh is fine here (scripts that backrest mounts must not source it).

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

# --- Helpers ---

is_dry_run() { [ "${DRY_RUN:-0}" = "1" ]; }

require_env_file() {
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌ .env missing (copy .env.dist)" >&2
        exit 1
    fi
}

has_profiles_line() {
    grep -qE '^COMPOSE_PROFILES=' "$ENV_FILE"
}

# Every declared profile except the catch-all "all", one per line, sorted.
known_profiles() {
    compose config --profiles | grep -v '^all$' | sort
}

# Services docker compose would run under the given selection.
services_for_profiles() {
    (cd "$PROJECT_DIR" && COMPOSE_PROFILES="$1" docker compose config --services)
}

# in_lines <newline-list> <item>: 0 if <item> is an exact line of the list.
in_lines() {
    printf '%s\n' "$1" | grep -qx "$2"
}

# Rewrite (or append) the COMPOSE_PROFILES line. Dry mode prints instead.
write_profiles() {
    if is_dry_run; then
        echo "DRY-RUN: would write to $ENV_FILE: COMPOSE_PROFILES=$1"
        return 0
    fi
    if has_profiles_line; then
        sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=$1|" "$ENV_FILE"
    else
        printf 'COMPOSE_PROFILES=%s\n' "$1" >> "$ENV_FILE"
    fi
    echo "✏️  Updated COMPOSE_PROFILES in $(basename "$ENV_FILE")"
}

# Mutating docker compose command. Dry mode prints instead.
run_compose() {
    if is_dry_run; then
        echo "DRY-RUN: docker compose $*"
    else
        compose "$@"
    fi
}

# Same, with the output held back and replayed only if the command fails:
# `stop` and `rm` each draw a progress block and `rm` announces every container
# it is about to remove, which repeats what we just printed ourselves.
run_compose_quiet() {
    if is_dry_run; then
        echo "DRY-RUN: docker compose $*"
        return 0
    fi
    _out="$(compose "$@" 2>&1)" || {
        printf '%s\n' "$_out" >&2
        return 1
    }
}

# `docker compose up` with the selection passed explicitly, so the started
# set never depends on which .env compose reads. Dry mode prints instead.
run_compose_up_with() {
    _sel="$1"
    shift
    if is_dry_run; then
        echo "DRY-RUN: COMPOSE_PROFILES=$_sel docker compose $*"
    else
        (cd "$PROJECT_DIR" && COMPOSE_PROFILES="$_sel" docker compose "$@")
    fi
}

# Run scripts/<name> with /bin/sh if it exists; tolerate failure like the
# systemd unit's `-` prefix does. Dry mode prints instead.
run_hook() {
    _hook="$PROJECT_DIR/scripts/$1"
    [ -f "$_hook" ] || return 0
    if is_dry_run; then
        echo "DRY-RUN: /bin/sh $_hook"
        return 0
    fi
    log "Running hook $1..."
    /bin/sh "$_hook" || log "warning: hook $1 failed (continuing)"
}

# Validate the service argument; on failure print usage plus the valid list.
validate_service() {
    _svc="$1"
    _cmd="$2"
    _known="$3"
    if [ -z "$_svc" ]; then
        echo "❌ Usage: services.sh $_cmd <service> (make $_cmd s=<service>). Valid services:" >&2
        printf '%s\n' "$_known" | sed 's/^/  - /' >&2
        exit 1
    fi
    if ! in_lines "$_known" "$_svc"; then
        echo "❌ Unknown service '$_svc'. Valid services:" >&2
        printf '%s\n' "$_known" | sed 's/^/  - /' >&2
        exit 1
    fi
}

# --- Checklist layout ---

# One row per optional service, as
# "<service>:<section>:<companion-of>:<needs>:<description>" (description last,
# so a colon inside it survives),
# ordered by section. Three things come out of compose.yaml, so the picker can
# never drift from the stack:
#   homepage.group=            the section the service is listed under
#   pi-pcloud.companion-of=    the service it is pointless without, which is
#                              what the picker draws it indented beneath
#   homepage.description=      the one-line description shown beside it
#   profiles:                  a service listing others in its own profile list
#                              is a dependency they cannot run without (gluetun
#                              for the containers sharing its network
#                              namespace), reported as <needs>
# The last two are different relations on purpose: qbittorrent needs gluetun but
# is a service in its own right, listed under Download, while comet only makes
# sense under stremio. Both propagate when a box is toggled; only companion-of
# nests. A service with no section label borrows its companion's, else "Other".
# Sorting goes through sort(1) because mawk has no asort. Fields are
# colon-separated, not tab-separated: `read` folds runs of IFS whitespace, which
# would swallow the empty fields a row carries.
config_rows() {
    awk '
        /^services:[ \t]*$/ { in_services = 1; next }
        /^[A-Za-z0-9_-]+:/ {
            if (in_services) collect()
            in_services = 0
            next
        }
        !in_services { next }
        /^  [A-Za-z0-9_-]+:[ \t]*$/ {
            collect()
            svc = $0
            gsub(/[ :]/, "", svc)
            next
        }
        /^[ \t]+profiles:/ { profiles = $0; next }
        /homepage\.group=/ {
            group = $0
            sub(/.*homepage\.group=/, "", group)
            sub(/"[ \t]*$/, "", group)
            next
        }
        /homepage\.description=/ {
            desc = $0
            sub(/.*homepage\.description=/, "", desc)
            sub(/"[ \t]*$/, "", desc)
            gsub(/\|/, "/", desc)
            next
        }
        /pi-pcloud\.companion-of=/ {
            companion = $0
            sub(/.*pi-pcloud\.companion-of=/, "", companion)
            sub(/"[ \t]*$/, "", companion)
            next
        }
        END {
            collect()
            for (i = 1; i <= n; i++) {
                cnt = split(prof[i], part, ",")
                for (j = 1; j <= cnt; j++)
                    if (part[j] != "" && part[j] != "all" && part[j] != name[i])
                        needs[part[j]] = needs[part[j]] " " name[i]
            }
            for (i = 1; i <= n; i++) {
                g = grp[i]
                if (g == "" && comp[i] != "")
                    for (k = 1; k <= n; k++)
                        if (name[k] == comp[i] && grp[k] != "") g = grp[k]
                if (g == "") g = "Other"
                section[name[i]] = g
            }
            for (i = 1; i <= n; i++) {
                root = comp[i] != "" ? comp[i] : name[i]
                child = comp[i] != "" ? 1 : 0
                sub(/^ /, "", needs[name[i]])
                # A sidecar carries no dashboard description of its own; saying
                # what it runs with beats an empty column.
                text = info[i] != "" ? info[i] : (comp[i] != "" ? "runs with " comp[i] : "")
                printf "%s|%s|%d|%s|%s|%s|%s\n", section[name[i]], root, child, name[i], comp[i], needs[name[i]], text
            }
        }
        function collect() {
            if (svc != "" && profiles != "") {
                n++
                name[n] = svc
                grp[n] = group
                comp[n] = companion
                info[n] = desc
                p = profiles
                sub(/^[^[]*\[/, "", p)
                sub(/\].*$/, "", p)
                gsub(/["\t ]/, "", p)
                prof[n] = p
            }
            svc = ""; profiles = ""; group = ""; companion = ""; desc = ""
        }
    ' "$PROJECT_DIR/compose.yaml" \
        | sort -t'|' -k1,1 -k2,2 -k3,3n -k4,4 \
        | awk -F'|' '{ printf "%s:%s:%s:%s:%s\n", $4, ($3 == 0 ? $1 : ""), $5, $6, $7 }'
}

# Runs the picker over the current selection and prints the COMPOSE_PROFILES
# value it produced (empty means core services only). Status: 0 printed,
# 1 cancelled, 2 no picker available here. Shared with install.sh through the
# `pick` subcommand, so a fresh install and `make config` offer the same list,
# nesting and linked toggling.
pick_profiles() {
    _enabled="$1"
    # A terminal must exist, but it need not be our stdin or stdout: the value
    # travels through this function's stdout (install.sh captures it) and the
    # installer itself may be running from `curl | sh`, where stdin is the
    # script. The picker is wired to /dev/tty for both directions below.
    { true </dev/tty; } 2>/dev/null || return 2
    command -v python3 >/dev/null 2>&1 || return 2

    # The picker only chooses: it reads
    # "service:section:parent:needs:state:description" rows and writes back the
    # services that stay ticked. Files, not a pipe, because it takes over the
    # terminal (see scripts/services-picker.py).
    _rows="$(mktemp)"
    _picked="$(mktemp)"
    _known="$(known_profiles)"
    while IFS=: read -r _svc _section _parent _needs _desc; do
        [ -n "$_svc" ] || continue
        in_lines "$_known" "$_svc" || continue
        if in_lines "$_enabled" "$_svc"; then
            printf '%s:%s:%s:%s:on:%s\n' "$_svc" "$_section" "$_parent" "$_needs" "$_desc" >>"$_rows"
        else
            printf '%s:%s:%s:%s:off:%s\n' "$_svc" "$_section" "$_parent" "$_needs" "$_desc" >>"$_rows"
        fi
    done <<EOF
$(config_rows)
EOF
    if [ ! -s "$_rows" ]; then
        rm -f "$_rows" "$_picked"
        echo "❌ No optional services declared in compose.yaml" >&2
        return 2
    fi
    if ! python3 "$PROJECT_DIR/scripts/services-picker.py" "$_rows" "$_picked" </dev/tty >/dev/tty; then
        rm -f "$_rows" "$_picked"
        return 1
    fi
    _selection="$(sort -u "$_picked")"
    rm -f "$_rows" "$_picked"

    # Everything ticked is written as "all", so a service added by a later
    # update is enabled too instead of silently missing from an explicit list.
    if [ "$(printf '%s\n' "$_selection" | grep -v '^$' | sort)" = "$_known" ]; then
        echo all
    else
        printf '%s\n' "$_selection" | grep -v '^$' | paste -sd, - || true
    fi
}

# The tick state a picker run should start from: what is enabled today.
current_enabled() {
    if has_profiles_line; then
        services_for_profiles "$(get_env_value COMPOSE_PROFILES)"
    else
        services_for_profiles all
    fi
}

# --- Subcommands ---

cmd_list() {
    require_env_file
    if has_profiles_line; then
        profiles="$(get_env_value COMPOSE_PROFILES)"
        echo "🧩 Optional services (COMPOSE_PROFILES=${profiles:-<empty: core only>})"
    else
        profiles=all
        echo "🧩 Optional services (no COMPOSE_PROFILES line in .env = all)"
    fi
    known="$(known_profiles)"
    enabled="$(services_for_profiles "$profiles")"
    for svc in $known; do
        if in_lines "$enabled" "$svc"; then
            printf '  ✅ %s enabled\n' "$svc"
        else
            printf '  ⛔ %s disabled\n' "$svc"
        fi
    done
}

cmd_enable() {
    svc="${1:-}"
    require_env_file
    known="$(known_profiles)"
    validate_service "$svc" enable "$known"
    if has_profiles_line; then
        current="$(get_env_value COMPOSE_PROFILES)"
    else
        echo "ℹ️  No COMPOSE_PROFILES line in .env (= everything enabled): writing the full explicit list first"
        current="$(printf '%s\n' "$known" | paste -sd, -)"
    fi
    if [ "$current" = "all" ]; then
        echo "ℹ️  COMPOSE_PROFILES=all: every service is already enabled"
        new="all"
    else
        case ",$current," in
            ",,") new="$svc" ;;
            *",$svc,"*) new="$current"; echo "ℹ️  $svc already in COMPOSE_PROFILES" ;;
            *) new="$current,$svc" ;;
        esac
        write_profiles "$new"
    fi
    run_hook "$svc-pre-start.sh"
    echo "🚀 Starting $svc (and any services it depends on)..."
    run_compose_up_with "$new" up -d "$svc"
    run_hook "$svc-bootstrap.sh"
    run_hook "$svc-oidc-bootstrap.sh"
    echo "✅ $svc enabled"
}

cmd_disable() {
    svc="${1:-}"
    require_env_file
    known="$(known_profiles)"
    validate_service "$svc" disable "$known"
    if has_profiles_line; then
        current="$(get_env_value COMPOSE_PROFILES)"
    else
        current=all
    fi
    if [ "$current" = "all" ]; then
        echo "ℹ️  COMPOSE_PROFILES was '$current' (= everything enabled): writing the full explicit list first"
        current="$(printf '%s\n' "$known" | paste -sd, -)"
    fi
    new="$(printf '%s\n' "$current" | tr ',' '\n' | grep -vx "$svc" | paste -sd, - || true)"
    [ -n "$new" ] || echo "⚠️  COMPOSE_PROFILES is now empty: only core services will run"
    write_profiles "$new"
    if services_for_profiles "$new" 2>/dev/null | grep -qx "$svc"; then
        echo "⚠️  $svc is still auto-enabled by another enabled service's profile — it will come back on the next stack restart"
    fi
    echo "🛑 Stopping and removing $svc..."
    run_compose_quiet stop "$svc"
    run_compose_quiet rm -f "$svc"
    echo "✅ $svc disabled"
}

# Print the COMPOSE_PROFILES value the user picks, and nothing else, so
# install.sh can offer the same screen while owning its own .env writing.
cmd_pick() {
    require_env_file
    _value="$(pick_profiles "$(current_enabled)")" || return "$?"
    printf '%s\n' "$_value"
}

cmd_config() {
    require_env_file
    known="$(known_profiles)"
    old_enabled="$(current_enabled)"

    # `|| rc=$?` keeps set -e out of it: a cancelled picker is a normal outcome.
    rc=0
    new_profiles="$(pick_profiles "$old_enabled")" || rc="$?"
    case "$rc" in
        1)
            echo "Cancelled — no changes."
            return 0
            ;;
        2)
            echo "❌ 'config' needs an interactive terminal and python3 (shipped with" >&2
            echo "   Raspberry Pi OS). Use 'make enable s=<service>' /" >&2
            echo "   'make disable s=<service>' instead." >&2
            exit 1
            ;;
    esac
    [ -n "$new_profiles" ] || echo "⚠️  Nothing selected: COMPOSE_PROFILES will be empty — only core services will run"
    write_profiles "$new_profiles"

    # Diff effective service sets (not raw profiles), so auto-enabled
    # dependencies are handled and core services cancel out.
    new_enabled="$(services_for_profiles "$new_profiles")"
    newly_on=""
    newly_off=""
    for svc in $known; do
        if in_lines "$new_enabled" "$svc"; then
            in_lines "$old_enabled" "$svc" || newly_on="$newly_on $svc"
        else
            if in_lines "$old_enabled" "$svc"; then newly_off="$newly_off $svc"; fi
        fi
    done

    if [ -z "$newly_on" ] && [ -z "$newly_off" ]; then
        echo "✅ No service changes (COMPOSE_PROFILES=${new_profiles:-<empty: core only>})"
        return 0
    fi

    # Only the services that were just enabled are started, so disabling
    # something does not redraw the whole stack (and does not rebuild images
    # to reach a state it is already in).
    if [ -n "$newly_on" ]; then
        for svc in $newly_on; do
            run_hook "$svc-pre-start.sh"
        done
        echo "🚀 Starting$newly_on..."
        # shellcheck disable=SC2086 # service names, split on purpose
        run_compose_up_with "$new_profiles" up -d $newly_on
    fi

    if [ -n "$newly_off" ]; then
        echo "🛑 Stopping and removing$newly_off..."
        # shellcheck disable=SC2086 # service names, split on purpose
        run_compose_quiet stop $newly_off
        # shellcheck disable=SC2086 # service names, split on purpose
        run_compose_quiet rm -f $newly_off
    fi

    for svc in $newly_on; do
        run_hook "$svc-bootstrap.sh"
        run_hook "$svc-oidc-bootstrap.sh"
    done

    echo "✅ Applied${newly_on:+ · enabled:$newly_on}${newly_off:+ · disabled:$newly_off}"
}

# --- Main ---

usage() {
    echo "Usage: services.sh {list|enable <service>|disable <service>|config|pick}" >&2
}

cmd="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi
case "$cmd" in
    list) cmd_list ;;
    enable) cmd_enable "${1:-}" ;;
    disable) cmd_disable "${1:-}" ;;
    config) cmd_config ;;
    pick) cmd_pick ;;
    *) usage; exit 1 ;;
esac
