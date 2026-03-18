# pi-web

[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://docker.com/)
[![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-Compatible-red.svg)](https://www.raspberrypi.org/)

A production-ready, privacy-focused web stack for Raspberry Pi—from DNS filtering to personal cloud—deployed in minutes.

pi-web bundles the hard parts (HTTPS, SSO, private DNS, VPN, backups, and monitoring) into a clean Docker Compose setup you can audit, customize, and run on standard Linux.

## Why pi-web?

If you're deciding between approaches, here's the short version:

- **Vs installing apps manually:** pi-web saves days of integration work by shipping a pre-wired stack (Traefik, Authelia, LLDAP, Postgres, Redis, backups, and monitoring) that works together out of the box.
- **Vs Umbrel or CasaOS:** pi-web is **lightweight and transparent**—no proprietary host OS, no app-store lock-in, just pure Docker Compose and readable config files.
- **For long-term ownership:** everything is Git-friendly and scriptable, so installs, updates, and recovery stay repeatable.

## Stack Overview

| Category | Services |
|----------|----------|
| **Cloud & Storage** | Nextcloud, Immich, n8n, Ntfy |
| **Network & Security** | Traefik (reverse proxy), Tailscale/Headscale (VPN), Authelia (SSO), LLDAP (user directory) |
| **DNS & Filtering** | Pi-hole (ad-blocking), Unbound (recursive DNS) |
| **Monitoring & Backup** | Beszel (monitoring), Backrest (restic backups), Portainer (container management) |
| **Infrastructure** | PostgreSQL, Redis, ddns-updater |

## Requirements

**Hardware:**
- Raspberry Pi 5 (8GB minimum, 16GB recommended)
- Storage: MicroSD card (16GB+) or NVMe SSD HAT

**Prerequisites:**
- Domain name + Cloudflare account (free tier OK)
- Cloudflare API token with DNS edit permissions
- Docker & Docker Compose installed

## Quick Start

Fast lane for the curious:

```bash
curl -sSL https://raw.githubusercontent.com/florianajir/pi-web/main/install.sh | bash
```

The installer clones pi-web (default: `~/pi-web`), creates `.env` from `.env.dist`, prompts for the missing required values, then runs `make preflight` and `make install`.

Want a custom path? Use:

```bash
curl -sSL https://raw.githubusercontent.com/florianajir/pi-web/main/install.sh | bash -s -- --dir /opt/pi-web
```

Prefer the manual route? Same destination, slightly more typing:

```bash
git clone https://github.com/florianajir/pi-web.git
cd pi-web
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
