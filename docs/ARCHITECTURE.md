# Architecture

## System Overview

```mermaid
flowchart LR
  Internet((Internet))
  Cloudflare[Cloudflare DNS]
  LAN[Home LAN Clients]

  subgraph Pi["Raspberry Pi Host (Docker Compose)"]
    DDNS[ddns-updater]
    Traefik[traefik]
    Tailscale[tailscale]

    subgraph Apps["User-facing services (routed by Traefik)"]
      Nextcloud[nextcloud]
      Immich[immich-server]
      N8N[n8n]
      Portainer[portainer]
      Beszel[beszel]
      Headscale[headscale]
      Headplane[headplane]
      Backrest[backrest]
      Ntfy[ntfy]
      PiholeWeb[pihole web]
      Authelia[authelia]
      Lldap[lldap]
    end

    subgraph Internal["Internal app services"]
      Postgres[(postgres)]
      Redis[(redis)]
      PiholeDNS[(pihole dns)]
    end
  end

  Internet -->|HTTPS 443| Traefik
  Cloudflare <-->|DNS records update| DDNS
  Traefik --> Nextcloud
  Traefik --> Immich
  Traefik --> N8N
  Traefik --> Portainer
  Traefik --> Beszel
  Traefik --> Headscale
  Traefik --> Headplane
  Traefik --> Backrest
  Traefik --> Ntfy
  Traefik --> PiholeWeb
  Traefik --> Authelia
  Traefik --> Lldap

  Nextcloud --> Postgres
  Nextcloud --> Redis
  Immich --> Postgres
  Immich --> Redis
  Authelia --> Postgres
  Authelia --> Redis
  Authelia --> Lldap
  Backrest --> Nextcloud
  Backrest --> Immich
  Backrest --> Beszel
  Backrest --> Postgres

  LAN -->|DNS 53/tcp+udp| PiholeDNS
  PiholeWeb -.admin UI.-> Traefik

  Tailscale <-->|VPN coordination| Headscale
  Headplane -->|admin API/UI| Headscale
```

## Service Roles

| Service | Purpose | Clients |
|---------|---------|---------|
| **Traefik** | Reverse proxy, TLS termination, request routing | Internet |
| **ddns-updater** | Keeps Cloudflare DNS pointing to your Pi's public IP | Cloudflare API |
| **Authelia** | SSO portal, OIDC provider, forward-auth middleware | All users |
| **LLDAP** | Lightweight LDAP directory for user management | Authelia, Nextcloud, Portainer, etc. |
| **Nextcloud** | File storage, collaboration | Users via Traefik + SSO |
| **Immich** | Photo/video library with ML tagging | Users via Traefik + SSO |
| **n8n** | Workflow automation | Users via Traefik |
| **Portainer** | Container & stack management UI | Admins via Traefik + SSO + 2FA |
| **Beszel** | Server monitoring, alerts, webhooks | Admins via Traefik + SSO |
| **Headscale** | Self-hosted Tailscale control plane | VPN clients |
| **Headplane** | Web UI for Headscale admin | Admins via Traefik + SSO + 2FA |
| **Ntfy** | Push notifications | Other services, webhooks |
| **Pi-hole** | Ad blocking, local DNS resolution | LAN & VPN clients |
| **Unbound** | Recursive DNS resolver | Pi-hole |
| **Backrest** | Automated backups (restic) | S3 storage, scheduled jobs |
| **PostgreSQL** | Database for Nextcloud, Immich, Authelia | App containers |
| **Redis** | Session store, caching | App containers |
| **Tailscale** | WireGuard VPN mesh agent | Your VPN devices |

## Docker Networks

Containers are isolated by network for security:

```mermaid
flowchart TB
    subgraph frontend["frontend (172.30.11.0/24)"]
        Traefik
        Authelia
        Services["Nextcloud, Immich, Portainer,\nBeszel, n8n, Ntfy, Backrest,\nHeadplane, Homepage, Uptime Kuma"]
    end

    subgraph auth["auth (internal)"]
        AutheliaB[Authelia]
        LLDAP
        PG_Auth[(Postgres)]
        Redis_Auth[(Redis)]
    end

    subgraph nextcloud_net["nextcloud (internal)"]
        NC[Nextcloud]
        PG_NC[(Postgres)]
        Redis_NC[(Redis)]
    end

    subgraph immich_net["immich (internal)"]
        IM[Immich]
        PG_IM[(Postgres)]
        Redis_IM[(Redis)]
    end

    subgraph dns["dns_internal (172.30.53.0/24, no internet)"]
        PH[Pi-hole]
        UB[Unbound]
    end

    subgraph lan_net["macvlan (physical LAN)"]
        PH_LAN[Pi-hole LAN interface]
    end

    Traefik -->|"reverse proxy"| Services
    Traefik -->|"forward-auth"| Authelia
    AutheliaB -->|"LDAP bind"| LLDAP
    AutheliaB --> PG_Auth
    AutheliaB --> Redis_Auth
```

