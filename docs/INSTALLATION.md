# Installation Guide

## Hardware Requirements

### Minimum
- Raspberry Pi 5 with 8GB RAM
- MicroSD card (16GB+) or SSD storage

### Recommended
- Raspberry Pi 5 with 16GB RAM
- NVMe SSD HAT for storage (significantly improves performance and reliability)

## Prerequisites

Before installing pi-pcloud, ensure you have:

1. **Domain Name** — A registered domain for accessing services via HTTPS
2. **Cloudflare Account** — Free tier OK. You'll need:
   - DNS management
   - Dynamic DNS (DDNS) updates via API
   - SSL/TLS certificate provisioning
3. **Cloudflare API Token** — Generate one with:
   - Zone: DNS edit permissions on your domain
4. **Docker & Docker Compose** — Pre-installed on Pi OS (verified during `make preflight`)

## Installation Steps

### 1. Clone Repository

```bash
git clone https://github.com/florianajir/pi-pcloud.git
cd pi-pcloud
```

### 2. Configure Environment

Copy the template and edit with your values:

```bash
cp .env.dist .env
```

**Essential variables to set:**

| Variable | Description | Example |
|----------|-------------|---------|
| `HOST_NAME` | Your domain | `pi.example.com` |
| `TIMEZONE` | Server timezone | `Europe/Paris` |
| `ADMIN_USER` | Stack-wide admin username | `admin` |
| `PASSWORD` | LLDAP admin & Authelia password | `strong-password-here` |
| `EMAIL` | Admin email & sender address | `admin@example.com` |
| `HOST_LAN_IP` | Your Pi's static LAN IP | `192.168.1.30` |
| `CLOUDFLARE_DNS_API_TOKEN` | Cloudflare API token | *(from Cloudflare dashboard)* |
| `CLOUDFLARE_ZONE_ID` | Your domain's zone ID | *(from Cloudflare dashboard)* |

**Network configuration** (defaults suit a `192.168.1.0/24` LAN, adjust if needed):

| Variable | Default | Notes |
|----------|---------|-------|
| `HOST_LAN_PARENT` | `eth0` | Network interface name |
| `HOST_LAN_SUBNET` | `192.168.1.0/24` | Your home network CIDR |
| `HOST_LAN_GATEWAY` | `192.168.1.1` | Your router's IP |
| `PIHOLE_IP` | `192.168.1.250` | Static IP for Pi-hole (must be in subnet, outside DHCP range) |

See [Configuration](CONFIGURATION.md) for all available options.

### 3. Run Preflight Checks

Verify your Pi is ready:

```bash
make preflight
```

This checks:
- Docker & Docker Compose availability
- cgroup v2 support
- Required commands (git, curl, etc.)

### 4. Deploy Stack

```bash
make install
```

This:
- Creates systemd service units
- Generates authentication secrets
- Starts all containers
- Initializes databases

### 5. Monitor Startup

```bash
make logs
```

Watch for any errors. Initial startup takes 2-5 minutes.

## First Login

### LLDAP Setup

1. Visit `https://lldap.<HOST_NAME>`
2. Login as `admin` with your `PASSWORD`
3. Create users in **Admin** → **Users**
4. Create an `admin` group and add your admin accounts to it — it gates the admin tools (Traefik, Pi-hole, Backrest, LLDAP, Dockhand, Headplane) with 2FA. Regular users need no group.

### SSO Portal

1. Visit `https://auth.<HOST_NAME>`
2. Log in with credentials from LLDAP
3. Set up 2FA if required by policy (admin users need it)

### Service Access

Services are automatically configured with SSO. Just visit them and they'll redirect to the auth portal:

- **Nextcloud** — `https://nextcloud.<HOST_NAME>`
- **Immich** — `https://immich.<HOST_NAME>`
- **Dockhand** — `https://dockhand.<HOST_NAME>` (admin only, 2FA required)
- **Beszel** — `https://beszel.<HOST_NAME>`
- **n8n** — `https://n8n.<HOST_NAME>`
- **Kavita** — `https://kavita.<HOST_NAME>` (see one-time setup below)
- And more (see [Architecture](ARCHITECTURE.md))

### Kavita (one-time OIDC finalization)

Kavita's OIDC connection to Authelia is wired automatically at boot (client, secret, and
`appsettings.json` are provisioned by `scripts/kavita-oidc-bootstrap.sh`). However, Kavita stores
its **role mapping and account auto-provisioning in its own database** (only editable via the UI),
so on a fresh install complete these steps once — they persist in the `kavita_config` volume:

1. Visit `https://kavita.<HOST_NAME>` and create the **admin account** (standard registration).
2. Go to **Settings → OpenID Connect**. The connection fields (Authority, Client ID, Secret) are
   already filled in.
3. Enable **Auto-Provision** so Authelia users get a Kavita account on first login.
4. Under **Advanced settings**, set **Roles claim** to `groups` (the default `.../claims/role` is
   not emitted by Authelia). Leave **Custom scopes** as `groups`.
5. To grant admin via SSO, put the user in an LLDAP group whose name matches a Kavita role
   (e.g. `Admin`), or set a **Roles prefix** (e.g. `kavita-`) and use groups like `kavita-admin`.

> These role/provisioning settings live only in Kavita's internal DB (no stable config-file
> surface), so they are intentionally **not** automated — do not edit `kavita.db` directly, as its
> schema is not stable across Kavita updates.

#### Email (optional)

With OIDC + Auto-Provision, accounts are created through Authelia at login, so Kavita's own email
server is usually **not needed** — it only powers local-account flows (invites, setup links,
password resets), which SSO bypasses. Leave it unconfigured unless you specifically want those.

Like the role settings, Kavita's SMTP config has **no env/config-file surface** (unlike the other
stack services): it lives only in the DB and is set via the admin UI. If you do want it, configure
it once under **Settings → Email**, reusing the `SMTP_*` values from your `.env`:

| Kavita field | `.env` variable |
|---|---|
| Host | `SMTP_HOST` |
| Port | `SMTP_PORT` |
| Username | `SMTP_USERNAME` |
| Password | `SMTP_PASSWORD` |
| Sender address | `EMAIL` |

## Troubleshooting

### Stack won't start

Check logs:
```bash
make logs
```

Common issues:
- **Port conflicts** — Ensure ports 80, 443, 53 are available
- **Storage permissions** — `data/` directory needs write access
- **Cloudflare token invalid** — Verify token has DNS edit permissions

### Services not accessible

1. Verify DNS resolves to your Pi:
   ```bash
   nslookup auth.<HOST_NAME>
   ```
   Should return your Raspberry Pi's public IP (via Cloudflare).

2. Check firewall allows 443 inbound
3. Verify Traefik logs for routing errors:
   ```bash
   docker compose logs traefik | tail -50
   ```

### Forgot / leaked admin password

Set a new `PASSWORD` in `.env` and run `make rotate-password`. Editing `.env` alone does **not** reset the LLDAP admin account — the rotate script performs the actual LDAP password change and updates Authelia's bind secret. See [Configuration: Changing Passwords](CONFIGURATION.md#changing-passwords).

Regular users reset their own password via the Authelia portal or the LLDAP admin UI.

## Next Steps

- Connect devices to your private VPN — see [Tailscale Setup](TAILSCALE.md)
- Configure backups — see [Configuration: Backrest](CONFIGURATION.md#backrest-restic-backup)
- Set up SMTP for notifications — see [Email & Notifications](EMAIL.md)
- Explore monitoring dashboards — see [Monitoring & Alerts](MONITORING.md)
- Review security architecture — see [Security & Authentication](SECURITY.md)
