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
| `make headscale-register <key>` | Register a device to VPN |
| `make headscale-reset` | Reset all VPN nodes (**destructive**) |

## Quick Workflows

**First-time setup:**
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
tailscale up --login-server https://headscale.<YOUR_DOMAIN>:443
# Copy URL from output, then:
make headscale-register <paste-url-here>
```

**Update services:**
```bash
docker compose pull
make restart
```

## See Also

- [Installation](INSTALLATION.md) — Setup instructions
- [Configuration](CONFIGURATION.md) — Environment variables
- [Architecture](ARCHITECTURE.md) — System design
- [Security](SECURITY.md) — Authentication
- [Monitoring](MONITORING.md) — Beszel, alerts, backups
- [Tailscale](TAILSCALE.md) — VPN setup