**Network isolation strategy:**

- **frontend** — Only this network is exposed to Traefik; handles all external traffic
- **auth** — Internal network; LDAP & auth secrets never exposed to services
- **service networks** — Separate isolated networks for Nextcloud, Immich with their own databases
- **dns_internal** — Pi-hole & Unbound on isolated network with no internet gateway; only DNS traffic
- **macvlan** — Pi-hole binds physical LAN interface for DHCP/DNS from home network

## Data Flow

### HTTPS Request → Service

```
Client (Internet/LAN/VPN)
  ↓
Traefik (TLS termination)
  ↓
Security Headers Middleware
  ↓
IP Allowlist (lan middleware)
  ↓
Forward-auth to Authelia (check session)
  ↓
Route to Backend Service
  ↓
Service handles request
```

### Service → Database

- **Nextcloud** → PostgreSQL + Redis (isolated network)
- **Immich** → PostgreSQL + Redis (isolated network)
- **Authelia** → PostgreSQL + Redis (auth network)
- **Beszel** → PocketBase SQLite (embedded)

### Service → External APIs

- **Traefik** → Cloudflare DNS API (for SSL cert provisioning)
- **ddns-updater** → Cloudflare DNS API (IP updates)
- **Backrest** → S3-compatible storage (backups)
- **Beszel** → S3, SMTP (backups, alerts)
- **Ntfy** → SMTP (email notifications)

## Backup Strategy

```mermaid
flowchart LR
    Services["Nextcloud\nImmich\nBeszel"]
    Restic["Backrest\n(restic)"]
    S3["S3 Storage"]
    LocalBackup["Local ./data backup\n(for restore reference)"]

    Services -->|"nightly"| Restic
    Restic -->|"encrypted"| S3
    Restic -->|"local copy"| LocalBackup
```

Two layers of protection:

1. **PocketBase built-in** (Beszel only) — SQLite snapshots per `BESZEL_BACKUP_CRON`
2. **Backrest (restic)** — Full application data + databases, with deduplication and encryption

See [Monitoring & Alerts](MONITORING.md#backup-strategy) for configuration details.

## Scaling & Failover

**Single-instance design:**
- Pi-web runs on one Raspberry Pi
- All data in `./data` directory (mount on external SSD for reliability)
- Backups to S3 for disaster recovery
- No clustering or replication built-in

**Backup & restore:**
- All data + config is backup-enabled
- Can restore to new Pi from S3 backups
- See [Monitoring & Alerts](MONITORING.md) for backup verification

## Storage Layout

```
pi-web/
├── .env                          # Configuration (secrets)
├── compose.yaml                  # Docker services definition
├── Makefile                      # Convenient commands
├── scripts/                      # Initialization & bootstrap scripts
├── config/                       # Service config files
│   ├── traefik/                  # Reverse proxy routes
│   ├── authelia/                 # SSO & OIDC config (regenerated)
│   ├── nextcloud/                # Nextcloud app config
│   ├── immich/                   # Immich config
│   └── ...
├── data/                         # ⚠️ Persistent data (mount on SSD!)
│   ├── nextcloud/                # Nextcloud files
│   ├── immich/                   # Immich library
│   ├── authelia-config/          # Auth secrets & config
│   ├── postgres/                 # Database files
│   ├── redis/                    # Cache/session data
│   ├── pihole/                   # Pi-hole config & blocklists
│   └── ...
└── docs/                         # Documentation
```

**Recommended setup:**
- Clone on SSD: `git clone ... /mnt/ssd/pi-web`
- Symlink from `/opt`: `ln -s /mnt/ssd/pi-web /opt/pi-web`
- Run systemd service from `/opt/pi-web`
