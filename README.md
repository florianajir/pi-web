# pi-web

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://docker.com/)
[![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-Compatible-red.svg)](https://www.raspberrypi.org/)

Turn your Raspberry Pi into a compact self‑hosted platform: VPN, DNS-level ad blocking, reverse proxy with TLS, file sync, automation, and full monitoring — all declaratively managed with one `docker compose` stack.

---

## Table of Contents
- [Overview & Goals](#overview--goals)
- [Architecture](#architecture)
- [Feature Matrix](#feature-matrix)
- [Hardware & Prerequisites](#hardware--prerequisites)
- [Quick Start](#quick-start)
- [Directory Layout](#directory-layout)
- [Configuration Model](#configuration-model)
- [Service Deep Dive](#service-deep-dive)
- [Operations (Make Targets)](#operations-make-targets)
- [Monitoring & Observability](#monitoring--observability)
- [Security & Hardening](#security--hardening)
- [Backups & Recovery](#backups--recovery)
- [Updating & Upgrading](#updating--upgrading)
- [Adding a New Service](#adding-a-new-service)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License & Acknowledgments](#license--acknowledgments)

---

## Overview & Goals
Provide a reliable, reproducible, low‑touch self‑hosting baseline optimized for constrained ARM boards (Raspberry Pi). Core design principles:
- Single source of truth (`compose.yaml` + `.env`)
- Minimum privileged exposure (only required host ports published)
- Memory limits everywhere to prevent host exhaustion
- Static, explicit monitoring targets (no surprise discovery)
- Easy rollback (git + volumes)

## Architecture

Logical groups:
- Edge: Traefik (HTTPS termination, routing)
- Connectivity: WireGuard (remote VPN), Pi-hole (DNS, optional DHCP)
- Productivity: Nextcloud, n8n
- Monitoring: Netdata (real-time metrics), Portainer (container management)
- Maintenance: Watchtower (optional image housekeeping)

Network layout:
- `frontend` (bridge) – Public HTTP(S) routed services
- `lan` (macvlan) – Pi-hole obtains a LAN IP for DHCP/DNS
- `nextcloud` (internal bridge) – App ↔ DB/Redis isolation

Data persistence via named volumes (e.g. `nextcloud_data`, `netdata_lib`, `portainer_data`, `wireguard_config`).

## Feature Matrix
| Capability | Implemented | Notes |
|------------|-------------|-------|
| Reverse proxy & TLS | ✔ | Traefik v3 (HTTP→HTTPS redirect) |
| VPN remote access | ✔ | WireGuard (auto peers) |
| DNS filtering | ✔ | Pi-hole (macvlan) |
| File sync & collaboration | ✔ | Nextcloud 28-apache |
| Automation workflows | ✔ | n8n |
| Real-time monitoring | ✔ | Netdata (host + containers) |
| Container management | ✔ | Portainer CE |
| Automatic image updates | ✔ | Watchtower (no auto restarts) |
| Dynamic DNS (Cloudflare) | ✔ | ddns-updater keeps `pi.*` records synced |
| Memory safeguarding | ✔ | `mem_limit` on each container |

## Hardware & Prerequisites
Minimum tested baseline: Raspberry Pi 4 (4GB RAM) + 32GB SD (or SSD). Recommended: SSD storage and 4GB+ RAM.

Requirements:
- Linux with Docker & Docker Compose plugin
- Outbound internet for image pulls
- (Optional) Control of LAN DNS or ability to edit `/etc/hosts` for `*.${HOST_NAME}` resolution

Kernel / cgroup memory enforcement strongly advised (see Section 5 – Quick Start → Memory Enablement).

## Quick Start
```bash
git clone https://github.com/florianajir/pi-web.git
cd pi-web
cp .env.dist .env   # Edit values (HOST_NAME, IPs, credentials, etc.)
make install        # Installs systemd unit
make start          # Launch stack
make status         # Verify health
```

Access services at: `https://<service>.${HOST_NAME}` (Traefik, Portainer, Nextcloud, n8n, Pi-hole dashboard). Netdata is available at `http://<HOST_IP>:19999`.

### Memory / cgroup Readiness
Run:
```bash
make preflight
```
Follow emitted guidance if memory limits are not enforced (enable cgroup flags or systemd driver as needed).

## Directory Layout
High‑level relevant paths:
```
compose.yaml                # Core stack definition
compose.test.yaml           # CI overlay (neutralizes conflicting host bindings)
.env.dist                   # Template environment (copy to .env)
config/pihole/              # Pi-hole dnsmasq snippets
config/systemd/system/      # Systemd unit templates (rendered by make install)
data/                       # Persistent volumes (bind-mounted or named)
scripts/                    # Utility scripts / helpers
AGENTS.md                   # Contribution & repo guidelines
```

## Configuration Model
All operational knobs live in `.env` (copy from `.env.dist`). Anything not in `.env.dist` is intentionally opinionated and set in `compose.yaml`.

Patterns:
- Use `${VAR:-default}` fallbacks in compose to permit safe omission
- Avoid adding variables unless end users must regularly change them
- Secrets never live in git (only sample defaults in `.env.dist`)

Domain convention: `<service>.${HOST_NAME}`. Override by changing `HOST_NAME` (ensure DNS/Wildcard mapping to host IP or add entries to local resolvers).

## Service Deep Dive

### 7.1 Global / Shared Variables
| Var | Purpose |
|-----|---------|
| HOST_NAME | Base internal domain suffix |
| TIMEZONE | TZ for logs & scheduling |
| EMAIL | Admin contact / Nextcloud & Grafana bootstrap |
| USER / PASSWORD | Initial admin credentials (rotate after bootstrap) |
| PUID / PGID | Filesystem UID/GID mapping for compatible images |
| ALLOW_IP_RANGES | Optional IP allowlist (Traefik middleware) |

### 7.2 Network & LAN
| Var | Purpose |
|-----|---------|
| PIHOLE_IP | Macvlan IP for Pi-hole (DNS/DHCP) |
| HOST_IP | Host LAN IP (wildcard resolves here for reverse proxy) |
| LAN_PARENT | Physical NIC used by macvlan |
| LAN_SUBNET | CIDR for macvlan |
| LAN_GATEWAY | Default gateway inside macvlan |

### 7.3 DHCP (Pi-hole)
| Var | Purpose |
|-----|---------|
| DHCP_ACTIVE | Enable built-in DHCP |
| DHCP_START / DHCP_END | Lease range |
| DHCP_ROUTER | Router advertised |
| DHCP_LEASE_TIME | Lease (hours) |

### 7.4 Nextcloud
| Var | Purpose |
|-----|---------|
| NEXTCLOUD_DB_NAME | DB name |
| NEXTCLOUD_DB_USER | DB user |
| NEXTCLOUD_DB_PASSWORD | DB password |
| NEXTCLOUD_DB_ROOT_PASSWORD | Root password (admin ops only) |
| NEXTCLOUD_TRUSTED_PROXIES | Trusted proxy CIDR(s) |

### 7.5 WireGuard (Runtime Provisioning)
On first start the container:
1. Generates server keys
2. Creates `WIREGUARD_PEERS` client configs
3. Allocates from `WIREGUARD_INTERNAL_SUBNET` (server `.1`)
4. Applies `WIREGUARD_PEER_DNS` and `WIREGUARD_ALLOWED_IPS`

| Var | Purpose |
|-----|---------|
| WIREGUARD_SERVER_URL | DNS / public endpoint |
| WIREGUARD_SERVER_PORT | UDP port |
| WIREGUARD_PEERS | Initial peer count |
| WIREGUARD_PEER_DNS | DNS pushed to clients |
| WIREGUARD_INTERNAL_SUBNET | VPN subnet (CIDR) |
| WIREGUARD_ALLOWED_IPS | AllowedIPs per peer |

Add peers later: stop stack, raise `WIREGUARD_PEERS`, start again (image appends new peers only). Revocation via `wg set wg0 peer <PUBKEY> remove` inside container.

### 7.6 Observability Stack
Netdata: Lightweight real-time monitoring agent running with host network mode on port 19999. Provides host metrics (CPU, RAM, disk, network) and Docker container metrics via socket access. Optional Netdata Cloud connection via claim tokens.  
Portainer: Container management UI routed through Traefik at `portainer.${HOST_NAME}`. Provides Docker environment visibility, container logs, and management capabilities.

### 7.7 Traefik
Configured via command flags + per‑service labels:
- HTTP→HTTPS redirect
- Optional IP allowlist (commented middleware)
- `--serversTransport.insecureSkipVerify=true` to tolerate self‑signed upstreams

#### 7.7.1 Cloudflare DNS‑01 (ACME) for valid LAN TLS
When clients (e.g., Tailscale) must trust HTTPS for `headscale.${HOST_NAME}`, Traefik can obtain a real certificate via Cloudflare DNS‑01 (free).

**Prereqs**
- Your base domain is hosted in Cloudflare.
- You can create a Cloudflare API token with **Zone → DNS → Edit** permission for that zone.

**Setup**
1. Set the token in `.env`:
	- `CF_DNS_API_TOKEN=...`
2. Restart Traefik:
	- `docker compose -f compose.yaml up -d traefik`

Traefik will request certificates for routed services (including `headscale.${HOST_NAME}`) using DNS‑01 and store them in the `traefik_letsencrypt` volume.

### 7.8 n8n
Runs with persistent volume; environment includes host, protocol, timezone. Extend via additional `N8N_*` variables in compose if needed.

### 7.9 Pi-hole
Uses macvlan IP; wildcard DNS maps all `<anything>.${HOST_NAME}` to `HOST_IP` enabling Traefik SNI routing. DHCP optional via env toggles.

### 7.10 Watchtower
Scheduled cleanup & image checks (`WATCHTOWER_*` env in compose). Restart control set to “no auto restart” to prevent surprise downtime; manual `make update` remains authoritative.

### 7.11 Cloudflare DDNS (ddns-updater)
Keeps your public DNS records in Cloudflare synced to your current public IP so `pi.${HOST_NAME}` and `*.pi.${HOST_NAME}` stay reachable.

Required `.env` keys:
- `CF_DNS_API_TOKEN` (DNS edit token)
- `CF_ZONE_ID` (Cloudflare Zone ID for your domain)
The updater will manage `HOST_NAME` and `*.HOST_NAME` automatically.

## Operations (Make Targets)
| Target | Action |
|--------|--------|
| make install | Render & install systemd unit/timers |
| make start | Start stack (systemd) |
| make stop | Stop stack |
| make restart | Restart stack |
| make status | Show systemd unit status |
| make logs | Follow aggregated container logs |
| make update | Git fast‑forward + restart |
| make preflight | Environment readiness (Docker, cgroups) |

Examples:
```bash
make preflight
make start
make logs
make update
```

## Monitoring & Observability
Netdata provides real-time monitoring out of the box:
- Access at `http://<HOST_IP>:19999`
- Auto-discovers and monitors all Docker containers
- Collects host metrics (CPU, memory, disk I/O, network)
- Optional: Connect to Netdata Cloud for centralized dashboards (set `NETDATA_CLAIM_TOKEN` in `.env`)

Portainer provides container management:
- Access at `https://portainer.${HOST_NAME}`
- View container logs, stats, and configurations
- Manage Docker volumes and networks

## Security & Hardening
Principles:
- No public HTTP (HTTPS only; HTTP redirected)
- Minimal published ports: 80/443 (Traefik) + UDP WireGuard + Pi-hole DNS (when enabled)
- Per‑service memory limits reduce blast radius
- Secrets stay outside git (volumes + local `.env`)

Recommendations:
- Rotate `USER` / `PASSWORD` after initial bootstrap
- Consider enabling Traefik allowlist middleware for admin UIs
- Keep WireGuard keys private; regenerate if exposed
- Regularly apply upstream image updates (`make update` then check change logs)

## Backups & Recovery
What to back up (volumes / data paths):
- Nextcloud (`nextcloud_data`) – files + app code + config
- MariaDB (`nextcloud_db`) – use `mariadb-dump` periodically
- Netdata (`netdata_config`, `netdata_lib`) – optional, regenerated on start
- Portainer (`portainer_data`) – settings, users, stacks
- n8n (`n8n_data`) – workflows & credentials
- WireGuard (`wireguard_config`) – server/peer keys & configs
- Pi-hole (`pihole_data`) – settings, gravity list, DHCP leases

Suggested approach: stop stack (or quiesce), snapshot volumes (bind-mount and tar, or use volume backup plugin). Store encrypted off‑device.

## Updating & Upgrading
Routine update:
```bash
make update
```
This performs `git pull --ff-only` then restarts the stack (containers pull newer images if tags moved). For image refresh without repo changes rely on Watchtower schedule or manually `docker compose pull && make restart`.

Breaking changes:
- Review release notes (Traefik major, Nextcloud major jumps)
- Backup volumes first (Section 11)
- Apply updates, verify health, roll back by `git reset --hard <prev>` + `make restart` if needed

## Adding a New Service
Checklist:
1. Define service in `compose.yaml` (pinned version, `restart: unless-stopped`, `mem_limit`)  
2. Expose internal port only (`expose:`) unless protocol requires host binding  
3. Add healthcheck (HTTP endpoint or simple CLI)  
4. Attach required networks; add `frontend` only if routed by Traefik  
5. Add Traefik labels (Host rule, `loadbalancer.server.port`)  
6. Persist data via a named volume (label it)  
7. Add any new env vars to `.env.dist` (with sane defaults)  
8. Validate with `docker compose -f compose.yaml config`  
9. Update README Service Section if user-facing  

## Troubleshooting
Common checks:
```bash
make status              # Systemd unit status
make logs                # Aggregate logs
docker compose ps        # Per-container state
docker compose logs <svc>
```
DNS resolution failing? Test Pi-hole:
```bash
dig @${PIHOLE_IP} nextcloud.${HOST_NAME}
```
Traefik routing issue? Inspect dashboard (`traefik.<HOST_NAME>`) or:
```bash
docker compose logs traefik | grep -i error
```
DDNS not updating records? Check updater logs:
```bash
docker compose logs ddns-updater
```
Tailscale/Headscale TLS error (`certificate signed by unknown authority` or SAN mismatch)?
- Ensure Traefik has issued a cert for `headscale.${HOST_NAME}` using Cloudflare DNS‑01 (Section 7.7.1).
- Confirm the certificate is no longer the Traefik default (`*.traefik.default`).
WireGuard peer not connecting:
```bash
docker exec -it pi-wireguard wg show
```
Netdata health:
```bash
curl -sf http://localhost:19999/api/v1/info
```
Portainer health:
```bash
docker exec pi-portainer wget -qO- http://localhost:9000/api/system/status
```

## FAQ
**Q: Can I expose a service directly without Traefik?**  
A: Prefer not. Route HTTP(S) through Traefik; non-HTTP protocols (WireGuard, DNS, Netdata) are the exceptions.

**Q: How do I add more WireGuard peers later?**  
A: Stop the stack, bump `WIREGUARD_PEERS` in `.env`, start again. Only new peers are generated.

**Q: Why Netdata instead of Prometheus+Grafana?**  
A: Lighter footprint, zero-config monitoring, and real-time dashboards out of the box—ideal for constrained Raspberry Pi hardware.

**Q: Can I change memory limits dynamically?**  
A: Edit `compose.yaml` and run `make restart`. Keep limits conservative to protect the host.

**Q: Is Watchtower safe in production?**  
A: It fetches and cleans images but does not restart automatically (policy here is manual validation before restart). Adjust if you accept auto restarts.

**Q: How do I connect Netdata to Netdata Cloud?**  
A: Set `NETDATA_CLAIM_TOKEN` and `NETDATA_CLAIM_ROOMS` in `.env`, then restart the stack.

## Contributing
See [AGENTS.md](AGENTS.md) for repository guidelines.
Workflow:
1. Fork
2. Feature branch
3. Minimal focused changes
4. Run validation (`docker compose config`, `yamllint`)  
5. Open PR with rationale (exposure, metrics, persistence)

## License & Acknowledgments
Licensed under MIT – see [LICENSE](LICENSE).

Acknowledgments:
- Netdata real-time monitoring
- Portainer container management
- Traefik reverse proxy
- n8n workflow automation
- WireGuard VPN
- Pi-hole DNS filtering

---
Happy self‑hosting! 🚀
