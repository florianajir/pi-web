# Troubleshooting

Start here:

```bash
make doctor     # anything outside its threshold: disk, RAM, swap, temperature, load, containers, restarts, backups
make status     # what is running, and on which ports
make logs       # follow everything
```

`make doctor` asks the `system-tools` container for the same reading the AI assistant's `anomalies` topic returns, so the terminal and the chat cannot disagree.

## Startup

**The stack won't come up.** `make logs`, then look for the usual three:

| Symptom | Cause |
|---------|-------|
| Port binding errors | Something else already holds `80`, `443` or `53` — often `systemd-resolved` on 53 |
| Permission denied under `data/` | `${DATA_LOCATION}` is not writable by the containers' UID |
| Traefik logs ACME failures | The Cloudflare token lacks `Zone → DNS → Edit`, or the zone ID is wrong |

**A service depends on one that never became healthy.** `docker compose ps` shows which. Compose `depends_on: service_healthy` means one failing healthcheck can hold back a whole branch of the stack — check the dependency's own logs first, not the service that appears stuck.

## Access

**A service returns 403.** The `lan` middleware refused your source IP. Either you are reaching it from outside your LAN and tailnet, or the request hairpinned through your router and arrived with the WAN address. Check `ALLOW_IP_RANGES` in `.env` against the network you are actually on.

Traefik's access log records the address it actually saw, which is the one the allowlist judged — read it rather than guessing:

```bash
journalctl -t pi-traefik -n 200 | grep '"DownstreamStatus":403' | tail
```

To confirm the middleware is the culprit rather than the service, compare the two paths — bypassing DNS and the router should succeed where the hostname fails:

```bash
curl -k -o /dev/null -w '%{http_code}\n' -H "Host: vault.<HOST_NAME>" https://127.0.0.1/   # 200 = service is fine
curl -k -o /dev/null -w '%{http_code}\n' https://vault.<HOST_NAME>/                        # 403 = allowlist
```

