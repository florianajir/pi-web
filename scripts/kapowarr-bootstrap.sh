#!/bin/sh
# Bootstrap Kapowarr: add the /comics root folder and register qBittorrent as an
# external download client (idempotent). Kapowarr shares gluetun's namespace, so
# qBittorrent is reachable at localhost:8080 and the API at localhost:5656.
# The image ships no curl/jq, so we drive its (undocumented) API with the bundled
# python3. Credentials are passed via the environment, never on the command line.
# Runs as ExecStartPost after docker compose up. Best-effort (warns, never fails start).

set -e

. "$(dirname "$0")/lib.sh"

KAPOWARR_CONTAINER="${KAPOWARR_CONTAINER:-pi-kapowarr}"

main() {
    container_is_running "$KAPOWARR_CONTAINER" || { log "Kapowarr not running, skipping"; return 0; }

    local user password
    user="$(get_env_value USER)"
    password="$(get_env_value PASSWORD)"

    KAP_USER="$user" KAP_PASS="$password" docker exec -i \
        -e KAP_USER -e KAP_PASS "$KAPOWARR_CONTAINER" python3 - <<'PY'
import json, os, time, urllib.parse, urllib.request

BASE = "http://localhost:5656/api"
USER = os.environ.get("KAP_USER") or None
PASS = os.environ.get("KAP_PASS") or None


def call(method, path, params=None, body=None):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status, json.loads(r.read() or b"{}")


def log(msg):
    print(f"[kapowarr-bootstrap] {msg}", flush=True)


# Wait for the API and obtain the api_key. Fresh installs have no auth password,
# so /auth returns the key regardless of the credentials we send.
key = None
for _ in range(60):
    try:
        _, res = call("POST", "/auth", body={"username": USER, "password": PASS})
        key = (res.get("result") or {}).get("api_key")
        if key:
            break
    except Exception:
        pass
    time.sleep(5)

if not key:
    log("WARNING: could not obtain API key; skipping")
    raise SystemExit(0)

# Root folder /comics (idempotent).
try:
    _, res = call("GET", "/rootfolder", params={"api_key": key})
    # Kapowarr stores paths with a trailing slash (/comics/), so normalise before comparing.
    folders = [(rf.get("folder") or "").rstrip("/") for rf in (res.get("result") or [])]
    if "/comics" not in folders:
        call("POST", "/rootfolder", params={"api_key": key}, body={"folder": "/comics"})
        log("Added root folder /comics")
    else:
        log("Root folder /comics already present")
except Exception as e:
    log(f"WARNING: root folder step failed: {e}")

# qBittorrent external client (idempotent), only when credentials are available.
if USER and PASS:
    try:
        _, res = call("GET", "/externalclients", params={"api_key": key})
        titles = [c.get("title") for c in (res.get("result") or [])]
        if "qBittorrent" not in titles:
            call("POST", "/externalclients", params={"api_key": key}, body={
                "client_type": "qBittorrent",
                "title": "qBittorrent",
                "base_url": "http://localhost:8080",
                "username": USER,
                "password": PASS,
                "api_token": None,
            })
            log("Added qBittorrent external client")
        else:
            log("qBittorrent external client already present")
    except Exception as e:
        log(f"WARNING: external client step failed: {e}")
else:
    log("USER/PASSWORD not set; skipping qBittorrent client")
PY

    log "Kapowarr bootstrap complete"
}

main "$@"
