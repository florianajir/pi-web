#!/bin/sh
# Tests for scripts/stack-up.sh, the start sequence shared by the systemd unit
# and `make update`.
#
# Everything runs against a throwaway copy of the script with stub hooks and a
# stub `docker` on PATH, so no container, no systemd and no host change. The
# point is the two things the refactor made possible to get wrong: a hook that
# stops being run, and a hook that runs when its service is disabled.
# Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
SCRIPT="$REPO_DIR/scripts/stack-up.sh"
UNIT="$REPO_DIR/config/systemd/system/pi-pcloud.service"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  got  [%s]\n  want [%s]\n' "$1" "$2" "$3"
    fi
}

contains() {
    case "$2" in
        *"$3"*) ok "$1" yes yes ;;
        *) ok "$1" "$2" "should contain: $3" ;;
    esac
}

lacks() {
    case "$2" in
        *"$3"*) ok "$1" "$2" "should NOT contain: $3" ;;
        *) ok "$1" yes yes ;;
    esac
}

# The entries the script declares, in order: "script.sh" or "service:script.sh".
hook_entries() {
    grep -oE '^[a-z0-9-]*:?[a-z0-9-]+\.sh$' "$SCRIPT"
}

# --- the sequence is complete -----------------------------------------------
#
# The drift this file exists to catch: a hook script sitting in scripts/ that
# nothing in the sequence runs. Discovered by filename convention, so a service
# added later is covered without touching this test.

declared="$(hook_entries | sed 's/.*://' | sort -u)"
for path in "$REPO_DIR"/scripts/*-pre-start.sh "$REPO_DIR"/scripts/*-bootstrap.sh; do
    name="$(basename "$path")"
    if printf '%s\n' "$declared" | grep -qx "$name"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s is in scripts/ but stack-up.sh never runs it\n' "$name"
    fi
done

# And the unit must go through the script, or the Makefile and the boot path
# would be running two different sequences again.
contains "the unit starts the stack through stack-up.sh" \
    "$(grep '^ExecStart=' "$UNIT")" "scripts/stack-up.sh"

# --- a sandbox that runs the real script ------------------------------------

mkdir -p "$WORK/scripts" "$WORK/bin"
cp "$SCRIPT" "$REPO_DIR/scripts/lib.sh" "$REPO_DIR/scripts/run-if-enabled.sh" "$WORK/scripts/"

# One stub per declared hook, announcing itself so the run is a transcript.
hook_entries | sed 's/.*://' | sort -u | while read -r name; do
    printf '#!/bin/sh\necho "HOOK %s"\n' "$name" >"$WORK/scripts/$name"
done

printf '#!/bin/sh\necho "DOCKER $*"\n' >"$WORK/bin/docker"
chmod +x "$WORK/bin/docker"
PATH="$WORK/bin:$PATH"
export PATH

# run <compose-profiles-line> : the .env line to write, or "none" for a file
# with no COMPOSE_PROFILES at all. COMPOSE_PROFILES is unset in the
# environment, the way make (unlike systemd) leaves it.
run() {
    if [ "$1" = none ]; then
        : >"$WORK/.env"
    else
        printf 'COMPOSE_PROFILES=%s\n' "$1" >"$WORK/.env"
    fi
    shift
    env -u COMPOSE_PROFILES sh "$WORK/scripts/stack-up.sh" "$@" 2>&1 || true
}

# --- gating -----------------------------------------------------------------

out="$(run qbittorrent)"
contains "an ungated hook always runs"        "$out" "HOOK authelia-pre-start.sh"
contains "the selected service's hook runs"   "$out" "HOOK qbittorrent-pre-start.sh"
contains "and so does its bootstrap"          "$out" "HOOK qbittorrent-bootstrap.sh"
lacks    "an unselected service is skipped"   "$out" "HOOK prowlarr-pre-start.sh"

# A .env with no COMPOSE_PROFILES line is a pre-profiles install: everything is
# enabled, matching the unit's Environment=COMPOSE_PROFILES=all fallback.
out="$(run none)"
contains "no line at all means everything"    "$out" "HOOK prowlarr-pre-start.sh"

# Defined but empty is core-only — what docker compose itself does with it.
out="$(run "")"
contains "core hooks still run when empty"    "$out" "HOOK ntfy-pre-start.sh"
lacks    "empty selects no optional service"  "$out" "HOOK kavita-oidc-bootstrap.sh"

# --- ordering and the compose call ------------------------------------------

out="$(run all --remove-orphans)"
contains "compose is asked to start the stack" "$out" "DOCKER compose up -d --remove-orphans"

# Configuration is rendered before anything starts, bootstraps only after.
order="$(printf '%s\n' "$out" | grep -nE 'HOOK authelia-pre-start|DOCKER compose up|HOOK homepage-widgets')"
ok "pre-start, then up, then bootstrap" \
    "$(printf '%s\n' "$order" | sed 's/^[0-9]*://' | cut -d' ' -f1-2 | tr '\n' '|')" \
    "HOOK authelia-pre-start.sh|DOCKER compose|HOOK homepage-widgets-bootstrap.sh|"

# --- failure semantics ------------------------------------------------------
#
# The `-` prefix the unit used to carry, now expressed by the two lists: a
# pre-start failure must stop the start, a bootstrap failure must not.

printf '#!/bin/sh\nexit 1\n' >"$WORK/scripts/ntfy-pre-start.sh"
printf 'COMPOSE_PROFILES=all\n' >"$WORK/.env"
out="$(env -u COMPOSE_PROFILES sh "$WORK/scripts/stack-up.sh" 2>&1)" && rc=0 || rc=$?
ok       "a failed pre-start hook fails the start" "$rc" 1
lacks    "and nothing is started"                  "$out" "DOCKER compose up"
printf '#!/bin/sh\necho "HOOK ntfy-pre-start.sh"\n' >"$WORK/scripts/ntfy-pre-start.sh"

printf '#!/bin/sh\nexit 1\n' >"$WORK/scripts/pihole-bootstrap.sh"
out="$(env -u COMPOSE_PROFILES sh "$WORK/scripts/stack-up.sh" 2>&1)" && rc=0 || rc=$?
ok       "a failed bootstrap does not fail the start" "$rc" 0
contains "it warns instead"                           "$out" "pihole-bootstrap.sh failed"
contains "and the later bootstraps still run"         "$out" "HOOK homepage-widgets-bootstrap.sh"

# --- a hook that went missing -----------------------------------------------
#
# Same rule as a failure: fatal before the start, a warning after it.

rm -f "$WORK/scripts/kavita-oidc-bootstrap.sh"
out="$(env -u COMPOSE_PROFILES sh "$WORK/scripts/stack-up.sh" 2>&1)" && rc=0 || rc=$?
ok       "a missing bootstrap only warns"                "$rc" 0
contains "and it is named"                               "$out" "kavita-oidc-bootstrap.sh is missing"

rm -f "$WORK/scripts/backrest-pre-start.sh"
out="$(env -u COMPOSE_PROFILES sh "$WORK/scripts/stack-up.sh" 2>&1)" && rc=0 || rc=$?
ok       "a missing pre-start hook fails the start"      "$rc" 1
lacks    "and nothing is started either"                 "$out" "DOCKER compose up"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