A split verdict means the client resolved the public address instead of the Pi-hole one and hairpinned back with the WAN source. This is stack-wide, not per-service: every router carries `lan`, so check a second hostname before suspecting one container. Browser DNS-over-HTTPS ("Secure DNS") is a common trigger, since it silently bypasses Pi-hole even on the LAN — see [DNS](#dns).

**A service returns a generic 404 from Traefik.** Its router is gone. For qBittorrent, Prowlarr, Kapowarr and Stremio the usual cause is **gluetun being unhealthy** — they share its network namespace, so when it drops, all of their Traefik routes vanish at once rather than erroring individually. `docker compose ps gluetun` and `docker compose logs gluetun`.

**Nothing resolves from outside.** Check that DNS points at your public IP and that 443 is forwarded:

```bash
nslookup auth.<HOST_NAME>          # should return your public IP, via Cloudflare
docker compose logs traefik | tail -50
```

**Forgot or leaked the admin password.** Set the new `PASSWORD` in `.env` and run `make rotate-password`. Editing `.env` alone does **not** reset the LLDAP admin account — see [Configuration → Changing passwords](CONFIGURATION.md#changing-passwords). Regular users reset their own from the Authelia portal or the LLDAP admin UI.

## DNS

**Queries not resolving.**

```bash
docker compose logs pihole | tail -20
nslookup example.com <PIHOLE_IP>      # from a LAN device
```

If devices aren't using Pi-hole at all, check your router's DHCP DNS option, or set it manually on one device to test.

**Upstream resolution broken.**

```bash
docker compose logs unbound | tail -20
docker compose exec unbound drill @127.0.0.1 -p 5335 cloudflare.com
```

The Uptime Kuma `dns resolution` monitor covers this whole chain continuously — see [Monitoring](MONITORING.md#what-is-actually-checked).

**A link or a redirect leads nowhere.** Sponsored search results, newsletter links and affiliate links route through ad infrastructure, so the block lists catch them and the click dies on a blank page instead of just losing an ad.

To find the real culprit, check the Pi-hole query log for the click — **the blocked domain is often not the one you typed**. A status of *blocked (CNAME)* means an alias is at fault: `g.live.com` was blocked because it points at `g.msn.com`.

Add the domain to the `ALLOW_LISTS` in `scripts/pihole-bootstrap.sh`, not only in the web UI, or the next rebuild loses it.

**High latency.** First queries are slower while Unbound walks the delegation tree; its cache warms quickly. If it stays high, check RAM pressure in Beszel and consider trimming very large blocklists.

## VPN

**A device won't register.** `docker compose logs headscale | tail -30`. The login server must be `https://headscale.<HOST_NAME>` — port 443, valid TLS. A device registered before must be deleted before re-registering.

**Services unreachable from the VPN.** Verify the client got a `100.64.x.x` address (`tailscale ip`) and that DNS is accepted (`tailscale dns status`). Then `nslookup nextcloud.<HOST_NAME>` should return the Pi's LAN IP.

**Connections relay instead of going direct.** Forward `41641/udp` (WireGuard) and `3478/udp` (STUN) on your router. Without them traffic still works, but rides the embedded DERP relay.

**A node shows offline while the device is connected.** "Last seen" lags by design — check `tailscale status` on the device itself before trusting the list.

## Books and audiobooks

**Shelfmark finds nothing on Direct Download.** Check the mirror list first
(**Settings → Mirrors**): the stack seeds one, `https://annas-archive.gl`, and mirror
availability moves. `annas-archive.is` resolves and loads but does not work as a source.
A search that returns empty while the log shows it still running is usually the
Cloudflare solve, not the mirror — `RELEASE_SEARCH_TIMEOUT` allows 300 s for a cold one.

**A mirror keeps re-challenging even though FlareSolverr solved it.** Expected, and the
one known rough edge of routing downloads through the VPN. FlareSolverr obtains the
`cf_clearance` cookie on the residential IP — it is a shared container and is not behind
gluetun — while Shelfmark then replays that cookie from gluetun's exit IP. Cloudflare
ties clearance to the IP, so it can challenge again. Two ways out, both deliberate
choices rather than fixes:

- Give up the tunnel for direct downloads, accepting they leave on the residential IP
  (torrents are unaffected — they go through qBittorrent, which is inside gluetun).
  **Changing `PROXY_MODE` in Settings → Network does not stick**: the proxy is
  reconciled on every stack start by `scripts/shelfmark-settings-bootstrap.sh`, which
  owns that value. Blank `GLUETUN_HTTP_PROXY` at the top of that script, or drop gluetun
  from `COMPOSE_PROFILES` — the script then unwinds the setting itself.
- Move FlareSolverr behind gluetun too, so the solve and the download share one exit IP.
  That also puts every Prowlarr indexer solve on the VPN — a larger change, and one
  Prowlarr does not otherwise need.

**Books do not appear in Kavita.** Shelfmark files into `download/books/`, which Kavita
scans as its **Books** library; its own in-progress grabs live in `download/shelfmark/`
and are meant to be invisible to Kavita. Check the file actually landed, then trigger a
library scan. Audiobooks go to `download/audiobooks/` and Kavita never reads them —
those are Audiobookshelf's library, and are also browsable through Nextcloud.

**Audiobookshelf's "Sign in with SSO" answers 400 `Invalid callback URL`.** The image
leaves `ROUTER_BASE_PATH` unset, and the server reads an unset value as
`/audiobookshelf` — every URL still works, because one without the prefix is rewritten
to carry it, so nothing looks wrong until a login. The callback check demands the URL
start with that base path, and `/login` does not. `compose.yaml` sets the variable to
the empty string, which is what actually turns the subfolder off; check it survived a
hand edit with `docker logs pi-audiobookshelf | head -2`.

**Signing in to Audiobookshelf through SSO lands on a second, non-admin account.** The
root account is created by `scripts/audiobookshelf-bootstrap.sh` and is matched to your
Authelia identity **by email** — so it only links if the LLDAP account you sign in with
carries the same address as `EMAIL` in `.env`. Fix the address on either side and log in
again, or promote the new account from the root one (Settings → Users). Group claims are
deliberately not used: Audiobookshelf reads them as a role and denies anyone whose groups
contain none of `admin`/`user`/`guest`, which in this stack is every regular user.

**Shelfmark downloads an audiobook and nothing appears.** `download/audiobooks/` is the
one download folder with no writer inside a container to create it, so on stacks built
before `scripts/audiobookshelf-pre-start.sh` existed the Docker daemon created it as
`root:root` and Shelfmark (uid 1000) could not file anything there. That hook repairs
the ownership, but only when it runs as root — `sudo sh scripts/audiobookshelf-pre-start.sh`
if `make update` ran unprivileged and the start log warned about it.

**Nothing downloads and the log mentions the torrent client.** Shelfmark reaches
qBittorrent through gluetun (`http://gluetun:8080`) with `ADMIN_USER`/`PASSWORD`. If
`ADMIN_USER` is under 3 characters, qBittorrent rejected it and kept its own generated
login — `scripts/shelfmark-pre-start.sh` then leaves the client unset on purpose and
says so in the start log.

## Email

| Symptom | Cause |
|---------|-------|
| Connection refused | Wrong host or port, or your ISP blocks outbound 25 — use 587 |
| Authentication failed | Most providers refuse the account password; generate an app password |
| Nothing sent at all | `SMTP_HOST` is empty or `localhost`, which disables delivery by design |

```bash
docker compose logs authelia | grep -i -E 'smtp|mail'
docker compose logs nextcloud | grep -i mail
```

## Monitoring

**Beszel agent not reporting.** `docker compose logs beszel-agent`. The hub reads the agent over the shared `beszel_socket` volume, and the agent reads container stats from the Docker socket. If the hub shows the system offline, restarting `beszel-agent` usually reconnects it.

**ntfy webhook silent.** Check that `config/ntfy/ntfy.env` holds the expected topic, then test directly:

```bash
curl -d "test alert" https://ntfy.<HOST_NAME>/<topic>
```

**Authelia login alerts stopped.**

```bash
sudo systemctl status pi-pcloud-authelia-ntfy.service
sudo journalctl -u pi-pcloud-authelia-ntfy.service -f
```

A `WARNING: NTFY_AUTHELIA_PASSWORD missing` line means `ntfy-pre-start.sh` has not run since the feature was added:

```bash
sh scripts/ntfy-pre-start.sh && docker compose up -d ntfy
```

### Uptime Kuma database keeps growing

The nightly prune catches its own exceptions, so a failure leaves no trace except `data/uptime-kuma/error.log`. A corrupt page anywhere in `heartbeat` makes every run abort with `SQLITE_CORRUPT`, and the file then grows without bound:

```bash
docker exec pi-uptime-kuma grep -c SQLITE_CORRUPT /app/data/error.log
docker exec pi-uptime-kuma sqlite3 /app/data/kuma.db "PRAGMA integrity_check(5);"
```

**Never `VACUUM` a database that fails `integrity_check`** — it rewrites the whole file and can fail halfway. Recover from a copy instead, with a recent sqlite: the 3.40 shipped in the Kuma image aborts `.recover` with `SQL logic error`, while `alpine:latest` carries a working one.

```bash
docker stop pi-uptime-kuma          # clean shutdown, then copy kuma.db aside
docker run --rm -v /path/to/backup:/bk alpine:latest sh -c \
  'apk add --no-cache sqlite && cd /bk && \
   sqlite3 kuma.db ".recover" | sqlite3 kuma-recovered.db && \
   sqlite3 kuma-recovered.db "PRAGMA integrity_check;"'
```

Then prune and `VACUUM` the recovered copy and swap it in — `chown 1000:1000`, and delete the stale `kuma.db-wal` / `kuma.db-shm` alongside the old file.

## Local AI

**The model doesn't appear in the picker.** Either the weights aren't there or the connection was never seeded. Both are idempotent, so just re-run them:

```bash
sh scripts/llama-cpp-pre-start.sh     # re-checks and re-downloads the weights
sh scripts/open-webui-bootstrap.sh    # re-seeds the connection, tools and suggestions
```

On a **fresh install** the steps that write the model's workspace row are skipped until an admin account exists — so run the bootstrap once after your first SSO login. See [Local AI](AI.md#how-open-webui-is-wired).

**Replies take minutes.** Something re-enabled the built-in tools or thinking. Both cost thousands of prompt tokens per message at ~40 tok/s — see [Why the defaults look aggressive](AI.md#why-the-defaults-look-aggressive).

**The assistant answers about the server without calling the tool.** Check the phrasing: singular and negated questions reliably fail to trigger a tool call where the plural, positive form works. See [Topic selection is testable](AI.md#topic-selection-is-testable-so-test-it).
