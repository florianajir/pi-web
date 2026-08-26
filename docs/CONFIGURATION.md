# Configuration

Everything is configured through `.env` at the root of the repository. Copy `.env.dist`, fill it in, and apply with `make restart`.

```bash
cp .env.dist .env
make check-env        # validates the required variables
make restart
```

> **Value syntax.** Do not use `$` or ` #` (whitespace + hash) in a value, do not end a value with `\`, do not quote values, and do not leave leading or trailing whitespace.
> Docker Compose interpolates `$VAR` inside `.env` (so `Sup3r$ecret!` reaches the services as `Sup3r!`, with only a warning in the logs), escapes the newline after a trailing backslash, truncates unquoted values at inline comments, strips surrounding quotes and trims edge whitespace — while the bootstrap scripts read `.env` verbatim, so any of those makes the two sides disagree. A backslash *inside* a value is fine.
> `make check-env` refuses such values, using the same `scripts/lib.sh` rule the installer applies at its prompts.

## Required variables

| Variable | Description | Example |
|----------|-------------|---------|
| `HOST_NAME` | Your domain name | `pi.example.com` |
| `TIMEZONE` | Server timezone | `Europe/Paris` |
| `ADMIN_USER` | Stack-wide admin username | `admin` |
| `PASSWORD` | LLDAP admin & Authelia password | `MySecurePassword123!` |
| `EMAIL` | Admin email & sender address | `admin@example.com` |
| `HOST_LAN_IP` | The Pi's static LAN IP — local DNS records point here | `192.168.1.30` |
| `CLOUDFLARE_DNS_API_TOKEN` | Cloudflare API token, `Zone → DNS → Edit` on your domain | *(dashboard)* |
| `CLOUDFLARE_ZONE_ID` | Your domain's zone ID | *(dashboard)* |

`make print-required-vars` prints this list as the Makefile actually enforces it.

**Generating the Cloudflare token:** dashboard → **API Tokens** → Create token → Permissions `Zone → DNS → Edit`, Zone resources `Include → your domain`.

## Optional variables

### General

| Variable | Default | Description |
|----------|---------|-------------|
| `DEFAULT_LANGUAGE` | `en-US` | Stack-wide language (BCP 47) — Open WebUI interface, Piper voice, suggestion tiles. See [Local AI](AI.md#language) |
| `DATA_LOCATION` | `./data` | Where persistent data lives — point it at your SSD |
| `NEXTCLOUD_DEFAULT_PHONE_REGION` | `FR` | ISO country code Nextcloud assumes for phone numbers without a prefix |
| `NEXTCLOUD_MAINTENANCE_WINDOW_START` | `2` | UTC hour at which Nextcloud runs its heavy background jobs |
| `COMPOSE_PROFILES` | `all` | Which optional services run — see [below](#choosing-which-services-run) |

### Network

Defaults suit a `192.168.1.0/24` LAN. The installer auto-detects all of these.

| Variable | Default | Notes |
|----------|---------|-------|
| `HOST_LAN_PARENT` | `eth0` | Network interface (`ip link` to find it). Must be wired — macvlan cannot use Wi-Fi |
| `HOST_LAN_SUBNET` | `192.168.1.0/24` | Your home network CIDR |
| `HOST_LAN_GATEWAY` | `192.168.1.1` | Your router's IP |
| `PIHOLE_IP` | `192.168.1.250` | Pi-hole's own LAN address — in the subnet, outside the DHCP range |
| `PIHOLE_DNS_UPSTREAMS` | `172.30.53.53#5335;1.1.1.1;9.9.9.9` | Unbound first; the public resolvers are failover only |
| `ALLOW_IP_RANGES` | `127.0.0.1/32,192.168.1.0/24,100.64.0.0/10,172.30.0.0/16` | Comma-separated CIDRs allowed to reach the services |

`ALLOW_IP_RANGES` in order: localhost, your home LAN (**adjust to your network**), the Tailscale allocation, and the Docker internal networks. It drives Traefik's `lan` middleware — see [Security](SECURITY.md#per-service-protection).

