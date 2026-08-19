# Commands Reference

Run all commands from the pi-pcloud directory: `/opt/pi-pcloud`

## Make Commands

| Command | Description |
|---------|-------------|
| `make preflight` | Verify Docker, cgroup v2, and dependencies |
| `make install` | Deploy stack and create systemd service |
| `make uninstall` | Remove stack, volumes, and units (**destructive**) |
| `make start` | Start all services |
| `make stop` | Stop all services |
| `make restart` | Restart all services (after config changes) |
| `make status` | Show stack status and port bindings |
| `make logs` | Follow live logs |
| `make update` | `git pull` + restart |
| `make doctor` | Report anything outside its threshold: disk, RAM, swap, temperature, load, containers, restarts, backups |
| `make check-env` | Validate required `.env` variables |
| `make headscale-register <key>` | Register a device to VPN |
| `make headscale-reset` | Reset all VPN nodes (**destructive**) |
| `make rotate-password` | Rotate `PASSWORD` after a leak (LLDAP admin + Authelia) |
| `make rotate-password-full` | Same, plus every Postgres role and every other service using `PASSWORD` |

## Quick Workflows

**First-time setup** (guided — clones, builds `.env`, deploys; see [Installation](INSTALLATION.md#quick-install-one-liner)):
```bash
curl -fsSL https://raw.githubusercontent.com/florianajir/pi-pcloud/main/install.sh | sh
```

**First-time setup (manual):**
```bash
cp .env.dist .env                       # Edit with your values
make preflight
make install
make logs
```

**Check status:**
```bash
make status
make logs
```

**After editing `.env`:**
```bash
make restart
```

**View service logs:**
```bash
docker compose logs traefik             # or: authelia, nextcloud, pihole, etc.
docker compose logs -f <service>        # Follow live
```

**Add device to VPN:**
```bash
tailscale up --login-server https://headscale.<YOUR_DOMAIN>
# Open the printed URL and sign in via Authelia — or register the key manually:
make headscale-register <key-from-the-url>
```

**Update the stack:**
```bash
make update                             # git pull + restart
docker compose pull && make restart     # only re-pull pinned images
```

## See Also

- [Installation](INSTALLATION.md) — Setup instructions
- [Configuration](CONFIGURATION.md) — Environment variables
- [Architecture](ARCHITECTURE.md) — System design
- [Security](SECURITY.md) — Authentication
- [Monitoring](MONITORING.md) — Beszel, alerts, backups
- [Tailscale](TAILSCALE.md) — VPN setup
