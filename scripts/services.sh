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
#   config             Interactive whiptail/dialog checklist of all services
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
    echo "✏️  COMPOSE_PROFILES=$1"
}

# Mutating docker compose command (stop/rm). Dry mode prints instead.
run_compose() {
    if is_dry_run; then
        echo "DRY-RUN: docker compose $*"
    else
        compose "$@"
    fi
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

# One display row per optional service, as "<tag>:<section>:<parent>",
# ordered by section, with a service that pulls in another indented under it:
# an "  - " tag hangs off the row above and <parent> names it. Everything is derived from
# compose.yaml, so the checklist cannot drift from the stack: a service's
# `profiles:` list names the dependents that auto-activate it (gluetun carries
# its netns tenants, n8n carries n8n-runners), which is what makes a pair a
# tree, and its `homepage.group=` label gives the section. A label-less service
# borrows its first child's section (flaresolverr sits with prowlarr), else the
# section of the service it shares a name prefix with (immich-machine-learning
# sits with immich-server), else "Other". Sorting goes through sort(1) because
# mawk has no asort. The indent marker stays ASCII: whiptail pads the tag
# column by byte length, so a multi-byte glyph would shift the second column of
# every child row out of line. Fields are colon-separated, not tab-separated: `read`
# folds runs of IFS whitespace, which would swallow the empty field a row
# always has (a section has no parent and a child shows no section).
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
        END {
            collect()
            for (i = 1; i <= n; i++) {
                cnt = split(prof[i], part, ",")
                for (j = 1; j <= cnt; j++)
                    if (part[j] != "" && part[j] != "all" && part[j] != name[i])
                        parent[part[j]] = name[i]
            }
            for (i = 1; i <= n; i++) {
                if (name[i] in parent) continue
                g = grp[i]
                for (k = 1; k <= n && g == ""; k++)
                    if ((name[k] in parent) && parent[name[k]] == name[i] && grp[k] != "")
                        g = grp[k]
                if (g == "") {
                    pre = name[i]
                    sub(/-.*$/, "", pre)
                    for (k = 1; k <= n && g == ""; k++)
                        if (k != i && grp[k] != "" && index(name[k], pre "-") == 1)
                            g = grp[k]
                }
                if (g == "") g = "Other"
                section[name[i]] = g
            }
            for (i = 1; i <= n; i++)
                if (name[i] in parent)
                    printf "%s|%s|1|%s|%s\n", section[parent[name[i]]], parent[name[i]], name[i], parent[name[i]]
                else
                    printf "%s|%s|0|%s|\n", section[name[i]], name[i], name[i]
        }
        function collect() {
            if (svc != "" && profiles != "") {
                n++
                name[n] = svc
                grp[n] = group
                p = profiles
                sub(/^[^[]*\[/, "", p)
                sub(/\].*$/, "", p)
                gsub(/["\t ]/, "", p)
                prof[n] = p
            }
            svc = ""; profiles = ""; group = ""
        }
    ' "$PROJECT_DIR/compose.yaml" \
        | sort -t'|' -k1,1 -k2,2 -k3,3n -k4,4 \
        | awk -F'|' '
            { sec[NR] = $1; root[NR] = $2; child[NR] = $3; svc[NR] = $4; par[NR] = $5; n = NR }
            END {
                for (i = 1; i <= n; i++)
                    if (child[i] == 0) {
                        section = sec[i]
                        gsub(/:/, " ", section)
                        printf "%s:%s:\n", svc[i], section
                    } else
                        printf "  - %s::%s\n", svc[i], par[i]
            }'
}

# Linked services move together, in both directions: unticking a parent takes
# the services hanging off it with it, and ticking one of those ticks the
# parent back (compose starts it anyway, through the child's own profile).
# Rule 1 keys off what changed against the state that was on screen, so the
# two rules cannot fight over a box the user did not touch.
close_selection() {
    _sel="$1"
    _shown="$2"
    _edges="$3"
    while IFS=' ' read -r _child _parent; do
        [ -n "$_parent" ] || continue
        in_lines "$_shown" "$_parent" || continue
        in_lines "$_sel" "$_parent" && continue
        _sel="$(printf '%s\n' "$_sel" | grep -vx "$_child" || true)"
    done <<EOF
$_edges
EOF
    while IFS=' ' read -r _child _parent; do
        [ -n "$_parent" ] || continue
        in_lines "$_sel" "$_child" || continue
        in_lines "$_sel" "$_parent" && continue
        _sel="$_sel
$_parent"
    done <<EOF
$_edges
EOF
    printf '%s\n' "$_sel" | grep -v '^$' | sort -u || true
}

# missing_from <list-a> <list-b>: entries of a absent from b, space-joined.
missing_from() {
    _out=""
    for _item in $1; do
        in_lines "$2" "$_item" || _out="$_out $_item"
    done
    printf '%s' "${_out# }"
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
    run_compose stop "$svc"
    run_compose rm -f "$svc"
    echo "✅ $svc disabled"
}

cmd_config() {
    require_env_file
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        echo "❌ 'config' needs an interactive terminal — run 'make config' from a TTY," >&2
        echo "   or use 'make enable s=<service>' / 'make disable s=<service>' instead." >&2
        exit 1
    fi
    if command -v whiptail >/dev/null 2>&1; then
        dialog_tool=whiptail
    elif command -v dialog >/dev/null 2>&1; then
        dialog_tool=dialog
    else
        echo "❌ 'config' needs whiptail or dialog installed (sudo apt install whiptail)." >&2
        exit 1
    fi

    if has_profiles_line; then
        old_profiles="$(get_env_value COMPOSE_PROFILES)"
    else
        old_profiles=all
    fi
    known="$(known_profiles)"
    old_enabled="$(services_for_profiles "$old_profiles")"

    # The rows never change, only their tick state, so read them once. The tag
    # carries the indent marker, so the service name is its last
    # whitespace-separated word. Fed by a here-doc, not a pipe, so the
    # assignments land in this shell.
    rows=""
    edges=""
    count=0
    while IFS=: read -r tag desc parent; do
        [ -n "$tag" ] || continue
        svc="${tag##* }"
        in_lines "$known" "$svc" || continue
        rows="$rows$tag:$desc
"
        [ -z "$parent" ] || edges="$edges$svc $parent
"
        count=$((count + 1))
    done <<EOF
$(config_rows)
EOF
    if [ "$count" -eq 0 ]; then
        echo "❌ No optional services declared in compose.yaml" >&2
        exit 1
    fi

    list_height=$count
    [ "$list_height" -le 14 ] || list_height=14
    height=$((list_height + 8))

    # Shown ticked, then re-shown whenever the linked services move a box the
    # user did not touch: whiptail has no way to toggle a row from a callback,
    # so the adjusted state comes back on screen to be confirmed or edited.
    shown="$(printf '%s\n' "$old_enabled" | grep -v '^$' | sort -u || true)"
    note=""
    while :; do
        set --
        while IFS=: read -r tag desc; do
            [ -n "$tag" ] || continue
            svc="${tag##* }"
            if in_lines "$shown" "$svc"; then
                set -- "$@" "$tag" "$desc" on
            else
                set -- "$@" "$tag" "$desc" off
            fi
        done <<EOF
$rows
EOF
        # whiptail/dialog draw the UI on the terminal and print the chosen tags
        # on stderr; the fd swap captures them. Non-zero means Cancel/Esc.
        if ! selection="$("$dialog_tool" --title "pi-pcloud optional services" \
                --separate-output \
                --checklist "${note}Choose which optional services run (space toggles, enter applies). An indented service runs with the one above it, and the two are ticked and unticked together:" \
                "$height" 72 "$list_height" "$@" 3>&1 1>&2 2>&3)"; then
            echo "Cancelled — no changes."
            return 0
        fi

        # Back from display tags to service names (drop the indent marker).
        selection="$(printf '%s\n' "$selection" | sed 's/^.* //' | grep -v '^$' | sort -u || true)"
        closed="$(close_selection "$selection" "$shown" "$edges")"
        [ "$closed" != "$selection" ] || break

        added="$(missing_from "$closed" "$selection")"
        removed="$(missing_from "$selection" "$closed")"
        note=""
        [ -z "$added" ] || note="${note}Also ticked (needed by a ticked service): $added
"
        [ -z "$removed" ] || note="${note}Also unticked (they only run with the service you unticked): $removed
"
        note="$note
"
        shown="$closed"
    done
    selection="$closed"
    new_profiles="$(printf '%s\n' "$selection" | paste -sd, - || true)"
    if [ "$(printf '%s\n' "$selection" | sort)" = "$known" ]; then
        new_profiles=all
    fi
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

    for svc in $newly_on; do
        run_hook "$svc-pre-start.sh"
    done

    echo "🚀 Applying selection (docker compose up -d)..."
    run_compose_up_with "$new_profiles" up -d

    for svc in $newly_off; do
        echo "🛑 Stopping and removing $svc..."
        run_compose stop "$svc"
        run_compose rm -f "$svc"
    done

    for svc in $newly_on; do
        run_hook "$svc-bootstrap.sh"
        run_hook "$svc-oidc-bootstrap.sh"
    done

    echo "✅ Applied. COMPOSE_PROFILES=${new_profiles:-<empty: core only>}"
    [ -z "$newly_on" ] || echo "   enabled:$newly_on"
    [ -z "$newly_off" ] || echo "   disabled:$newly_off"
}

# --- Main ---

usage() {
    echo "Usage: services.sh {list|enable <service>|disable <service>|config}" >&2
}

cmd="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi
case "$cmd" in
    list) cmd_list ;;
    enable) cmd_enable "${1:-}" ;;
    disable) cmd_disable "${1:-}" ;;
    config) cmd_config ;;
    *) usage; exit 1 ;;
esac
