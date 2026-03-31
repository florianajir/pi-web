# Configuration

All configuration is managed through the `.env` file. Copy `.env.dist` and edit with your values.

## Environment Variables

### Personal Settings

| Variable | Description | Required | Default | Example |
|----------|-------------|----------|---------|---------|
| `HOST_NAME` | Your domain name | ✓ | — | `pi.example.com` |
| `TIMEZONE` | Server timezone | ✓ | — | `Europe/Paris` |
| `USER` | LLDAP admin username | ✓ | — | `admin` |
| `PASSWORD` | LLDAP admin & Authelia password | ✓ | — | `MySecurePassword123!` |
| `EMAIL` | Admin email & sender address | ✓ | — | `admin@example.com` |
| `DATA_LOCATION` | Path for persistent data | — | `./data` | `/mnt/ssd/pi-web-data` |

### Network Configuration

| Variable | Description | Default | Notes |
|----------|-------------|---------|-------|
| `HOST_LAN_IP` | Pi's static IP on home LAN | Auto-detected | Set if auto-detect fails |
| `HOST_LAN_PARENT` | Network interface name | `eth0` | Use `ip link` to find |
| `HOST_LAN_SUBNET` | Home network CIDR | `192.168.1.0/24` | Match your router's subnet |
| `HOST_LAN_GATEWAY` | Router IP | `192.168.1.1` | Usually `.1` in your subnet |
| `PIHOLE_IP` | Static IP for Pi-hole | `192.168.1.250` | Must be in subnet, outside DHCP range |
| `ALLOW_IP_RANGES` | IP ranges allowed to access services | `127.0.0.1/32,192.168.1.0/24,100.64.0.0/10,172.30.0.0/16` | Comma-separated CIDR blocks |

**IP Ranges Explained:**
- `127.0.0.1/32` — Localhost (internal access)
- `192.168.1.0/24` — Home LAN (adjust to match your network)
- `100.64.0.0/10` — Tailscale VPN (standard allocation)
- `172.30.0.0/16` — Docker internal networks

### Traefik & Cloudflare

| Variable | Description | Required | Notes |
|----------|-------------|----------|-------|
| `CLOUDFLARE_DNS_API_TOKEN` | Cloudflare API token | ✓ | Zone: DNS edit permissions only |
| `CLOUDFLARE_ZONE_ID` | Your domain's zone ID | ✓ | Find in Cloudflare dashboard |

**To generate token:**
1. Log in to Cloudflare dashboard
2. Go to **API Tokens**
3. Create token with:
   - Permissions: Zone → DNS → Edit
   - Zone resources: Include → Your domain
4. Copy and paste into `.env`

### S3 Storage (Optional)

For backups and file storage. Compatible with AWS S3, Scaleway, DigitalOcean Spaces, etc.

| Variable | Description | Required | Example |
|----------|-------------|----------|---------|
| `S3_ENDPOINT` | S3-compatible endpoint URL | — | `https://s3.fr-par.scw.cloud` |
| `S3_BUCKET` | Bucket name | — | `my-pi-web-backup` |
| `S3_REGION` | Region code | — | `fr-par` |
| `S3_ACCESS_KEY_ID` | Access key | — | *(from provider)* |
| `S3_SECRET_ACCESS_KEY` | Secret key | — | *(from provider)* |

**Features using S3:**
- **Backrest** — Automated restic backups
- **Beszel** — Backup storage + file uploads
- **Nextcloud** — External storage mounting (optional)

**Set all 5 or leave all empty** — partial config will error.

### Backrest (Restic Backup)

| Variable | Description | Default | Notes |
|----------|-------------|---------|-------|
| `BACKREST_S3_URI` | Restic repository URI | Auto-derived | Set if using non-S3 storage |
| `BACKREST_S3_REPO_PASSWORD` | Repository encryption key | — | 32+ chars, random recommended |
| `NEXTCLOUD_SQL_BACKUP_KEEP` | Days of SQL backups to retain | `7` | Separate from full backups |

