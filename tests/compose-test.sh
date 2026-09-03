#!/bin/sh
# Invariants compose.yaml must hold, checked against the config docker compose
# actually renders - anchors, merge keys, !reset and profiles all resolved, so
# these test what runs rather than what the file looks like.
#
# --no-interpolate on purpose: it leaves ${PASSWORD} literal, so no secret from
# .env ever enters this process, and none can reach a failure message.
# `docker compose config` never contacts the daemon, so this touches nothing.
# Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"

pass=0
fail=0

# stremio-lan is deliberately outside "all" - it is the alternative to stremio,
# never both - so it has to be named, or its block would go unchecked until
# someone enabled the profile.
PROFILES="all,stremio-lan"

if ! command -v docker >/dev/null 2>&1; then
    printf 'compose-test.sh: docker is required to render compose.yaml\n' >&2
    exit 1
fi

rendered="$(COMPOSE_PROFILES="$PROFILES" docker compose -f "$REPO_DIR/compose.yaml" \
    config --no-interpolate --format json 2>/dev/null)" || {
    printf 'compose-test.sh: docker compose config failed - run `docker compose config` to see why\n' >&2
    exit 1
}

out="$(printf '%s' "$rendered" | python3 "$TESTS_DIR/compose-invariants.py" "$REPO_DIR")" || {
    printf 'compose-test.sh: the invariant checker itself failed\n' >&2
    exit 1
}

# Each category is a class of drift, so a failure names every instance rather
# than only the first.
none() {
    _label="$1"
    _prefix="$2"
    _hits="$(printf '%s\n' "$out" | grep "^$_prefix " || true)"
    if [ -z "$_hits" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n' "$_label"
        printf '%s\n' "$_hits" | sed "s/^$_prefix /  /"
    fi
}

# The failure this file exists to catch: authelia once waited on lldap, which
# declared no healthcheck, so it never started and took the services behind it
# with it. Compose reports nothing - the dependency simply never resolves.
none "every service_healthy target declares a healthcheck" HEALTH

# A moving tag makes a rebuild non-reproducible and a rollback impossible.
none "every image is pinned by tag or digest" IMAGE

# A router reachable from the LAN with no middlewares has neither the ip
# allowlist nor forward auth on it.
none "every publicly routed router carries middlewares" ROUTER

# Adding a Postgres-backed service means adding its role, or it silently uses
# none and the password rotation misses it.
none "every Postgres-backed service owns a role" POSTGRES

# A rendering that half-breaks still returns something, and every check above
# would pass having inspected four services.
none "the rendered stack is the expected size" FLOOR

# --- the checker must actually catch each of them ---------------------------
#
# Five green assertions above prove nothing on their own: a checker that looks
# at the wrong key, or a rule that stops matching after a compose schema
# change, reports the same silence as a clean stack. So feed it a rendering
# that is broken on purpose, one category at a time.

catches() {
    _label="$1"
    _prefix="$2"
    _json="$3"
    _got="$(printf '%s' "$_json" | python3 "$TESTS_DIR/compose-invariants.py" "$REPO_DIR" \
        | grep -c "^$_prefix " || true)"
    if [ "$_got" -gt 0 ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s (the checker reported nothing)\n' "$_label"
    fi
}

catches "a service_healthy wait on a service with no healthcheck" HEALTH '{"services":{
  "waiter": {"image": "x:1", "depends_on": {"target": {"condition": "service_healthy"}}},
  "target": {"image": "x:1"}
}}'

catches "a service_healthy wait on a service this profile drops" HEALTH '{"services":{
  "waiter": {"image": "x:1", "depends_on": {"absent": {"condition": "service_healthy"}}}
}}'

catches "a moving tag" IMAGE '{"services": {"drifting": {"image": "somewhere/thing:latest"}}}'

catches "an image with no tag at all" IMAGE '{"services": {"untagged": {"image": "somewhere/thing"}}}'

catches "a public router with no middlewares" ROUTER '{"services": {"exposed": {"image": "x:1", "labels": {
  "traefik.http.routers.exposed.rule": "Host(`x`)",
  "traefik.http.routers.exposed.entrypoints": "websecure"
}}}}'

catches "a Postgres-backed service with no role" POSTGRES '{"services":{
  "newthing": {"image": "x:1", "depends_on": {"postgres": {"condition": "service_started"}}}
}}'

catches "a rendering that came back nearly empty" FLOOR '{"services": {"lonely": {"image": "x:1"}}}'

printf '%s\n' "$out" | grep '^CHECKED ' | sed 's/^CHECKED/compose-test.sh: checked/'
printf '\ncompose-test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
