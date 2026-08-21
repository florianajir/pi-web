# Installation

## Before you start

- A **Raspberry Pi 5** (8 GB minimum, 16 GB recommended) running Raspberry Pi OS, ideally booting from an NVMe SSD.
- A **domain on Cloudflare** (free tier) and an API token with `Zone → DNS → Edit` on it — dashboard → **API Tokens** → Create token.
- **Docker and the Compose plugin.** The installer offers to install them if missing.
- Your router forwarding **`443/tcp`** to the Pi. Optionally `41641/udp` and `3478/udp` for direct VPN links.

## Guided install

```bash
curl -fsSL https://raw.githubusercontent.com/florianajir/pi-pcloud/main/install.sh | sh
```

The installer:

1. **Checks prerequisites** — `git`, `make`, Docker, the Compose plugin; offers to install what's missing via `apt-get` / [get.docker.com](https://get.docker.com). A fresh Docker install requires logging out and re-running, since the `docker` group only takes effect at next login.
2. **Clones the repository** into `~/pi-pcloud` (`/opt/pi-pcloud` when run as root). Override with `PI_PCLOUD_DIR=/path`, or run it from inside an existing clone to reuse that checkout — it is fast-forwarded in place.
3. **Builds `.env`** from `.env.dist`, prompting only for what it cannot work out: domain, email, admin user, Cloudflare token and zone. Timezone and the whole network layout are auto-detected, and `PASSWORD` can be generated for you.
4. **Asks which services to run**, using the same picker as `make config` — everything pre-selected, grouped into sections, linked services toggling together. Core infrastructure always runs, and the choice can be changed any time. See [Choosing which services run](CONFIGURATION.md#choosing-which-services-run).
5. **Runs `make preflight`, then `make install`.**

Prompts use `whiptail` dialogs when available (it ships with Raspberry Pi OS) and fall back to plain terminal prompts otherwise, with identical behaviour. A host without `python3` skips step 4 and keeps every service enabled.

### What it detects, and when it asks anyway

The network layout is resolved before the first prompt, because macvlan gives Pi-hole its own LAN address and is picky about its parent:

| Situation | What happens |
|-----------|--------------|
| Parent interface is Wi-Fi, or a VPN tunnel owns the default route | Asks for confirmation — macvlan needs a wired parent |
| Subnet is not a `/24` | Asks for `PIHOLE_IP` explicitly |
| Something already answers a ping at the chosen Pi-hole address | Skips it and picks another |
| Layout cannot be determined at all | Asks before falling back to the `192.168.1.0/24` placeholders from `.env.dist` |

The fallback is all-or-nothing, so a half-detected layout is never mixed with placeholders. The installer stops if that confirmation is refused, and an unattended run also stops on an auto-detected Wi-Fi or tunnel parent — export `HOST_LAN_PARENT` to override, since nobody is there to read the warning.

### Re-running and unattended installs

It is safe to re-run: an existing clone is fast-forwarded, and an existing `.env` is never modified. `.env` only appears once fully configured, so an interrupted run restarts cleanly.

Any prompt can be pre-answered by exporting the variable first — `HOST_NAME`, `EMAIL`, `ADMIN_USER`, `PASSWORD`, `TIMEZONE`, `HOST_LAN_IP`, `CLOUDFLARE_DNS_API_TOKEN`, `CLOUDFLARE_ZONE_ID`. Exported network values (`HOST_LAN_PARENT`, `HOST_LAN_SUBNET`, `HOST_LAN_GATEWAY`, `PIHOLE_IP`, `ALLOW_IP_RANGES`) override auto-detection, and an exported `COMPOSE_PROFILES` skips the service picker — without it, a non-interactive run enables everything.

That makes fully unattended installs possible from a non-interactive shell:

```bash
export HOST_NAME=pi.example.com EMAIL=admin@example.com ADMIN_USER=admin PASSWORD='…'
export CLOUDFLARE_DNS_API_TOKEN='…' CLOUDFLARE_ZONE_ID='…'
export COMPOSE_PROFILES=nextcloud,immich-server,immich-machine-learning
curl -fsSL https://raw.githubusercontent.com/florianajir/pi-pcloud/main/install.sh | sh
```

They need passwordless sudo (the Raspberry Pi OS default), since `make install` applies sysctl, `/etc/hosts` and systemd changes.

Values must satisfy the [`.env` value syntax rule](CONFIGURATION.md) — the installer and `make check-env` both enforce it through `scripts/lib.sh`, so a prompt and a later check can never disagree.

Optional settings (SMTP, S3 backups, `DEFAULT_LANGUAGE`) are left empty; fill them in `.env` later.

## Manual install

```bash
git clone https://github.com/florianajir/pi-pcloud.git
cd pi-pcloud
cp .env.dist .env       # fill in the required variables
make preflight          # Docker, Compose, cgroup v2, required commands
make install            # systemd units, secrets, containers, databases
make logs               # first startup takes 2–5 minutes
```

The variables you must set are listed in [Configuration → Required variables](CONFIGURATION.md#required-variables); `make check-env` validates them.

## First login

### 1. Create your users in LLDAP

Visit `https://lldap.<HOST_NAME>` and log in as `admin` with your `PASSWORD`.

- Create users under **Admin → Users**.
- Create an **`admin` group** and add your admin accounts to it. It gates the admin tools — Traefik, Pi-hole, Backrest, LLDAP, Dockhand, Headplane — behind 2FA. Regular users need no group at all.

### 2. Log in through the SSO portal

Visit `https://auth.<HOST_NAME>` and sign in with an LLDAP account. Admin users are prompted to enrol TOTP or a WebAuthn key on first access to a protected admin tool.

### 3. Open your services

Everything is wired to SSO already — just visit it and you'll be redirected to the portal:

`https://nextcloud.<HOST_NAME>` · `https://immich.<HOST_NAME>` · `https://vault.<HOST_NAME>` · `https://ai.<HOST_NAME>` · `https://beszel.<HOST_NAME>` · `https://uptime.<HOST_NAME>` · `https://n8n.<HOST_NAME>` · `https://dockhand.<HOST_NAME>`

`https://homepage.<HOST_NAME>` is a dashboard listing all of them, with live widgets. The full list with its protection model is in [Security](SECURITY.md#per-service-protection).

### 4. Kavita — one manual step

Kavita's OIDC connection is provisioned automatically (`scripts/kavita-oidc-bootstrap.sh` writes the client, secret and `appsettings.json`), but its **role mapping and account auto-provisioning live in its own database**, editable only through the UI. Once per fresh install:

1. Visit `https://kavita.<HOST_NAME>` and create the **admin account** by normal registration.
2. **Settings → OpenID Connect** — Authority, Client ID and Secret are already filled in.
3. Enable **Auto-Provision** so Authelia users get a Kavita account on first login.
4. Under **Advanced settings**, set **Roles claim** to `groups`. The default `.../claims/role` is not emitted by Authelia. Leave **Custom scopes** as `groups`.
5. To grant admin via SSO, put the user in an LLDAP group whose name matches a Kavita role (e.g. `Admin`), or set a **Roles prefix** such as `kavita-` and use groups like `kavita-admin`.

These persist in the `kavita_config` volume. They are deliberately not automated — there is no stable config-file surface for them, and `kavita.db`'s schema is not stable across updates, so do not edit it directly.

> Kavita's email settings have the same problem, but with OIDC + Auto-Provision they are usually unnecessary: they only power local-account flows (invites, setup links, password resets) that SSO bypasses. If you want them anyway, fill **Settings → Email** with your `SMTP_*` values from `.env`.

## Next steps

- **[Connect your devices to the VPN](TAILSCALE.md)** — one command per device.
- **[Set up off-site backups](CONFIGURATION.md#backrest-restic-backups)** — S3 credentials plus a repository password.
- **[Configure SMTP](EMAIL.md)** — password resets and alert emails.
- **[Subscribe to the ntfy topics](MONITORING.md#ntfy-topics)** — alerts on your phone.
- Something not working? **[Troubleshooting](TROUBLESHOOTING.md)**.