**Auto-derived URI format:** `s3:${S3_ENDPOINT}/${S3_BUCKET}/restic`

**Without S3:**
- Backrest uses local `${DATA_LOCATION}/backrest-data` directory
- No automated off-site backups
- Consider adding `BACKREST_S3_*` for safety

### Beszel Monitoring

| Variable | Description | Default | Notes |
|----------|-------------|---------|-------|
| `BESZEL_S3_FORCE_PATH_STYLE` | Force path-style S3 URLs | `true` | For non-AWS providers |
| `BESZEL_BACKUP_CRON` | PocketBase backup schedule | `0 3 * * *` | Runs at 3:00 AM daily |
| `BESZEL_BACKUP_MAX_KEEP` | Max backup snapshots to keep | `7` | Older backups deleted |
| `BESZEL_TEMP_ALERT_VALUE` | Temperature alert threshold | `70` | In Celsius |
| `BESZEL_TEMP_ALERT_MIN` | Min time before alert repeats | `5` | In minutes |

**Cron format:** `minute hour day month weekday`
- `0 3 * * *` = 3:00 AM daily
- `0 0 * * 0` = Sunday midnight (weekly)
- `*/6 * * * *` = Every 6 hours

### Email & SMTP

| Variable | Description | Default | Notes |
|----------|-------------|---------|-------|
| `SMTP_HOST` | SMTP server hostname | `localhost` | e.g., `smtp.gmail.com` |
| `SMTP_PORT` | SMTP port | `587` | 587 = TLS, 465 = SSL, 25 = plain |
| `SMTP_USERNAME` | Authentication username | *(empty)* | Often your email address |
| `SMTP_PASSWORD` | Authentication password | *(empty)* | Use app-specific password for Gmail |
| `SMTP_SECURE` | Connection security | `tls` | Nextcloud: `tls`, `ssl`, or empty |
| `SMTP_AUTHTYPE` | Auth method | `LOGIN` | Nextcloud: `LOGIN`, `PLAIN`, etc. |
| `SMTP_ENCRYPTION` | Encryption mode | `STARTTLS` | LLDAP: `STARTTLS`, `NONE` |
| `SMTP_SSL` | Enable SSL | `false` | n8n: `true` or `false` |
| `MAIL_FROM_ADDRESS` | Sender local part | `nextcloud` | Nextcloud: `noreply@${MAIL_DOMAIN}` |
| `MAIL_DOMAIN` | Sender domain | `${HOST_NAME}` | Combined: `nextcloud@pi.example.com` |

**Services auto-configured:**
- Authelia, Nextcloud, LLDAP, n8n, Ntfy, Beszel, Dockhand (read from `.env` and generated startup config)

**Services needing manual setup:**
- Uptime Kuma, Immich (configure via their UIs)

**Quick setup for Gmail:**
```env
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USERNAME=your-email@gmail.com
SMTP_PASSWORD=app-specific-password  # Generate at https://myaccount.google.com/apppasswords
SMTP_SECURE=tls
```

**Disable email:**
- Leave `SMTP_HOST` empty or set to `localhost`
- Stack starts normally, email delivery fails silently
- Authelia disables startup check to keep stack resilient

### Authentication (Auto-configured)

These are auto-generated on first start; **do not edit manually**:

| Secret | Location | Purpose |
|--------|----------|---------|
| `jwt_secret` | `authelia-config/secrets/jwt_secret` | Authelia token signing |
| `session_secret` | `authelia-config/secrets/session_secret` | Cookie signing |
| `storage_encryption_key` | `authelia-config/secrets/storage_encryption_key` | DB encryption |
| `oidc_hmac_secret` | `authelia-config/secrets/oidc_hmac_secret` | OIDC token HMAC |
| `oidc_private_key.pem` | `authelia-config/secrets/oidc_private_key.pem` | JWT RS256 signing |
| `oidc_*_secret.txt` | `authelia-config/secrets/` | Per-client OIDC secrets |
| `ldap_password` | `authelia-config/secrets/ldap_password` | LLDAP bind password |

