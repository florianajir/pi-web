# Installation Guide

## Hardware Requirements

### Minimum
- Raspberry Pi 5 with 8GB RAM
- MicroSD card (16GB+) or SSD storage

### Recommended
- Raspberry Pi 5 with 16GB RAM
- NVMe SSD HAT for storage (significantly improves performance and reliability)

## Prerequisites

Before installing pi-web, ensure you have:

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
git clone https://github.com/florianajir/pi-web.git
cd pi-web
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
| `USER` | LLDAP admin username | `admin` |
| `PASSWORD` | LLDAP admin & Authelia password | `strong-password-here` |
| `EMAIL` | Admin email & sender address | `admin@example.com` |
| `CLOUDFLARE_DNS_API_TOKEN` | Cloudflare API token | *(from Cloudflare dashboard)* |
| `CLOUDFLARE_ZONE_ID` | Your domain's zone ID | *(from Cloudflare dashboard)* |

**Network configuration** (usually auto-detected, adjust if needed):

| Variable | Default | Notes |
|----------|---------|-------|
| `HOST_LAN_IP` | Auto-detected | Your Pi's static LAN IP |
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
4. Assign groups (e.g., `users`, `admin`) for access control

### SSO Portal

1. Visit `https://auth.<HOST_NAME>`
2. Log in with credentials from LLDAP
3. Set up 2FA if required by policy (admin users need it)

### Service Access

Services are automatically configured with SSO. Just visit them and they'll redirect to the auth portal:

- **Nextcloud** — `https://nextcloud.<HOST_NAME>`
- **Immich** — `https://immich.<HOST_NAME>`
- **Portainer** — `https://portainer.<HOST_NAME>` (admin only, 2FA required)
- **Beszel** — `https://beszel.<HOST_NAME>`
- **n8n** — `https://n8n.<HOST_NAME>`
- And more (see [Architecture](ARCHITECTURE.md))

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

### Forgot password

Reset LLDAP admin:
1. Stop stack: `make stop`
2. Remove LLDAP volume: `docker volume rm pi-web_lldap_data`
3. Restart: `make start`
4. LLDAP admin reset to credentials in `.env`

## Next Steps

- Connect devices to your private VPN — see [Tailscale Setup](TAILSCALE.md)
- Configure backups — see [Configuration: Backrest](CONFIGURATION.md#backrest-restic-backup)
- Set up SMTP for notifications — see [Email & Notifications](EMAIL.md)
- Explore monitoring dashboards — see [Monitoring & Alerts](MONITORING.md)
- Review security architecture — see [Security & Authentication](SECURITY.md)
