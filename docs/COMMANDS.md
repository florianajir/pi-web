# Commands Reference

## The `pi-pcloud` command

`make install` puts a `pi-pcloud` command on `PATH`, so everything below is reachable from any directory:

```bash
pi-pcloud config             # same as `make config`
pi-pcloud enable stremio     # same as `make enable stremio`
pi-pcloud status             # same as `make status`
pi-pcloud update             # pull code and images, rebuild, restart
pi-pcloud                    # the command list
```

It is a thin dispatcher onto the Makefile — same output, same exit code, same arguments (both forms take the service name positionally; `s=<service>` still works with `make` for compatibility), and a target added there needs no change here. Tab completion covers both the commands and, after `enable` / `disable`, the service names (bash and zsh; open a new shell after installing).

The command is a symlink to `scripts/pi-pcloud` inside the checkout, so `git pull` updates it. Point `PI_PCLOUD_DIR` at another checkout to override which one it drives.

## Make Commands

Run these from the pi-pcloud directory (`/opt/pi-pcloud`), or use the `pi-pcloud` command above from anywhere.

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
| `make services` | List optional services and whether each is enabled (`COMPOSE_PROFILES`) |
| `make enable <service>` | Enable an optional service: update `COMPOSE_PROFILES` in `.env`, start it, run its init hooks |
| `make disable <service>` | Disable an optional service: update `COMPOSE_PROFILES` in `.env` and stop it |
| `make config` | Interactive checklist to choose which optional services run |
| `make update` | Pull the repository and updated images, rebuild the locally built ones, restart, prune replaced layers |
| `make doctor` | Report anything outside its threshold: disk, RAM, swap, temperature, load, containers, restarts, backups |
| `make check-env` | Validate required `.env` variables |
| `make test` | Run the installer and `check-env` test suites (temporary copies only, no host changes) |
| `make headscale-register <key>` | Register a device to VPN |
| `make headscale-reset` | Reset all VPN nodes (**destructive**) |
| `make rotate-password` | Rotate `PASSWORD` after a leak (LLDAP admin + Authelia) |
| `make rotate-password-full` | Same, plus every Postgres role and every other service using `PASSWORD` |

**About `update`:** images are refreshed while the stack is still running, so the interruption is a single restart rather than a download. It only pulls what the current `COMPOSE_PROFILES` selects, rebuilds the five images built from `config/*/Dockerfile` against their updated bases, and finishes with `docker image prune -f`, which reclaims the layers the recreated containers released (dangling images only — nothing a container still references). Expect several minutes on a Pi when base images have moved.

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

**Toggle optional services** (see [Configuration → Choosing which services run](CONFIGURATION.md#choosing-which-services-run)):
```bash
make services                           # What is enabled right now?
make config                             # Interactive checklist (whiptail)
make enable stremio                     # Auto-starts gluetun too, runs init hooks
make disable n8n
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
make update                             # code + images, then one restart
docker compose pull && make restart     # only re-pull pinned images
```

## See Also

- [Installation](INSTALLATION.md) — Setup instructions
- [Configuration](CONFIGURATION.md) — Environment variables
- [Architecture](ARCHITECTURE.md) — System design
- [Security](SECURITY.md) — Authentication
- [Monitoring](MONITORING.md) — Beszel, alerts, backups
- [Tailscale](TAILSCALE.md) — VPN setup
