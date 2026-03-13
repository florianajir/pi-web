# pi-web

[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://docker.com/)
[![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-Compatible-red.svg)](https://www.raspberrypi.org/)

`pi-web` is a compact self-hosting stack for Raspberry Pi, managed with a single Docker Compose setup.

It includes:
- Private cloud servers (`nextcloud`, `immich`, `n8n`)
- Push notifications (`ntfy`)
- Personal DNS filtering (`pihole`)
- VPN Connectivity (`tailscale`, `headscale`, `headplane`)
- Secured network access using reverse proxy + TLS (`traefik` with Cloudflare DNS challenge and DDNS updater)
- **Single Sign-On (SSO)** authentication via OIDC with `authelia` (backed by `lldap` user directory)
- Monitoring (`beszel`) and container management (`portainer`)
- Backup management (`backrest`)
- Internal data services (`postgres`, `redis`)
- Maintenance (`watchtower`)

---

## Requirements

### Hardware Requirements

**Minimum:**
- Raspberry Pi 5 with 8GB RAM
- MicroSD card (16GB+) or SSD storage

**Recommended:**
- Raspberry Pi 5 with 16GB RAM
- NVMe SSD HAT for storage (significantly improves performance and reliability)

### Prerequisites

Before installing pi-web, you'll need:

1. **Domain Name**: A registered domain name for accessing your services via HTTPS
2. **Cloudflare Account**: Free Cloudflare account for:
   - DNS management
   - Dynamic DNS (DDNS) updates
   - SSL/TLS certificate provisioning via DNS challenge
3. **Cloudflare API Token**: Generate an API token with DNS edit permissions for your zone
4. **Docker & Docker Compose**: Installed on your Raspberry Pi (checked during `make preflight`)

---


## Architecture

```mermaid
flowchart LR
  Internet((Internet))
  Cloudflare[Cloudflare DNS]
  LAN[Home LAN Clients]

  subgraph Pi["Raspberry Pi Host (Docker Compose)"]
    DDNS[ddns-updater]
    Traefik[traefik]
    Watchtower[watchtower]
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
  Watchtower -.automatic image updates.-> Nextcloud
  Watchtower -.automatic image updates.-> Immich
```

---

## DNS Architecture

This stack implements a privacy-first, three-tier recursive DNS pipeline. No third-party DNS provider (Google, Cloudflare, etc.) ever sees your queries.

### Components

| Tier | Container | Role |
|------|-----------|------|
| 1 | **Pi-hole** | Ad/tracker filtering, local hostname resolution |
| 2 | **Unbound** | Recursive resolver — walks the DNS delegation tree from root servers |
| 3 | **Root servers** | Authoritative source of truth |

### DNS Query Flow

```mermaid
sequenceDiagram
    participant C as Client (LAN / Tailscale)
    participant P as Pi-hole
    participant U as Unbound
    participant R as Root & TLD Servers

    C->>P: DNS query (e.g. cloudflare.com)
    alt Domain is blocked
        P-->>C: NXDOMAIN (ad/tracker blocked)
    else Domain is allowed
        P->>U: Forward query
        U->>R: Recursive resolution
        R-->>U: Authoritative answer
        U-->>P: Resolved IP
        P-->>C: DNS response
    end
```

### Tailscale DNS integration

Headscale is configured with [MagicDNS](https://tailscale.com/kb/1081/magicdns) and pushes Pi-hole as the global nameserver to all connected clients. Any device that joins the Tailscale network with `--accept-dns=true` automatically uses Pi-hole for DNS over the encrypted WireGuard tunnel — no manual client configuration required.

Headscale also sets up split DNS for the local domain (e.g. `pi.ajir.dev`) so that service hostnames like `nextcloud.pi.ajir.dev` resolve correctly inside the VPN.

### Network isolation

Pi-hole and Unbound communicate over a dedicated internal Docker bridge network that has no internet gateway — the two containers can reach each other, but nothing else can reach Unbound directly. Unbound is additionally attached to a separate egress network exclusively for outbound recursive queries to root servers.

```mermaid
flowchart LR
    subgraph VPN["Tailscale VPN"]
        TC[VPN Client]
    end
    subgraph LAN["Home LAN"]
        LC[LAN Client]
    end
    subgraph Pi["Raspberry Pi"]
        PH[Pi-hole]
        UB[Unbound]
    end
    Internet((Root Servers))

    TC -->|DNS| PH
    LC -->|DNS| PH
    PH -->|forward\ninternal network| UB
    UB -->|recursive resolve\negress network| Internet
```

---

## Security & Authentication

This stack implements a defense-in-depth authentication architecture with multiple layers: network-level IP filtering, a VPN mesh, a central SSO portal, and per-service OIDC integration — all backed by a lightweight LDAP directory.

### Components overview

| Component | Role |
|-----------|------|
| **Traefik** | Reverse proxy — terminates TLS, applies middleware chains (IP allowlist, forward-auth) |
| **Tailscale / Headscale** | WireGuard VPN mesh — only devices on the tailnet can reach services behind the `lan` middleware |
| **Authelia** | SSO portal & OIDC provider — handles login, session management, 2FA, and issues OIDC tokens |
| **LLDAP** | Lightweight LDAP directory — single source of truth for user identities and group memberships |
| **Redis** | Session store for Authelia (cookie-based sessions with inactivity/absolute timeouts) |
| **PostgreSQL** | Persistent storage for Authelia (user preferences, TOTP devices, WebAuthn credentials) |

### Authentication flow

```mermaid
sequenceDiagram
    participant B as Browser
    participant T as Traefik
    participant A as Authelia
    participant L as LLDAP
    participant S as Service

    B->>T: HTTPS request to service.example.com
    T->>T: lan middleware — check IP in allowlist

    alt IP not in ALLOW_IP_RANGES
        T-->>B: 403 Forbidden
    else IP allowed
        T->>A: Forward-auth check (session cookie)
        alt Valid session
            A-->>T: 200 + Remote-User / Remote-Groups headers
            T->>S: Proxy request with identity headers
            S-->>B: Response
        else No session or expired
            A-->>T: 302 Redirect to login
            T-->>B: Redirect to https://auth.example.com
            B->>A: User submits credentials
            A->>L: LDAP bind (verify password)
            L-->>A: Bind success + group memberships
            A->>A: Evaluate access policy (one_factor / two_factor)
            opt two_factor required
                B->>A: TOTP code or WebAuthn assertion
            end
            A-->>B: Set session cookie + redirect back
            B->>T: Original request (with cookie)
            T->>A: Forward-auth check (valid cookie)
            A-->>T: 200 + identity headers
            T->>S: Proxy request
            S-->>B: Response
        end
    end
```

### OIDC single sign-on

Services that support OpenID Connect bypass forward-auth and authenticate directly against Authelia as an OIDC provider. This gives each service its own token-based session while the user only logs in once.

```mermaid
sequenceDiagram
    participant B as Browser
    participant S as Service (e.g. Nextcloud)
    participant A as Authelia (OIDC Provider)
    participant L as LLDAP

    B->>S: Click "Login with SSO"
    S-->>B: 302 to Authelia /authorize (client_id, redirect_uri, scope)
    B->>A: Authorization request

    alt Already authenticated (session cookie)
        A->>A: Check consent & policy
    else Not authenticated
        A->>A: Show login form
        B->>A: Submit credentials
        A->>L: LDAP bind + group lookup
        L-->>A: Identity + groups
    end

    A-->>B: 302 back to Service with authorization code
    B->>S: Callback with code
    S->>A: Exchange code for tokens (server-to-server)
    A-->>S: ID token (JWT, RS256) + access token + refresh token
    S->>S: Verify JWT signature, provision/update user
    S-->>B: Authenticated session
```

**Registered OIDC clients:**

| Client | Scopes | Auth method | Consent | Policy | Notes |
|--------|--------|-------------|---------|--------|-------|
| Nextcloud | openid profile email groups offline_access | client_secret_post | implicit | one_factor | Group provisioning enabled |
| Immich | openid profile email | client_secret_post | implicit | one_factor | Mobile app callback supported |
| Beszel | openid profile email | client_secret_basic | implicit | one_factor | PKCE (S256) enabled |
| Portainer | openid profile email groups | client_secret_basic | implicit | one_factor | Auto-team provisioning |
| Headplane | openid profile email | client_secret_basic | implicit | **two_factor** | VPN admin — stricter policy |

### Traefik middleware layers

Every incoming request passes through Traefik, which applies a chain of middlewares before reaching the backend service.

```mermaid
flowchart LR
    R[Request] --> TLS["TLS termination"]
    TLS --> Compress["gzip compression"]
    Compress --> Headers["Security headers\n(HSTS, X-Frame-Options,\nX-Content-Type-Options)"]
    Headers --> LAN{"lan middleware\n(IP allowlist)"}
    LAN -->|Denied| Block[403]
    LAN -->|Allowed| Auth{"authelia middleware\n(forward-auth)"}
    Auth -->|No session| Login["Redirect to\nauth portal"]
    Auth -->|Valid session| Backend["Backend service"]
```

**Middleware assignment per service:**

| Service | `lan` (IP allowlist) | `authelia` (forward-auth) | Own OIDC | Notes |
|---------|:---:|:---:|:---:|-------|
| Authelia portal | — | — | — | Public entry point for login |
| Nextcloud | — | — | yes | LAN-only + OIDC |
| Immich | yes | — | yes | LAN-only + OIDC |
| Beszel | yes | — | yes | LAN-only + OIDC |
| n8n | yes | — | — | LAN-only + own auth |
| Ntfy | yes | — | — | LAN-only + own auth |
| Homepage | yes | yes | — | LAN-only + user |
| Uptime Kuma | yes | yes | — | LAN-only + user |
| Traefik dashboard | yes | yes | — | LAN-only + admin + two_factor |
| Pi-hole | yes | yes | — | LAN-only + admin + two_factor |
| Backrest | yes | yes | — | LAN-only + admin + two_factor |
| LLDAP | yes | yes | — | LAN-only + admin + two_factor + own auth |
| Headplane | yes | — | yes | LAN-only + OIDC + admin + two_factor |
| Portainer | yes | — | yes | LAN-only + OIDC + admin + two_factor |

### Access control policies

Authelia enforces group-based access rules defined per domain:

| Domain pattern | Required group | Policy | Description |
|----------------|---------------|--------|-------------|
| `auth.*` | — | bypass | Login portal itself |
| `homepage.*`, `uptime.*` | users | one_factor | General SSO-protected services |
| `backrest.*`, `pihole.*`, `traefik.*`, `lldap.*` | admin or lldap_admin | two_factor | Admin tools |
| `lldap.*` | users | two_factor | LDAP directory (also requires valid session) |
| `*.*` (catch-all) | users | deny | All other services |

### Network segmentation

Docker networks enforce east-west isolation between services:

```mermaid
flowchart TB
    subgraph frontend["frontend network (172.30.11.0/24)"]
        Traefik
        Authelia
        Services["Nextcloud, Immich, Portainer,\nBeszel, n8n, Ntfy, Backrest,\nHeadplane, Homepage, Uptime Kuma"]
    end

    subgraph auth["auth network (internal)"]
        AutheliaB[Authelia]
        LLDAP
        PG_Auth[(Postgres)]
        Redis_Auth[(Redis)]
    end

    subgraph nextcloud_net["nextcloud network (internal)"]
        NC[Nextcloud]
        PG_NC[(Postgres)]
        Redis_NC[(Redis)]
    end

    subgraph immich_net["immich network (internal)"]
        IM[Immich]
        PG_IM[(Postgres)]
        Redis_IM[(Redis)]
    end

    subgraph dns["dns_internal (172.30.53.0/24, no gateway)"]
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

### Secret management

All secrets are **auto-generated on first start** by `scripts/authelia-pre-start.sh` and stored under `${DATA_LOCATION}/authelia-config/secrets/` with `600` permissions:

| Secret | Purpose |
|--------|---------|
| `jwt_secret` | Authelia identity validation tokens |
| `session_secret` | Session cookie signing |
| `storage_encryption_key` | Database credential encryption |
| `oidc_hmac_secret` | OIDC token HMAC signing |
| `oidc_private_key.pem` | RSA-2048 key for JWT RS256 signatures |
| `oidc_<client>_secret.txt` | Per-client OIDC shared secrets |
| `ldap_password` | LDAP bind password (= `PASSWORD` from `.env`) |

OIDC client secrets are injected into services via Docker volume mounts (read-only). No secrets are baked into images or committed to the repository.

---

## Beszel Monitoring

Beszel provides lightweight server monitoring via a hub + agent architecture, built on PocketBase (embedded SQLite). The bootstrap script (`scripts/beszel-agent-bootstrap.sh`) fully auto-configures the hub on first start.

### Architecture

```mermaid
flowchart LR
    subgraph Pi["Raspberry Pi"]
        Agent["beszel-agent\n(host network)"]
        Hub["beszel hub\n(PocketBase)"]
        Traefik["traefik"]
    end

    subgraph External["External Services"]
        S3["S3 Storage\n(file storage + backups)"]
        SMTP["SMTP Server"]
        Ntfy["ntfy"]
    end

    Agent -->|metrics via\nUnix socket| Hub
    Traefik -->|"HTTPS reverse proxy\n(X-Forwarded-For)"| Hub
    Hub -->|"OIDC auth"| Authelia["authelia"]
    Hub -->|file storage &\nSQLite backups| S3
    Hub -->|alert emails| SMTP
    Hub -->|webhook alerts| Ntfy
```

### Auto-configured settings

The bootstrap script authenticates as PocketBase superuser and applies settings via `PATCH /api/settings`:

| Setting | Source | Description |
|---------|--------|-------------|
| **SMTP** | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `EMAIL` | Transactional emails (alerts, password resets) |
| **S3 file storage** | `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | PocketBase file uploads stored in S3 |
| **S3 backups** | Same S3 credentials + `BESZEL_BACKUP_CRON`, `BESZEL_BACKUP_MAX_KEEP` | Built-in PocketBase SQLite backup to S3 |
| **Trusted proxy** | Always set | `X-Forwarded-For` header trusted, `useLeftmostIP: true` — ensures real client IPs are logged |
| **OIDC** | Authelia client secret from `authelia-config/secrets/oidc_beszel_secret.txt` | SSO via Authelia |
| **Ntfy webhook** | `config/ntfy/ntfy.env` | Push notifications for monitoring alerts |
| **Temperature alerts** | `BESZEL_TEMP_ALERT_VALUE` (default: 70°C), `BESZEL_TEMP_ALERT_MIN` (default: 5 min) | Auto-created for all monitored systems |

### Backup strategy

Beszel data is protected by two independent backup layers:

1. **PocketBase built-in backup** — SQLite snapshots on `BESZEL_BACKUP_CRON` schedule, stored to S3 when configured (or local otherwise), with `BESZEL_BACKUP_MAX_KEEP` retention.
2. **Backrest (restic)** — The `beszel_data` Docker volume is mounted read-only into the Backrest container and included in the nightly S3 restic backup alongside Nextcloud, Immich, and other service data.

---

## Email & SMTP Configuration

The stack supports outbound email for notifications, password resets, and workflow automation. All services share a single set of SMTP credentials defined in `.env`.

### Environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `SMTP_HOST` | SMTP server hostname | `localhost` |
| `SMTP_PORT` | SMTP server port | `587` |
| `SMTP_USERNAME` | SMTP authentication username | *(empty)* |
| `SMTP_PASSWORD` | SMTP authentication password | *(empty)* |
| `EMAIL` | Sender address (also used as admin email across services) | `noreply@localhost` |

Optional per-service overrides (rarely needed):

| Variable | Used by | Description | Default |
|----------|---------|-------------|---------|
| `SMTP_SECURE` | Nextcloud | Connection security (`tls`, `ssl`, or empty) | `tls` |
| `SMTP_AUTHTYPE` | Nextcloud | Authentication method | `LOGIN` |
| `SMTP_ENCRYPTION` | LLDAP, Authelia | Encryption mode | `STARTTLS` |
| `SMTP_SSL` | n8n | Enable SSL | `false` |
| `SMTP_ENABLED` | LLDAP | Enable password-reset emails | `false` |
| `MAIL_FROM_ADDRESS` | Nextcloud | Local part of sender address | `nextcloud` |
| `MAIL_DOMAIN` | Nextcloud | Domain part of sender address | `${HOST_NAME}` |

### Services using SMTP

#### Auto-configured from `.env`

These services read SMTP settings directly from environment variables at startup — no manual configuration needed:

| Service | Purpose | Notes |
|---------|---------|-------|
| **Authelia** | 2FA enrollment emails, password reset, identity verification | Uses `submission://` URI scheme; `disable_startup_check` is enabled so the stack starts even without valid SMTP |
| **Nextcloud** | Sharing notifications, activity digests, password resets | Sender is `${MAIL_FROM_ADDRESS}@${MAIL_DOMAIN}` (e.g. `nextcloud@pi.example.com`) |
| **LLDAP** | Self-service password reset emails | Disabled by default (`SMTP_ENABLED=false`); set to `true` in `.env` to enable |
| **n8n** | Workflow email nodes (Send Email action), error notifications | Standard SMTP envelope; uses `N8N_SMTP_*` env vars mapped from the shared variables |
| **Ntfy** | Outbound email notifications for push topics | Sends via `${SMTP_HOST}:${SMTP_PORT}` as the sender relay |
| **Beszel** | Host monitoring alerts and notifications | Auto-configured via PocketBase settings API by `scripts/beszel-agent-bootstrap.sh` |

#### Manual setup via UI

These services support email notifications but must be configured through their web interface:

| Service | Where to configure | Notes |
|---------|-------------------|-------|
| **Uptime Kuma** | *Settings → Notifications → Add* | Add an SMTP notification type with your server details |
| **Immich** | Not currently supported | Immich does not have built-in email notifications |
| **Portainer** | Not currently supported | Portainer does not expose SMTP settings for notifications |

### Quick setup example

To enable email across all services, add your SMTP provider credentials to `.env`:

```env
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=you@example.com
SMTP_PASSWORD=app-password-here
EMAIL=noreply@example.com
```

> **Note:** If `SMTP_HOST` is left unset or set to `localhost`, services will start normally but email delivery will silently fail. Authelia disables its SMTP startup check to keep the stack resilient in this case.

---

## Install guide

1. Clone the repository.
2. Copy `.env.dist` to `.env` and fill required values.
3. Run preflight checks using `make preflight`.
4. Install/start the stack using `make install`.

```bash
git clone https://github.com/florianajir/pi-web.git
cd pi-web
cp .env.dist .env # Edit .env with your values
make preflight
make install
make status
make logs
```

> **Note:** On first start, all authentication secrets and OIDC configuration are auto-generated
> (see [Security & Authentication](#security--authentication) for details). The LLDAP admin
> username is `admin` with the `PASSWORD` from `.env`. The SSO portal is at `https://auth.<HOST_NAME>`.

---


## Connecting Devices with Tailscale

This stack includes Headscale for managing your private Tailscale network. To connect new devices:

### Quick Command

```bash
make headscale-register <key>
```

### Detailed Steps

1. On the client device, install Tailscale and run the join command. It will output a registration key and prompt for approval.
2. Copy the key provided by the client.
3. On your Pi-Web host, run:

   ```bash
   make headscale-register <key>
   ```

   Replace `<key>` with the actual key from the client.

Your device will now be connected to your private VPN network managed by Headscale.


---

## Make commands

| Command | Description |
| --- | --- |
| `make preflight` | Verify Docker/cgroup readiness |
| `make install` | Install systemd units and start stack |
| `make uninstall` | Remove stack, volumes, and units (destructive) |
| `make start` | Start stack |
| `make stop` | Stop stack |
| `make restart` | Restart stack |
| `make status` | Show stack status |
| `make logs` | Follow stack logs |
| `make headscale-register <key>` | Register a Headscale node |
| `make headscale-reset` | Reset all Headscale registrations (destructive) |

---

## Variables listing (`.env`)

### Personal
- `HOST_NAME`
- `TIMEZONE`
- `EMAIL`
- `USER`
- `PASSWORD`
- `DATA_LOCATION` (default: `./data`)

### Network
- `HOST_LAN_IP`
- `HOST_LAN_PARENT` (default: `eth0`)
- `HOST_LAN_SUBNET` (default: `192.168.1.0/24`)
- `HOST_LAN_GATEWAY` (default: `192.168.1.1`)
- `PIHOLE_IP` (default: `192.168.1.250`)
- `ALLOW_IP_RANGES` (default: `127.0.0.1/32,192.168.1.0/24,100.64.0.0/10,172.30.0.0/16`)

### Traefik / Cloudflare
- `CLOUDFLARE_DNS_API_TOKEN`
- `CLOUDFLARE_ZONE_ID`

### S3 Storage (shared credentials)
- `S3_ENDPOINT` — S3-compatible endpoint URL (e.g. `https://s3.fr-par.scw.cloud`)
- `S3_BUCKET` — S3 bucket name
- `S3_REGION` — S3 region (e.g. `fr-par`)
- `S3_ACCESS_KEY_ID` — S3 access key
- `S3_SECRET_ACCESS_KEY` — S3 secret key

### Backrest (restic backup)
- `BACKREST_S3_URI` *(optional)* — Restic repository URI; auto-derived as `s3:${S3_ENDPOINT}/${S3_BUCKET}/restic` if not set
- `BACKREST_S3_REPO_PASSWORD` — Restic repository encryption password
- `NEXTCLOUD_SQL_BACKUP_KEEP` (default: `7`)

### Beszel (PocketBase)
- `BESZEL_S3_FORCE_PATH_STYLE` (default: `true`) — Force path-style S3 addressing for PocketBase
- `BESZEL_BACKUP_CRON` (default: `0 3 * * *`) — PocketBase built-in backup schedule
- `BESZEL_BACKUP_MAX_KEEP` (default: `7`) — Max PocketBase backup snapshots to retain

### Authentication (auto-configured)
- `USER` and `PASSWORD` from the personal section are used for lldap admin and Authelia LDAP bind.
  All Authelia secrets (JWT, session, storage encryption key, OIDC HMAC, RSA key, lldap JWT) are
  auto-generated on first start by `scripts/authelia-pre-start.sh` and stored in
  `${DATA_LOCATION}/authelia-config/secrets/`.
- Headplane OIDC SSO uses Authelia as issuer and loads:
  - client secret from `${DATA_LOCATION}/authelia-config/secrets/oidc_headplane_secret.txt`
  - Headscale API key from `config/headplane/headscale_api_key` (auto-generated by `scripts/headscale-init.sh`)
- Portainer OIDC bootstrap is enabled by default and uses `EMAIL` / `PASSWORD` from `.env`
  (`USER` then `admin` are used as fallback usernames).
- Portainer OAuth auto-provisioning also ensures a default `oidc-users` team exists when needed,
  uses it as the default team for newly created OAuth users, backfills existing teamless standard
  users, and only grants that team endpoint access when no explicit endpoint/group access policies
  are already present.
- SMTP configuration is shared across services — see [Email & SMTP Configuration](#email--smtp-configuration) for details.
- Administration web UIs (`traefik`, `portainer`, `backrest`, `pihole`, `beszel`,
  `uptime`, and `headscale/admin` via `headplane`) are protected by Authelia and require an admin
  account with 2FA.
- `lldap` keeps its own native login flow and is restricted to allowed network ranges via Traefik `lan`
  middleware (to avoid double authentication prompts).

---

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
