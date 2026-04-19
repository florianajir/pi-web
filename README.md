# pi-pcloud

[![CI](https://github.com/florianajir/pi-pcloud/actions/workflows/ci.yml/badge.svg)](https://github.com/florianajir/pi-pcloud/actions/workflows/ci.yml)
[![CodeQL](https://github.com/florianajir/pi-pcloud/actions/workflows/codeql.yml/badge.svg)](https://github.com/florianajir/pi-pcloud/actions/workflows/codeql.yml)
[![Dependabot](https://badgen.net/badge/icon/dependabot?icon=dependabot&label)](https://github.com/florianajir/pi-pcloud/actions/workflows/dependabot/dependabot-updates)

A production-ready, privacy-focused web stack for Raspberry Pi—from DNS filtering to personal cloud—deployed in minutes.

pi-pcloud bundles the hard parts (HTTPS, SSO, private DNS, VPN, backups, and monitoring) into a clean Docker Compose setup you can audit, customize, and run on standard Linux.

## Why pi-pcloud?

If you're deciding between approaches, here's the short version:

- **Vs installing apps manually:** pi-pcloud saves days of integration work by shipping a pre-wired stack (Traefik, Authelia, LLDAP, Postgres, Redis, backups, and monitoring) that works together out of the box.
- **Vs Umbrel or CasaOS:** pi-pcloud is **lightweight and transparent**—no proprietary host OS, no app-store lock-in, just pure Docker Compose and readable config files.
- **For long-term ownership:** everything is Git-friendly and scriptable, so installs, updates, and recovery stay repeatable.

## Stack Overview

| Category | Services |
|----------|----------|
| **Cloud & Storage** | Nextcloud, Immich, n8n, Ntfy |
| **Network & Security** | Traefik (reverse proxy), Tailscale/Headscale (VPN), Authelia (SSO), LLDAP (user directory) |
| **DNS & Filtering** | Pi-hole (ad-blocking), Unbound (recursive DNS) |
| **Download** | qBittorrent (torrent client), Gluetun (VPN kill-switch gateway) |
| **Monitoring & Backup** | Beszel (monitoring), Backrest (restic backups), Dockhand (container management) |
| **Infrastructure** | PostgreSQL, Redis, ddns-updater |

## Requirements

**Hardware:**
- Raspberry Pi 5 (8GB RAM minimum, **16GB RAM recommended** for the full stack)
- Storage: NVMe SSD HAT recommended (MicroSD cards degrade quickly under continuous I/O)
- S3-compatible bucket (or equivalent) recommended for off-site Backrest backups

**Prerequisites:**
- Domain name + Cloudflare account (free tier OK)
- Cloudflare API token with DNS edit permissions
- Docker & Docker Compose installed

**Router port forwarding:**

| Port | Protocol | Service | Purpose |
|------|----------|---------|---------|
| `443` | TCP | Traefik | HTTPS access to web services |
| `41641` | UDP | Tailscale/Headscale | WireGuard VPN tunnel |
| `3478` | UDP | Tailscale/Headscale | STUN — peer-to-peer traversal |

> Only `443` is required for basic HTTPS access. `41641` and `3478` are needed for direct VPN connections via Headscale.

## Quick Start

```bash
git clone https://github.com/florianajir/pi-pcloud.git
cd pi-pcloud
cp .env.dist .env                   # Edit with your values
make preflight                      # Verify prerequisites
make install                        # Deploy stack
make logs                           # Follow startup logs
```

After first start, visit `https://auth.<YOUR_DOMAIN>` to create your first user in LLDAP, then log in to services with SSO.

## Usage

| Task | Command |
|------|---------|
| Start/stop stack | `make start` / `make stop` |
| View logs | `make logs` |
| Stack status | `make status` |
| Register Tailscale device | `make headscale-register <key>` |
| Full command reference | See [docs/COMMANDS.md](docs/COMMANDS.md) |

## Documentation

- **[Installation Guide](docs/INSTALLATION.md)** — Detailed setup, hardware requirements, and prerequisites
- **[Architecture](docs/ARCHITECTURE.md)** — System design, service interactions, networking diagrams
- **[Security & Authentication](docs/SECURITY.md)** — Authentication flows, OIDC, access control, encryption
- **[Configuration](docs/CONFIGURATION.md)** — All environment variables, secrets, and customization options
- **[Monitoring & Alerts](docs/MONITORING.md)** — Beszel setup, alerts, and backup strategy
- **[Email & Notifications](docs/EMAIL.md)** — SMTP configuration, Ntfy push notifications
- **[Networking](docs/NETWORKING.md)** — DNS architecture, Tailscale/Headscale, network segmentation
- **[Tailscale Setup](docs/TAILSCALE.md)** — Connecting devices, MagicDNS, split DNS configuration
- **[Development](AGENTS.md)** — Guidelines for contributing

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
