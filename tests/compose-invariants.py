"""Invariants compose.yaml must hold, checked against the rendered config.

Reads `docker compose config --format json` on stdin and prints one line per
finding, prefixed by category, for tests/compose-test.sh to assert on. Nothing
here reads .env: the caller renders with --no-interpolate, so a password stays
the literal ${PASSWORD} and never enters this process.
"""

import json
import re
import sys
from pathlib import Path

# --- deliberate exceptions, each with the reason it is not a bug -------------

# depends_on: service_healthy targets whose healthcheck is baked into the image
# instead of compose.yaml. Compose honours those, but the file itself says
# nothing, which is exactly how a *missing* healthcheck stays invisible - so
# each one is named here rather than skipped by a rule.
IMAGE_HEALTHCHECK = {
    # docker image inspect ghcr.io/immich-app/immich-server
    #   -> {"Test": ["CMD-SHELL", "immich-healthcheck"]}
    "immich-server": "the image ships HEALTHCHECK immich-healthcheck",
}

# Traefik entrypoints that are not published to the LAN. A router there needs no
# middleware: `internalapi` serves api@internal on :8080 to Homepage's widget.
INTERNAL_ENTRYPOINTS = {"traefik"}

# Talks to postgres without owning a role: backrest is the backup client, it
# reads every database through the superuser.
NO_PG_ROLE = {"backrest"}

# Where the compose service name and the postgres role name differ.
PG_ROLE_ALIAS = {"immich-server": "immich"}

# Floors, not just non-empty checks: a profile list that half-breaks still
# renders *something*, and every assertion below would pass having inspected
# four services. Raise these when the stack grows well past them, and never
# lower one to make a failure go away.
MIN_SERVICES = 38
MIN_ROUTERS = 28
MIN_HEALTH_DEPS = 18


def labels_of(service):
    labels = service.get("labels") or {}
    if isinstance(labels, list):
        return dict(item.split("=", 1) for item in labels if "=" in item)
    return labels


def routers_of(services):
    routers = {}
    for name, service in services.items():
        for key, value in labels_of(service).items():
            match = re.match(r"traefik\.http\.routers\.([^.]+)\.(.+)", key)
            if match:
                router = routers.setdefault(match.group(1), {"_service": name})
                router[match.group(2)] = value
    return routers


def postgres_roles(repo_dir):
    """The one list that creates a role and a database per service."""
    source = Path(repo_dir, "config/postgres/init-databases.sh").read_text()
    match = re.search(r'^SERVICES="([^"]+)"', source, re.M)
    if not match:
        return None
    return set(match.group(1).split())


def main():
    repo_dir = sys.argv[1]
    config = json.load(sys.stdin)
    services = config["services"]
    findings = []

    def report(category, message):
        findings.append(f"{category} {message}")

    if len(services) < MIN_SERVICES:
        report("FLOOR", f"rendered only {len(services)} services, expected at least {MIN_SERVICES}")

    health_deps = 0
    for name, service in sorted(services.items()):
        for target, spec in sorted((service.get("depends_on") or {}).items()):
            if spec.get("condition") != "service_healthy":
                continue
            health_deps += 1
            if target not in services:
                report("HEALTH", f"{name} waits on {target}, which this profile does not render")
            elif not services[target].get("healthcheck") and target not in IMAGE_HEALTHCHECK:
                report("HEALTH", f"{name} waits for {target} to be healthy, but {target} declares no healthcheck")

    if health_deps < MIN_HEALTH_DEPS:
        report("FLOOR", f"found only {health_deps} service_healthy dependencies, expected at least {MIN_HEALTH_DEPS}")

    for name, service in sorted(services.items()):
        image = service.get("image")
        if not image:
            if not service.get("build"):
                report("IMAGE", f"{name} has neither an image nor a build")
            continue
        tag = image.rsplit("/", 1)[-1]
        if "@sha256:" in image or tag.endswith(":local"):
            continue
        if ":" not in tag:
            report("IMAGE", f"{name} uses {image}, which has no tag")
        elif re.search(r":(latest|stable|main|master|edge|nightly)$", image):
            report("IMAGE", f"{name} uses {image}, a moving tag")

    routers = routers_of(services)
    if len(routers) < MIN_ROUTERS:
        report("FLOOR", f"found only {len(routers)} Traefik routers, expected at least {MIN_ROUTERS}")

    for router, spec in sorted(routers.items()):
        if "rule" not in spec:
            continue
        if spec.get("entrypoints") in INTERNAL_ENTRYPOINTS:
            continue
        if "middlewares" not in spec:
            report("ROUTER", f"{router} ({spec['_service']}) is routed publicly with no middlewares")

    roles = postgres_roles(repo_dir)
    if roles is None:
        report("POSTGRES", 'could not read SERVICES="..." from config/postgres/init-databases.sh')
    else:
        backed = {
            name for name, service in services.items()
            if "postgres" in (service.get("depends_on") or {})
        }
        for name in sorted(backed - NO_PG_ROLE):
            if PG_ROLE_ALIAS.get(name, name) not in roles:
                report("POSTGRES", f"{name} depends on postgres but init-databases.sh creates no role for it")
        expected = {PG_ROLE_ALIAS.get(name, name) for name in backed}
        for role in sorted(roles - expected):
            report("POSTGRES", f"init-databases.sh creates role {role}, which no service depends on postgres for")

    for finding in findings:
        print(finding)
    print(f"CHECKED {len(services)} services, {health_deps} health dependencies, {len(routers)} routers")


main()
