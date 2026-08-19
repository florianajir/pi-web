#!/bin/sh
# Bootstrap Kapowarr: add the /comics root folder and register qBittorrent as an
# external download client (idempotent). Kapowarr shares gluetun's namespace; its own
# API is at localhost:5656, but qBittorrent must be reached at gluetun:8080 (localhost
# returns 403 — see QB_BASE_URL note below).
# The image ships no curl/jq, so we drive its (undocumented) API with the bundled
# python3. Credentials are passed via the environment, never on the command line.
# Runs as ExecStartPost after docker compose up. Best-effort (warns, never fails start).

set -eu

. "$(dirname "$0")/lib.sh"

KAPOWARR_CONTAINER="${KAPOWARR_CONTAINER:-pi-kapowarr}"

main() {
    container_is_running "$KAPOWARR_CONTAINER" || { log "Kapowarr not running, skipping"; return 0; }

    local user password
    user="$(get_env_value ADMIN_USER)"
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

# download_folder MUST be /downloads (only path mounted identically in both Kapowarr and
# qBittorrent) so torrents qBittorrent saves are found and imported into /comics.
# flaresolverr_base_url lets Kapowarr solve Cloudflare on GetComics (same solver Prowlarr uses).
DESIRED_SETTINGS = {
    "download_folder": "/downloads",
    "flaresolverr_base_url": "http://flaresolverr:8191",
}
try:
    _, res = call("GET", "/settings", params={"api_key": key})
    cur = res.get("result", {})
    changed = {k: v for k, v in DESIRED_SETTINGS.items()
               if (cur.get(k) or "").rstrip("/") != v.rstrip("/")}
    if changed:
        call("PUT", "/settings", params={"api_key": key}, body=changed)
        log("Updated settings: " + ", ".join(sorted(changed)))
    else:
        log("Settings already correct (download_folder, flaresolverr_base_url)")
except Exception as e:
    log(f"WARNING: settings step failed: {e}")

QB_BASE_URL = "http://gluetun:8080"
if USER and PASS:
    try:
        _, res = call("GET", "/externalclients", params={"api_key": key})
        clients = res.get("result") or []
        existing = next((c for c in clients if c.get("title") == "qBittorrent"), None)
        body = {
            "title": "qBittorrent",
            "base_url": QB_BASE_URL,
            "username": USER,
            "password": PASS,
            "api_token": None,
        }
        if existing is None:
            call("POST", "/externalclients", params={"api_key": key},
                 body={"client_type": "qBittorrent", **body})
            log("Added qBittorrent external client")
        elif existing.get("base_url") != QB_BASE_URL:
            # Migrate a stale base_url (e.g. http://localhost:8080 -> gluetun).
            call("PUT", f"/externalclients/{existing['id']}", params={"api_key": key}, body=body)
            log(f"Updated qBittorrent external client base_url to {QB_BASE_URL}")
        else:
            log("qBittorrent external client already present")
    except Exception as e:
        log(f"WARNING: external client step failed: {e}")
else:
    log("ADMIN_USER/PASSWORD not set; skipping qBittorrent client")
PY

    log "Kapowarr bootstrap complete"
}

main "$@"