**Generated by:** `scripts/authelia-pre-start.sh` (runs on first start)
**Permissions:** `600` (owner read/write only)

OIDC client secrets are injected into services via Docker volumes, never exposed in environment.

### Download Stack (qBittorrent + Gluetun VPN)

qBittorrent runs inside Gluetun's network namespace — all torrent traffic exits through the configured VPN tunnel. The WebUI is exposed by the Gluetun container (which owns the network interface) and proxied by Traefik at `https://qbittorrent.<HOST_NAME>`.

**VPN configuration** is managed via a separate env file (not `.env`):

1. Copy `config/gluetun/gluetun.env.dist` to `config/gluetun/gluetun.env`
2. Fill in your provider credentials

| Variable | Description | Example |
|----------|-------------|---------|
| `VPN_SERVICE_PROVIDER` | Provider name | `mullvad`, `nordvpn`, `protonvpn`, `custom` |
| `VPN_TYPE` | Protocol | `wireguard` or `openvpn` |
| `WIREGUARD_PRIVATE_KEY` | WireGuard private key | *(from provider)* |
| `WIREGUARD_ADDRESSES` | WireGuard client address | `10.x.x.x/32` |
| `OPENVPN_USER` / `OPENVPN_PASSWORD` | OpenVPN credentials | *(from provider)* |
| `SERVER_COUNTRIES` | VPN server country filter | `Netherlands` |
| `FIREWALL_VPN_INPUT_PORTS` | Allow inbound on VPN interface | `6881` (improves peer reachability) |

The env file is optional — if absent, Gluetun starts without a VPN (traffic goes through the host's default route).

**Credentials bootstrap** — qBittorrent credentials (`USER`/`PASSWORD` from `.env`) are applied automatically on first start by `scripts/qbittorrent-bootstrap.sh`. The config template (`config/qbittorrent/qBittorrent.conf.template`) pre-configures auth bypass for localhost and `ALLOW_IP_RANGES` so the bootstrap script can call the API unauthenticated. Idempotent on subsequent restarts.

### Headscale VPN

These are auto-generated; no manual configuration needed:

| File | Purpose | Generated by |
|------|---------|--------------|
| `config/headplane/headscale_api_key` | Headplane → Headscale admin API access | `scripts/headscale-init.sh` |

## Custom Configuration

### Overriding Defaults

Environment variables from `.env` override defaults in:
- `compose.yaml` — Docker service definitions
- `config/traefik/` — Reverse proxy routes
- `config/authelia/` — SSO configuration

To customize, either:
1. Edit `.env` (preferred for secrets)
2. Edit `config/` files (for non-secrets)

Changes require: `make restart`

### Adding New Services

To add a service:
1. Add container definition to `compose.yaml`
2. Create config files in `config/<service>/`
3. Set environment variables in `.env`
4. Define Traefik routes (or use auto-discovery if available)
5. Update ALLOW_IP_RANGES if needed
6. Run `make install` or `make restart`

### Changing Passwords

**LLDAP admin:**
1. Update `PASSWORD` in `.env`
2. `make restart`
3. LLDAP admin password resets on startup if it detects mismatch

**Regular user:**
- Use Authelia portal → **Account** → **Change password**
- Or LLDAP admin UI → **Users** → **Reset password**

**Authelia system:**
- Stored in `authelia-config/secrets/` (auto-generated)
- To regenerate all secrets: delete the secrets directory and restart
- **Warning:** This invalidates all existing sessions; users must re-authenticate

## Verification

After editing `.env`:

```bash
# Verify syntax
make preflight

# Apply changes
make restart

# Check status
make status

# Watch startup
make logs
```

If something breaks:
1. `make stop`
2. Review your `.env` changes
3. `make start` again
4. Check logs: `make logs`

## Backup Configuration

Always backup your `.env` and `config/` directory:

```bash
tar -czf pi-web-config-backup.tar.gz \
  .env \
  config/ \
  data/authelia-config/secrets/
```

Keep backups in multiple places (S3, external drive, etc.) for disaster recovery.