### S3 storage

Used by Backrest (backups), Beszel (snapshots and file uploads) and optionally Nextcloud external storage. Works with AWS S3, Scaleway, DigitalOcean Spaces and friends. **Set all five or leave all five empty** — a partial configuration errors.

| Variable | Example |
|----------|---------|
| `S3_ENDPOINT` | `https://s3.fr-par.scw.cloud` |
| `S3_BUCKET` | `my-pi-pcloud-backup` |
| `S3_REGION` | `fr-par` |
| `S3_ACCESS_KEY_ID` | *(from provider)* |
| `S3_SECRET_ACCESS_KEY` | *(from provider)* |

### Backrest (restic backups)

| Variable | Default | Notes |
|----------|---------|-------|
| `BACKREST_S3_URI` | `s3:${S3_ENDPOINT}/${S3_BUCKET}/restic` | Set explicitly for non-S3 storage |
| `BACKREST_S3_REPO_PASSWORD` | — | Repository encryption key. 32+ random characters |
| `NEXTCLOUD_SQL_BACKUP_KEEP` | `30` | Nextcloud SQL dumps retained, separate from the full backups |

Without complete S3 credentials Backrest still starts, but its `s3` repository is unusable — the pre-start script warns and the nightly plan has nowhere to write. For a local-only setup, create a repository under `/repos` (bind-mounted from `${DATA_LOCATION}/backrest/repos`) in the Backrest UI. See [Backup strategy](MONITORING.md#backup-strategy).

### Beszel

| Variable | Default | Notes |
|----------|---------|-------|
| `BESZEL_S3_FORCE_PATH_STYLE` | `true` | Needed by most non-AWS providers |
| `BESZEL_BACKUP_CRON` | `0 3 * * *` | PocketBase snapshot schedule (`minute hour day month weekday`) |
| `BESZEL_BACKUP_MAX_KEEP` | `7` | Snapshots retained |
| `BESZEL_TEMP_ALERT_VALUE` | `70` | Temperature alert threshold, °C |
| `BESZEL_TEMP_ALERT_MIN` | `5` | Minutes over the threshold before alerting |
| `BESZEL_TEMP_ALERT_OVERWRITE` | `false` | Set to `true` to let the bootstrap overwrite alerts you edited in the Beszel UI |

`BESZEL_BACKUP_CRON` is the switch: leave it empty and PocketBase's built-in backups stay off entirely. The CPU (90%), memory (90%) and disk (85%) alerts are constants in `scripts/beszel-agent-bootstrap.sh`, not variables — see [Monitoring](MONITORING.md#beszel--the-hardware).

### Email

| Variable | Default | Notes |
|----------|---------|-------|
| `SMTP_HOST` | `localhost` | Leave empty or `localhost` to disable email entirely |
| `SMTP_PORT` | `587` | 587 = STARTTLS, 465 = SSL, 25 = plain |
| `SMTP_USERNAME` | *(empty)* | Often your email address |
| `SMTP_PASSWORD` | *(empty)* | Use an app-specific password where the provider requires one |
| `SMTP_SECURE` | `tls` | Nextcloud only |
| `SMTP_AUTHTYPE` | `LOGIN` | Nextcloud only |
| `SMTP_ENCRYPTION` | `STARTTLS` | Authelia and LLDAP |
| `SMTP_SSL` | `false` | n8n only |
| `MAIL_FROM_ADDRESS` | `nextcloud` | Nextcloud sender local part; the domain is always `HOST_NAME` |

Which services read these, and which need setting up in their own UI: [Email & Notifications](EMAIL.md).

### Download VPN (Gluetun)

qBittorrent, Kapowarr and Stremio run inside Gluetun's network namespace, so all their traffic exits through the VPN tunnel. Gluetun's credentials live in **their own file**, not `.env`:

```bash
cp config/gluetun/gluetun.env.dist config/gluetun/gluetun.env
```

| Variable | Example |
|----------|---------|
| `VPN_SERVICE_PROVIDER` | `mullvad`, `nordvpn`, `protonvpn`, `custom` |
| `VPN_TYPE` | `wireguard` or `openvpn` |
| `WIREGUARD_PRIVATE_KEY` / `WIREGUARD_ADDRESSES` | *(from provider)* — `10.x.x.x/32` |
| `OPENVPN_USER` / `OPENVPN_PASSWORD` | *(from provider)* |
| `SERVER_COUNTRIES` | `Netherlands` |
| `FIREWALL_VPN_INPUT_PORTS` | `6881` — improves peer reachability |

The file is optional: without it Gluetun starts with no tunnel and traffic takes the host's default route.

qBittorrent's credentials (`ADMIN_USER` / `PASSWORD`) are applied on first start by `scripts/qbittorrent-bootstrap.sh`. The config template pre-authorises localhost and `ALLOW_IP_RANGES` so the bootstrap can call the API unauthenticated; it is idempotent on later restarts.

## Auto-generated secrets

These need no configuration and must not be edited by hand. `scripts/authelia-pre-start.sh` generates them on first start with mode `600` under `${DATA_LOCATION}/authelia-config/secrets/`, and `scripts/headscale-init.sh` generates `config/headplane/headscale_api_key`. Full inventory: [Security → Secrets](SECURITY.md#secrets).

## Choosing which services run

Every optional service in `compose.yaml` carries a [Compose profile](https://docs.docker.com/compose/how-tos/profiles/) named after itself (plus a catch-all `all`). `COMPOSE_PROFILES` selects them:

```env
COMPOSE_PROFILES=all                                          # everything (the default)
COMPOSE_PROFILES=immich-server,nextcloud,stremio,llama-cpp    # a selection
COMPOSE_PROFILES=                                             # core services only
```

**Core services always run** (they carry no profile): `traefik`, `authelia`, `lldap`, `postgres`, `redis`, `pihole`, `unbound`, `headscale`, `tailscale`, `ntfy`, `backrest`, `ddns-updater`, `homepage`. Pi-hole and Unbound stay core because subdomain resolution depends on the Pi-hole wildcard record; Headscale and Tailscale stay core because they provide remote access to everything else.

**Optional services:** `beszel`, `beszel-agent`, `uptime-kuma`, `dockhand`, `n8n`, `n8n-runners`, `headplane`, `immich-server`, `immich-machine-learning`, `nextcloud`, `gluetun`, `qbittorrent`, `stremio`, `comet`, `prowlarr`, `kapowarr`, `flaresolverr`, `kavita`, `vaultwarden`, `llama-cpp`, `piper`, `parakeet`, `system-tools`, `open-webui`.

**Some services pull in their dependencies** — the dependency carries the dependent's profile too, so enabling one starts both:

| Enabling | Also starts |
|----------|-------------|
| `qbittorrent`, `stremio` or `kapowarr` | `gluetun` (their VPN network namespace) |
| `n8n-runners` | `n8n` |
| `beszel-agent` | `beszel` |
| `prowlarr` | `flaresolverr` |

### Managing the selection

```bash
make config              # interactive checklist — the comfortable path
make services            # list each optional service and whether it is enabled
make enable stremio      # add to COMPOSE_PROFILES and start it (plus dependencies)
make disable stremio     # remove from COMPOSE_PROFILES and stop it
```

`make config` opens a terminal picker; on confirm it rewrites `COMPOSE_PROFILES` and starts or stops whatever changed. Services are listed under the section they belong to, and one that is pointless on its own is indented under its parent:

```
Choose which services run — applying starts and stops containers now
24/24 enabled · Traefik, Authelia, Pi-hole, Headscale, Postgres … always run
── Download ──────────────────────────────────────────────────────────────
 [x] prowlarr                   Indexer manager
 [x]   flaresolverr             Cloudflare challenge solver for Prowlarr
 [x] qbittorrent                Torrent client (VPN protected)
── Video ─────────────────────────────────────────────────────────────────
 [x] stremio                    Streaming server (VPN protected)
 [x]   comet                    Stremio debrid addon
```

Ticking propagates along both dependency relations — the hard ones in the table above, and the companion indent — transitively, so the screen always shows a set the stack can actually run: unticking `gluetun` unticks `qbittorrent`, `kapowarr`, `stremio` and — through `stremio` — `comet`. The footer names whatever moved.

The whole layout is read out of `compose.yaml` (`homepage.group` for the section, `homepage.description` for the text, `pi-pcloud.companion-of` for the indent, `profiles:` for the hard dependencies), so the picker cannot drift from the stack. It is `scripts/services-picker.py`, standard-library `curses` only — nothing to install on Raspberry Pi OS, and on a host without `python3` you simply use `make enable` / `make disable` instead. All three targets wrap `scripts/services.sh`, which is what actually writes `.env` and runs the hooks.

Enabling also runs the service's init hooks — `scripts/<service>-pre-start.sh` before the start, `scripts/<service>-bootstrap.sh` / `-oidc-bootstrap.sh` after — the same scripts the systemd unit runs. So no `make restart` is needed: the stack is immediately consistent, and the unit reads the same `.env` at next boot.

> **Upgrading an older install:** an `.env` with no `COMPOSE_PROFILES` line keeps running everything, because the systemd unit defaults the variable to `all`. Manual `docker compose` invocations do not get that default, so add `COMPOSE_PROFILES=all` to your `.env`.

## Changing passwords

**The admin password (`PASSWORD`) after a leak** — set the new value in `.env`, then:

```bash
make rotate-password         # LLDAP admin account + Authelia's bind secret
make rotate-password-full    # the above, plus every Postgres role and every service using PASSWORD
```

Editing `.env` alone is **not enough**: LLDAP does not reset an existing admin's password to match the env var on startup. `make rotate-password` performs the actual LDAP password-modify operation and updates Authelia's `ldap_password` secret — and since everything logs in through Authelia SSO, that is the credential a leaked `PASSWORD` actually exposes.

`rotate-password-full` additionally covers Nextcloud, Vaultwarden, Pi-hole, qBittorrent, Prowlarr, Kapowarr, Beszel, ntfy and Dockhand. See the header comment of `scripts/rotate-password.sh` for the ordering constraints it handles (Nextcloud's `config.php` dbpassword, Authelia's `db_password` secret versus its `AUTHELIA_DB_PASSWORD` env var); doing these by hand out of order breaks things.

Every service holding a Postgres role must be rotated *and* recreated together, since the role password and the connection string in the container's environment have to move as one. A role that is rotated without its container being recreated does not fail immediately — the running container keeps its established connection — it fails at the *next* recreate, which may be an unrelated reboot or image bump long afterwards. `vaultwarden` was missing from both lists until it was added; if you add another Postgres-backed service, wire it into `rotate_postgres_roles()`, give it a `*_ROLE_OK` gate, and add it to Backrest's gate, which needs every role it dumps.

**A regular user** resets their own password from the Authelia portal (**Account → Change password**) or has it reset from the LLDAP admin UI.

**Authelia's own secrets** are auto-generated. To regenerate them all, delete `${DATA_LOCATION}/authelia-config/secrets/` and restart — this invalidates every session and everyone must log in again.

## Customising further

A `compose.override.yaml` is not the way to switch services off — `profiles:` lists *merge* across compose files, so an override can only add activation profiles, never remove the built-in ones. Use `make enable` / `make disable`, and verify with `make services` or `make status`.

Non-secret behaviour lives in `config/<service>/` (Traefik is the exception: it is configured entirely by CLI flags and labels in `compose.yaml`). Secrets and anything a script reads belong in `.env`. Either way, apply with `make restart`.

To add a service to the stack, follow the [add-service checklist](../.agents/skills/add-service/SKILL.md) — it covers the Compose profile, Traefik labels, the Authelia OIDC client, shared Postgres/Redis, ntfy, Uptime Kuma, Backrest, Homepage labels and the systemd bootstrap hook.

**Back up what cannot be regenerated** — `.env` and the Authelia secrets — somewhere other than the Pi:

```bash
tar -czf pi-pcloud-config-backup.tar.gz .env config/ data/authelia-config/secrets/
```
