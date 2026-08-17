# Configuration

All configuration is managed through the `.env` file. Copy `.env.dist` and edit with your values.

## Environment Variables

### Personal Settings

| Variable | Description | Required | Default | Example |
|----------|-------------|----------|---------|---------|
| `HOST_NAME` | Your domain name | ✓ | — | `pi.example.com` |
| `TIMEZONE` | Server timezone | ✓ | — | `Europe/Paris` |
| `ADMIN_USER` | Stack-wide admin username | ✓ | — | `admin` |
| `PASSWORD` | LLDAP admin & Authelia password | ✓ | — | `MySecurePassword123!` |
| `EMAIL` | Admin email & sender address | ✓ | — | `admin@example.com` |
| `DATA_LOCATION` | Path for persistent data | — | `./data` | `/mnt/ssd/pi-pcloud-data` |

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
| `S3_BUCKET` | Bucket name | — | `my-pi-pcloud-backup` |
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

**Credentials bootstrap** — qBittorrent credentials (`ADMIN_USER`/`PASSWORD` from `.env`) are applied automatically on first start by `scripts/qbittorrent-bootstrap.sh`. The config template (`config/qbittorrent/qBittorrent.conf.template`) pre-configures auth bypass for localhost and `ALLOW_IP_RANGES` so the bootstrap script can call the API unauthenticated. Idempotent on subsequent restarts.

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

### Disabling Containers with `compose.override.yaml`

Use `compose.override.yaml` to disable optional services without editing `compose.yaml`.

`docker compose` automatically loads:
- `compose.yaml`
- `compose.override.yaml` (if present)

To disable a service by default, assign it to a profile that you do not enable (for example `disabled`):

```yaml
services:
  n8n:
    profiles:
      - disabled

  n8n-runners:
    profiles:
      - disabled

  open-webui:
    profiles:
      - disabled
```

With this override in place:
- `make start` / `make restart` keeps those services stopped
- The rest of the stack starts normally

To re-enable one temporarily, start it with its profile explicitly enabled.

To make it permanent again, remove the `profiles` block for that service from `compose.override.yaml` and restart the stack.

Verify what is running with `make status` (or `docker compose ps`).

### Adding New Services

To add a service:
1. Add container definition to `compose.yaml`
2. Create config files in `config/<service>/`
3. Set environment variables in `.env`
4. Define Traefik routes (or use auto-discovery if available)
5. Update ALLOW_IP_RANGES if needed
6. Run `make install` or `make restart`

### Local AI Model (llama.cpp + Open WebUI)

Open WebUI at `https://ai.<YOUR_DOMAIN>` talks to `llama-cpp`, which serves
**Gemma 4 E2B** (Google's QAT Q4_0 build, text + image + audio in) over an
OpenAI-compatible API on the internal `ai` network. There is no Ollama in the
stack: llama.cpp is the engine Ollama wraps, and running it directly is faster
on ARM CPU and one process instead of two.

Measured on a Raspberry Pi 5 (16GB, 3 threads pinned to cores 1-3):
~10 tok/s generation, ~40 tok/s prompt processing, ~3.7GB resident.

**Where the weights live.** `scripts/llama-cpp-pre-start.sh` downloads them into
the `llama_models` Docker volume (on the NVMe root, not `DATA_LOCATION`) before
the stack starts, because the `ai` network is internal and the container cannot
reach HuggingFace itself. It is idempotent - it only re-downloads a file whose
size does not match the remote one. To re-check by hand:

```bash
sh scripts/llama-cpp-pre-start.sh
```

**Why the connection is bootstrapped, not just configured.** `OPENAI_API_BASE_URL`
and friends are Open WebUI *PersistentConfig* variables: they seed the database
on first start and are ignored afterwards, so on an instance that already has
connections the model simply never shows up in the picker.
`scripts/open-webui-bootstrap.sh` (an `ExecStartPost` hook) appends
`http://llama-cpp:8080/v1` to the stored connection list when it is missing,
leaves any other connection you configured in the UI alone, and restarts
open-webui only when it changed something. Run it by hand after a database
restore:

```bash
sh scripts/open-webui-bootstrap.sh
```

**Changing the model.** Edit the `DOWNLOADS` list in
`config/llama-cpp/fetch-models.sh`, then point `LLAMA_ARG_MODEL` (and
`LLAMA_ARG_MMPROJ` / `LLAMA_ARG_SPEC_DRAFT_MODEL`, or drop them) at the new
files in `compose.yaml`. Prefer `Q4_0` quantisations: llama.cpp repacks those
into the ARM i8mm/dotprod kernels the Pi 5 has. Anything much past ~4B
parameters will be too slow to chat with on CPU.

**Tuning knobs** (all `environment:` entries on the `llama-cpp` service):

| Variable | Default here | Notes |
|----------|--------------|-------|
| `LLAMA_ARG_CTX_SIZE` | `16384` | Context window. The model supports 128k; RAM and prompt-processing time do not. |
| `LLAMA_ARG_THINK_BUDGET` | `512` | Thinking-token cap. `0` disables reasoning (fastest first token), `-1` lets it run unrestricted. |
| `LLAMA_ARG_THREADS` | `3` | Matched to `cpuset: "1-3"`, leaving core 0 for Traefik and DNS. A 4th thread measured no faster. |
| `LLAMA_ARG_SPEC_TYPE` | `draft-mtp` | Speculative decoding via Gemma 4's multi-token-prediction head; roughly doubles generation speed. Remove it and `LLAMA_ARG_SPEC_DRAFT_MODEL` to disable. |
| `LLAMA_ARG_MMPROJ` | mmproj file | Vision/audio input. Removing it saves ~1GB of RAM and re-enables `--cache-reuse`. |

### Changing Passwords

**LLDAP admin (the shared `PASSWORD` / SSO master credential) - after a leak:**
- Run `make rotate-password` - rotates the LLDAP admin account (via the LDAP
  password-modify operation, not an env var) and Authelia's matching
  `ldap_password` secret. This is the actual credential a leaked `PASSWORD`
  exposes, since everything logs in through Authelia SSO.
- **Note:** updating `PASSWORD` in `.env` and restarting/recreating `lldap` on
  its own does **not** change the admin account's password - LLDAP does not
  reset an existing admin's password to match the env var on startup, despite
  older guidance here. `make rotate-password` (or `scripts/rotate-password.sh`)
  is the only correct way to do this.
- For a full rotation across every Postgres role and every other service that
  also uses `PASSWORD` (Nextcloud, Pi-hole, qBittorrent, Prowlarr, Kapowarr,
  Beszel, ntfy, Dockhand), use `make rotate-password-full` instead.
  See `scripts/rotate-password.sh`'s header comment for the exact ordering
  constraints it handles (Nextcloud's `config.php` dbpassword, Authelia's
  `db_password` secret vs. its `AUTHELIA_DB_PASSWORD` env var, etc.) - doing
  these by hand out of order breaks things.

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
tar -czf pi-pcloud-config-backup.tar.gz \
  .env \
  config/ \
  data/authelia-config/secrets/
```

Keep backups in multiple places (S3, external drive, etc.) for disaster recovery.
