## Copilot Project Instructions

Purpose: Make AI agents immediately productive when extending the `pi-web` Raspberry Pi self‑hosting stack (Traefik, Pi-hole, Netdata, Portainer, n8n) while keeping changes safe and minimal.

### 1. Architecture (What Exists Today)
Single Docker Compose file (`compose.yaml`) plus a tiny CI overlay (`compose.test.yaml`) that only neutralizes Pi-hole host DNS port usage. Service groups:
- Edge: `traefik` (v3.4) – central TLS / routing (HTTPS only, HTTP redirected). Dashboard exposed via router `traefik`.
- Monitoring: `netdata` (real-time host+container metrics on port 19999), `portainer` (container management UI behind Traefik).
- Productivity: `nextcloud` (28-apache) served behind Traefik with private storage, backed by `db` (MariaDB 11.4) and `redis` cache on an internal network.
- Infra / Utility: `pihole` (DNS + optional DHCP via macvlan `lan` network), `n8n` (automation), `watchtower` (image updates).
- Networks: `frontend` (routed HTTP services), `lan` (macvlan for Pi‑hole DHCP/IP). Network names are fixed via `name:` to satisfy Traefik provider lookups.
- Persistence: Named volumes `netdata_config`, `netdata_lib`, `netdata_cache`, `portainer_data`, `pihole_data`, `n8n_data`, `wireguard_config`.

### 2. Key Conventions & Patterns
- Traefik exposure: Add labels `traefik.enable=true`, host rule `Host(`<service>.${HOST_NAME}`)` and explicit `loadbalancer.server.port=<internal_port>`; do NOT publish container ports (except required external protocols: Pi-hole DNS, Traefik 80/443).
- Healthchecks: Use lightweight CLI (`wget` for HTTP `/api/health` or service health; `dig`/`nslookup` for DNS). Follow existing intervals (30s) and retry (3) unless strong reason.
- Memory: Every runtime service sets `mem_limit` (common ranges: 128m–1g). Mirror pattern for new services.
- Environment: All runtime values come from `.env`; template new required keys in `.env.dist` only (never commit secrets). Prefer bash parameter defaults: `${VAR:-default}` for resiliency.
- Networks: Only attach what you need. Public UI -> `frontend`. Netdata uses host network mode for full host visibility.
- Labels: Keep them minimal; existing `com.example.*` labels are descriptive only—replicate for consistency when adding volumes / services.
- WireGuard specifics: Requires `NET_ADMIN` + `SYS_MODULE`, mounts `/lib/modules`, and maps UDP `${WIREGUARD_SERVER_PORT:-51820}`. Default DNS for peers should match Pi-hole (`WIREGUARD_PEER_DNS` == `PIHOLE_IP`). Persist peer configs under `wireguard_config/` and treat them as secrets.

### 3. Security & Exposure
- LAN-only expectation: Do NOT introduce public Internet exposure or open extra host ports. Future remote access should remain VPN-based (WireGuard external or future in-stack implementation).
- Optional IP allowlist middleware currently commented out; if re‑enabling, pattern (uncomment & adapt):
  - `traefik.http.middlewares.lan.ipallowlist.sourcerange=${ALLOW_IP_RANGES}`
  - Apply via `traefik.http.routers.<service>.middlewares=lan`
- `--serversTransport.insecureSkipVerify=true` intentionally tolerates self-signed backend certs—don’t remove casually.

### 4. Monitoring Integration
- Netdata: Runs with host network mode on port 19999, auto-discovers containers via Docker socket. No configuration files needed. Optional Netdata Cloud connection via `NETDATA_CLAIM_TOKEN` env var.
- Portainer: Container management UI routed through Traefik. Provides Docker visibility without CLI access.

### 5. CI & Validation
- Lint / syntax: GitHub Actions (`.github/workflows/ci.yml`) runs `docker compose config` (with and without test overlay) + `yamllint` (config in `.yamllint`). Maintain 2‑space indent, 120 char width.

- ARM check workflow (`raspberry-pi.yml`) pulls images with `--platform linux/arm64`. When adding a new image, replicate a simple `docker run --platform ... --version` probe.
- Test overlay (`compose.test.yaml`) must stay minimal: override only conflicting host bindings (currently Pi-hole port 53). Don’t duplicate base service specs.

### 6. Systemd / Operations
- `make install` renders `config/systemd/system/pi-web.service` (replacing `__PROJECT_PATH__`) into `/etc/systemd/system/`. Never hardcode absolute paths in the repo.
- Operational commands: `make start|stop|restart|status|logs|update`. Keep emoji + concise log style if adding targets.

### 7. Adding a Service (Practical Checklist)
1. Define service in `compose.yaml`: image tag (avoid `latest` if upstream offers stable tags), `restart: unless-stopped`, `mem_limit`, `expose` (not `ports`) unless protocol requires host binding.
2. Healthcheck matching existing cadence (prefer `CMD` array form).
3. Attach networks: `frontend` only if it needs HTTP routing.
4. Traefik labels: host rule + `loadbalancer.server.port`. Add middleware only if already defined (avoid inventing new ones inline).
5. Persistent data: Add named volume with descriptive labels if stateful.
6. Update `.env.dist` for any new required vars (document defaults with comments if needed).
7. Extend ARM test workflow with a one‑line version probe.
8. Run local validation: `docker compose -f compose.yaml config` (and with overlay) before committing.

### 8. Common Pitfalls to Avoid
- Exposing raw container ports instead of routing through Traefik.
- Forgetting `mem_limit` (causes risk on constrained Pi hardware).
- Removing macvlan network config needed for Pi‑hole DHCP.

### 9. PR Expectations
- Keep diffs minimal & scoped. Provide a short rationale (purpose + exposure + metrics) in PR description.
- No sweeping reformatting or dependency “cleanup” PRs.
- Avoid adding narrative or redundant inline comments that merely describe the change (the diff is sufficient). Only introduce or retain comments that convey lasting operational, architectural, or configuration intent.

### 10. Reproducibility Rule (File-First Changes)
- Treat repository files as the source of truth. Any operational fix must be implemented in tracked files (`compose.yaml`, scripts, templates, docs, etc.) so it survives `make install` / `make start` and fresh deployments.
- Do not leave production fixes as container-only manual changes. Runtime/container commands may be used for debugging or emergency mitigation, but the corresponding durable file change is required in the same work.
- If a temporary in-container action is performed to unblock users, immediately follow with the file-based patch and validation steps.

Questions / unclear areas? Open an issue or request clarifications—update this file after consensus.
