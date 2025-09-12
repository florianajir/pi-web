# Copilot Project Instructions

Purpose: Help AI agents contribute effectively to the `pi-web` Raspberry Pi self‑hosting stack (Traefik, Pi-hole, Prometheus, Grafana, n8n) with consistent patterns and safe changes.

## Core Architecture
- Single Docker Compose stack (`compose.yaml`) + optional test overlay (`compose.test.yaml` for CI: removes privileged host DNS ports for Pi-hole).
- Service groups:
  - Edge / Routing: `traefik` (TLS, HTTP->HTTPS redirect, basic auth middleware for internal UIs like Prometheus dashboard).
  - Monitoring: `prometheus`, `grafana`, `cadvisor`, `node-exporter` (two logical networks: `monitoring` internal, `frontend` public‑facing).
  - Infrastructure: `pihole` (DNS + ad-block), `watchtower` (auto image updates), `n8n` (workflow automation).
- Persistence via named volumes: `grafana-data`, `prometheus-data`, `traefik_data`, `pihole_data`, `n8n_data`.
- Systemd wrapper (`config/systemd/system/*.service|*.timer`) provides host-level lifecycle; `Makefile` materializes path placeholders (`__PROJECT_PATH__`).

## Conventions & Patterns
- All externally exposed UIs are routed through Traefik using labels `traefik.http.routers.<service>...` with host pattern: `<service>.${HOST_NAME}`.
- Healthchecks: Each service declaring HTTP health uses lightweight `wget` or protocol‑appropriate CLI (`dig` for Pi-hole). Reuse style when adding services.
- Resource governance: Every service pins `mem_limit`; mirror pattern for new services to preserve Pi constraints.
- Networks: Public access services attach to `frontend`; pure exporters attach only to `monitoring` unless Traefik routing required.
- Environment variable source: root `.env` (runtime) + `.env.dist` (template). Never commit secrets; extend `.env.dist` when introducing new required vars.
- Avoid exposing container ports directly—prefer Traefik unless protocol (DNS :53) or metrics scraping requires otherwise.
- CI overlay (`compose.test.yaml`) is minimal; only override exactly what blocks shared runners (e.g., privileged / reserved ports).

## Developer & CI Workflow
- Linting: YAML style enforced via `.yamllint` (120 char width, relaxed rules). Keep new YAML aligned.
- CI jobs: `lint` validates compose syntax (`docker compose -f compose.yaml -f compose.test.yaml config`), runs yamllint, optional Prometheus config validation (note: path in workflow is legacy—actual config lives at `config/prometheus/prometheus.yml`; adjust if refactoring).
- ARM compatibility: `raspberry-pi.yml` executes multi-arch image version checks. If adding images, mirror test block with `docker run --platform ${{ matrix.platform }} --rm <image> --version`.
- Security scan: Trivy file system scan; no custom suppression logic—prefer fixing base image tags.

## File / Directory Landmarks
- `compose.yaml`: Source of truth for services; replicate label / memory / healthcheck patterns exactly.
- `compose.test.yaml`: Only CI-safe overrides; do not duplicate base config.
- `config/prometheus/prometheus.yml`: Add new scrape targets; keep 15s `scrape_interval` unless justified. Use static_configs; no service discovery here.
- `config/grafana/provisioning/`: Datasource + dashboards provisioning. Provide fixed `uid` when adding datasources to avoid duplication.
- `config/systemd/system/pi-web.service`: Contains placeholder path token—do not hardcode absolute paths in repo.
- `Makefile`: Only declarative orchestration; keep output emojis & messaging style when adding targets.

## Adding a New Service (Example Checklist)
1. Add service block to `compose.yaml` with: image, `restart: unless-stopped`, memory limits, healthcheck, labels for Traefik (if HTTP UI) or internal only.
2. Attach correct networks (`frontend` if routed; `monitoring` if scraped).
3. Add volume for persistent state (named volume + label) if data durability required.
4. If UI should be gated: append middleware `global-auth` OR define a new middleware if special headers needed.
5. Update Prometheus config if metrics endpoint exists (static target `service-name:port`).
6. Extend ARM test workflow with compatibility probe.
7. Add any new required env vars to `.env.dist` (never commit secrets).

## Basic Auth & Security
- TLS: ACME HTTP challenge on entrypoint `web` auto-manages certificates stored in `traefik_data` volume.
- `--serverstransport.insecureskipverify=true` is set intentionally (internal self-signed cases); do not remove without verifying upstream cert chain.

## Network Exposure & Remote Access Policy
- Policy: All Traefik-routed services are intended to be reachable only from the local LAN; do NOT create Internet-facing port forwards (80/443) to this stack.
- Remote (outside LAN) access MUST occur exclusively through a WireGuard VPN terminating inside the LAN. Until a WireGuard service is added to `compose.yaml`, use a host-level or separate appliance WireGuard instance—do not bypass by exposing Traefik publicly.
- When adding a new HTTP service: treat it as private-by-default. Open an issue before proposing any public exposure.
- Enforce LAN scoping via an ip whitelist middleware chained with auth. Pattern (reuse `ALLOW_IP_RANGES` from `.env`):
  Example labels snippet for a new service:
  traefik.http.middlewares.lan-only.ipallowlist.sourcerange=${ALLOW_IP_RANGES}
    traefik.http.routers.<service>.middlewares=global-auth,lan-only
- Do not add global WAN CIDRs (e.g. 0.0.0.0/0) to `ALLOW_IP_RANGES`.
- If a future WireGuard service is integrated, update docs instead of altering exposure strategy for existing services.

## Performance / Monitoring Notes
- Prometheus retention tuned (1y / 10GB). If adjusting, keep both time and size flags paired.
- cAdvisor restricted (`-docker_only=true`, label storage disabled) to reduce overhead—retain unless higher granularity required.

## When Editing Dashboards
- Maintain datasource `uid: p1w3b` for Prometheus queries to avoid provisioning duplicates.
- Large JSON dashboards should stay under version control; avoid manual edits inside container.

## PR Guidance for Agents
- Keep diffs minimal; do not mass reformat YAML (line length <=120, indentation 2 spaces).
- Validate with: `docker compose -f compose.yaml config` locally before proposing.
- If adding service: include short rationale in PR body (purpose + network exposure + auth decision).

## Out of Scope
- WireGuard service is mentioned in README but not yet implemented in `compose.yaml`; do not reference operational steps until added. (Remote access expectation remains: use VPN, never direct public Traefik exposure.)

Feedback welcome: highlight unclear conventions or missing workflow details in follow-up.
