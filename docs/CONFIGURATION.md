# Configuration

All configuration is managed through the `.env` file. Copy `.env.dist` and edit with your values.

> Do not use `$`, `\` or ` #` (whitespace + hash) in any value, and do not quote values: Docker Compose interpolates `$VAR` inside `.env` values (so `Sup3r$ecret!` reaches the services as `Sup3r!` with only a warning in the logs), truncates unquoted values at inline comments, and strips surrounding quotes — while the bootstrap scripts read `.env` verbatim, so quoting makes the two sides disagree instead of helping. `make check-env` refuses such values in the required variables.

## Environment Variables

### Personal Settings

| Variable | Description | Required | Default | Example |
|----------|-------------|----------|---------|---------|
| `HOST_NAME` | Your domain name | ✓ | — | `pi.example.com` |
| `TIMEZONE` | Server timezone | ✓ | — | `Europe/Paris` |
| `ADMIN_USER` | Stack-wide admin username | ✓ | — | `admin` |
| `PASSWORD` | LLDAP admin & Authelia password | ✓ | — | `MySecurePassword123!` |
| `EMAIL` | Admin email & sender address | ✓ | — | `admin@example.com` |
| `DEFAULT_LANGUAGE` | Stack-wide language (BCP 47) for Open WebUI, Piper voice, suggestion tiles | — | `en-US` | `fr-FR` |
| `DATA_LOCATION` | Path for persistent data | — | `./data` | `/mnt/ssd/pi-pcloud-data` |

### Network Configuration

| Variable | Description | Default | Notes |
|----------|-------------|---------|-------|
| `HOST_LAN_IP` | Pi's static IP on home LAN | — (**required**) | Local DNS records point here |
| `HOST_LAN_PARENT` | Network interface name | `eth0` | Use `ip link` to find |
| `HOST_LAN_SUBNET` | Home network CIDR | `192.168.1.0/24` | Match your router's subnet |
| `HOST_LAN_GATEWAY` | Router IP | `192.168.1.1` | Usually `.1` in your subnet |
| `PIHOLE_IP` | Static IP for Pi-hole | `192.168.1.250` | Must be in subnet, outside DHCP range |
| `PIHOLE_DNS_UPSTREAMS` | Pi-hole upstream resolvers | `172.30.53.53#5335;1.1.1.1;9.9.9.9` | Unbound first; public resolvers are failover only |
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
| `NEXTCLOUD_SQL_BACKUP_KEEP` | Nextcloud SQL dumps to retain | `30` | Separate from full backups |

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
| `MAIL_FROM_ADDRESS` | Nextcloud sender local part | `nextcloud` | Sender domain is always `HOST_NAME` |

**Services auto-configured:**
- Authelia, Nextcloud, LLDAP, n8n, Ntfy, Beszel, Vaultwarden (read from `.env` and generated startup config)

**Services needing manual setup:**
- Uptime Kuma, Immich, Kavita (configure via their UIs) — see [Email & Notifications](EMAIL.md#who-sends-what)

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
~10 tok/s generation, ~40 tok/s prompt processing, ~3.7GB resident. A short
question answers in about 3 seconds end to end.

**Latency comes from prompt size, not the model.** Three defaults exist purely
because ~30 tok/s of prompt processing punishes anything verbose:

- *Thinking is off* (`LLAMA_ARG_CHAT_TEMPLATE_KWARGS`). Gemma 4 otherwise spends
  ~500 tokens reasoning before the first visible word - over a minute of empty
  chat window for "how are you".
- *One server slot* (`LLAMA_ARG_N_PARALLEL=1`). llama-server defaults to several
  and runs them concurrently, so two requests each generated at ~5 tok/s instead
  of one at ~10. Queueing is faster than sharing three threads.
- *Open WebUI's built-in tools are off for this model*, along with title, tag,
  follow-up and search-query generation. Built-in tools (time, memory, chats,
  notes, knowledge, channels) inject ~5000 tokens of schemas into every message
  sent from the browser - roughly three minutes of prompt processing before the
  model starts. The other four are invisible extra LLM calls per message.
  All are re-enablable in Admin Settings and in the model's own Capabilities.

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
open-webui only when it changed something. It also seeds the low-latency
defaults above - once, guarded by a `pi-pcloud.local_ai_defaults` marker row, so
anything you change afterwards in Admin Settings stays changed. The same script
registers the `system-tools` server below (marker `pi-pcloud.system_tools`) and
seeds the new-chat suggestions (marker `pi-pcloud.prompt_suggestions`); the
markers are independent, so re-seeding one never re-imposes the others.

Everything that writes the model's *workspace row* - turning the built-in tools
off (marker `pi-pcloud.local_ai_model_defaults`), attaching the tool server,
seeding the suggestions - needs an admin account to own that row, and there is
none until the first SSO login. Those steps are therefore skipped, unmarked, on a
fresh install, and applied by the next run of the hook; the settings that live in
the `config` table alone (connection, low-latency defaults, audio) apply from
the first boot. Run it by hand after the first login, or after a database
restore:

```bash
sh scripts/open-webui-bootstrap.sh
```

**Who may use it.** Authelia already decides who reaches
`ai.${HOST_NAME:-pi.lan}`, so Open WebUI's own `pending` role - which parks every
SSO login behind an admin approval screen - would only mean nobody can use the
service until an admin notices. The script sets `ui.default_user_role` to `user`
and releases accounts already parked (marker `pi-pcloud.open_access`).

That alone is not enough to make the assistant usable, because two separate
things default to admin-only:

- A model with a workspace row is kept by `get_filtered_models` only for its
  owner or for someone named in an access grant. The row exists here to turn the
  builtin tools off and it belongs to the admin, so every other account got an
  **empty model picker**.
- A tool server whose `config` carries no `access_grants` is private to admins
  (`has_connection_access`), so a normal user clicking one of the suggestions
  below would get an invented answer with no tool call.

Both are granted wildcard public read - `('user', '*', 'read')`, the shape the
code itself documents as public - by the same marker. They stay visible and
revocable in **Admin Settings** and **Workspace → Models**; narrowing either one
by hand is never undone. Admin rights still have to be granted deliberately.

**Answering questions about this server.** `system-tools` (built from
`config/system-tools/`) is an OpenAPI tool server on the `ai` network. Open WebUI
discovers tools from an OpenAPI spec and hands them to the model as function
definitions, so the model can measure the machine it runs on instead of guessing
at it - "how much disk is left?", "is anything down?", "how long has it been
up?". It is attached to `gemma-4-e2b-it` in the workspace, so it is live on every
chat; untick it under the model in **Workspace → Models** to turn it off.

One operation, `get_system_status(topic)`, with `topic` one of:

| Topic | Answers with |
|-------|--------------|
| `overview` | One line each of uptime, CPU, RAM, `/`, containers |
| `anomalies` | Only the readings outside their threshold - or that none are |
| `disk` | Free space on `/`, `/mnt/usbdrive` and `/mnt/sdcard` |
| `cpu` | Usage overall and per core, load average, temperature, clock |
| `memory` | RAM and swap |
| `uptime` | Uptime, boot time, host clock |
| `services` | Container count, and which ones are not running or not healthy |
| `restarts` | What restarted, how often, and with which exit code |
| `errors` | The last few log lines of whatever is currently failing |
| `backups` | Last backup per plan, whether it worked, when the next one runs |
| `devices` | Tailnet devices, their owner, which are online, when the rest were last seen |

**Reporting versus judging.** Every topic but one hands the model a measurement
and leaves the conclusion to it - and "184.5G free of 468.9G" is a conclusion a
4B model gets wrong often enough to matter, mid-sentence, against a threshold it
has to invent. `anomalies` moves that decision into code: it walks disk, memory,
swap, temperature, 5-minute load, container health, restart counts and backup age,
and returns *only* what is off. When nothing is, it says so in one line, naming
what it checked - so the model states it rather than hedging.

The thresholds are at the top of `app.py`. `DISK_PCT`, `MEMORY_PCT` and `TEMP_C`
are deliberately Beszel's own alert values (85% / 90% / 70°C, see
`scripts/beszel-agent-bootstrap.sh`), so anything this topic calls abnormal is
something that has already pushed to ntfy - two voices on one number, rather than
a chat that disagrees with your phone. `RESTART_LOOP` is 3, which only ever counts
restarts *within* one run of the stack, because `docker compose up` zeroes the
counter.

**Swap needs two conditions, and that is the interesting one.** It was written
first as a plain `SWAP_PCT = 50` and fired on its first run against a box where
nothing was wrong: 103 days of uptime, swap 100% full, **7G of RAM available, no
OOM kill on record, and 0.13 MB/min of actual paging**. The 2G is
`/var/swap` on the NVMe, and what filled it was `parakeet` (578M), `llama-cpp`
(351M) and `immich-machine-learning` (158M) - services that load a model, go idle,
and have their cold pages evicted exactly once. That is what swap is *for*, and
the fill level cannot tell it apart from a machine fighting for RAM.

So the finding now needs `SWAP_PCT` **and** `RAM_PRESSURE_PCT` (80%) together.
`RAM_PRESSURE_PCT` sits below `MEMORY_PCT` on purpose: paging under pressure
starts before RAM is exhausted, so the swap finding can fire one step ahead of the
memory one. The `memory` topic still reports swap unconditionally for anyone who
wants the raw number. The general lesson for any threshold added here: a level is
a state, and only some states are faults.

Nothing new is measured for it - it reuses the collectors the other topics already
call, so the whole pass is one `statvfs` per filesystem, two `/proc` reads, one
inspect per container and one SQLite query: **60-80 ms** end to end, against the
~300 ms `cpu` alone spends sleeping between its two `/proc/stat` samples. That
sample is the one thing `anomalies` skips: the 5-minute load average already says
whether the machine is saturated, sustained, which is the only version worth
reporting.

The same verdict is reachable from a shell with **`make doctor`**, which asks this
container for the `anomalies` topic and prints it - the same endpoint, so the
terminal and the chat cannot disagree.

**Why one operation and not ten.** Tool schemas are injected into the prompt of
every message. At ~40 tok/s of prompt processing they are the latency budget, and
that is exactly why the built-in tools are off above - they cost ~5000 tokens,
about three minutes before the model writes a word. This one is 170 tokens
(`curl llama-cpp:8080/tokenize` on the payload Open WebUI builds from the spec),
which llama-server then caches for the rest of the conversation.

That shape is what keeps growth cheap, and the difference is measured: the enum has
gone 6 → 10 topics for 113 → 170 tokens - about **+14 per topic**, depending on
how much the topic's own description has to explain,
where a single extra *operation* costs **+72** on its own. So a new capability
becomes a topic, never a second operation. `anomalies` came in at **+19**,
tokenizing the same payload with and without it - above that average, because its
clause has to say what a threshold *is* and not merely name a subject.

The replies are digested for the same reason, and it matters more than the schema
does: a reply is re-processed on every later turn of the conversation. `df -h`
alone is ~400 tokens of column padding, so nothing here returns raw command
output, and `errors` caps itself at three containers and three lines each.

**Topic selection is testable, so test it.** The real ceiling is not tokens, it is
whether a 4B model still picks the right topic as the list grows. One prompt per
topic, sent to `llama-server` with the schema attached, currently scores 10/10 at
ten topics - no degradation from six.

`anomalies` was checked the same way and records one boundary. Both tile wordings
("y a-t-il des anomalies...", "are there any anomalies...") select it reliably, and
adding it moved none of the other topics. But a vague *"est-ce que tout va bien ?"*
still routes to `overview` - a defensible answer, since `overview` does report the
container count, though it would miss a full swap. Widening the topic's own
description to "whether anything is wrong right now" was tried and changed that
case not at all, only the token count, so the short clause stayed and the tile
names anomalies outright instead.

What does break is phrasing, in two
reproducible ways: the **singular** ("est-ce qu'*un* conteneur est arrêté ?") makes
the model ask *which* container instead of calling anything, and **negation**
("depuis quand X *n'est-il plus* en ligne ?") makes it answer nothing at all. Both
work stated positively and in the plural. Re-run the check when adding a topic, and
when writing a suggestion.

**What it can reach.** `/` is bind-mounted read-only at `/hostfs`: `/proc` and
`/sys` report the host from inside a container anyway, but `statvfs` can only
measure a filesystem this process can itself see, which is what `disk` needs.

The Docker socket is mounted `:ro`, the same way `homepage` already mounts it -
but be clear about what that buys: `:ro` protects the socket *inode*, not the
Docker API, and anything holding an open socket can still `POST
/containers/create` and get host root. What actually constrains this server is its
own code - it only ever issues `GET`, to two paths, and `services` is the only
caller. There is likewise no endpoint that accepts a command, a path or a pattern:
the model picks a topic from a closed list and each topic maps to fixed code, so a
prompt injection has nothing to steer. The container itself runs `read_only` with
`no-new-privileges`.

`services`, `restarts` and `errors` filter the container list on
`com.docker.compose.project=$COMPOSE_PROJECT` (passed in from
`COMPOSE_PROJECT_NAME`, defaulting to `pi-web`). The socket is the host's, so
without that filter the count also covers containers that have nothing to do with
this stack - and any stray `docker run` left in `Exited` would be reported as
something needing attention.

`errors` reads container logs, which is the one place where "the model picks a
topic, not a target" earns its keep: it only ever reads the tail of containers it
has *already* found stopped or unhealthy. The model cannot name what gets read, so
there is no way to ask it for the logs of something else.

`backups` reads Backrest's own operation log,
`$DATA_LOCATION/backrest/data/oplog.sqlite`, opened `mode=ro`. That directory is
bind-mounted straight in at `/run/backrest` rather than reached through `/hostfs`,
because `DATA_LOCATION` is relative to the project directory by default and a
relative path means nothing against the host root - the directory, not the file,
because the oplog does not exist until Backrest's first run and Docker would
otherwise create a directory in its place.
Backrest's repos live on a remote, so restic would want their password, and the
log answers "did last night run" without one. The same reading is served as JSON
at `/health/backups` - `ok`, `stale`, `failed` or `unknown`, no status a substring
of another - which is what the Uptime Kuma `backup freshness` monitor matches on;
see [Monitoring](MONITORING.md#what-is-actually-checked). It is kept out of the
OpenAPI schema, so it costs no prompt tokens: the model reads the topic instead. Two things to know: the status codes
come from `proto/v1/operations.proto`, where `WARNING` is declared before `ERROR`
but numbered *after* the cancellations (reading declaration order off the binary
gets it backwards - `ERROR` is 4); and a WAL database opened read-only can refuse
the read if the WAL needs replaying, which surfaces as `backup log unreadable`
rather than an error.

`devices` reads headscale's node API - the tailnet is self-hosted, so there is no
Tailscale SaaS call - reusing the API key `homepage`'s headscale widget already
holds, mounted read-only at `/run/secrets/headscale_api_key`. Those keys expire, so
this and the Homepage widget break together. It is also the one topic that needs
the `frontend` network, since headscale listens there; the container makes egress
GETs to a fixed URL and accepts no URL of its own, so what widens is the reachable
surface, not the steerable one.

Note what `devices` does *not* have: a parameter naming a device. Ten devices fit
in eleven digested lines, so "when was the iPad last online?" is answered by the
model reading its own tool result - no free-form target, and the closed-enum
property survives. Past `DEVICE_LINES` devices the offline ones are trimmed
oldest-first and the reply says how many it dropped.

There is deliberately no `network` topic. It existed briefly and was dropped: the
default route, the link speed and `wlan0: down` are static configuration, and
traffic *since boot* is a number nothing can be done with - a rate would be needed,
and beszel and the Homepage widget already graph one. The question it could not
answer either way is which *service* is using the bandwidth, which would need
per-container counters.

To give a *different* model the same capability, add `server:pi-system` to its
`toolIds` in **Workspace → Models**; the tool server itself is registered once,
globally. To add a topic, extend `TOPICS` and the `Topic` literal in
`config/system-tools/app.py`; to report another drive, add its mount point to
`FILESYSTEMS` in the same file (one that is not mounted is skipped, so a drive
that comes and goes is safe to list). Either way, `docker compose build
system-tools` afterwards.

**The tiles on the new-chat screen.** Open WebUI ships six suggestions of its own
- vocabulary drills, the Roman Empire, options trading - which advertise a model
this box does not run and never touch the tool, so nobody discovers the assistant
can be asked about the machine. `scripts/open-webui-bootstrap.sh` replaces them
with nine that each map to a topic, in the stack's `DEFAULT_LANGUAGE`: free disk
space, whether anything is abnormal, a general status, CPU temperature and load,
uptime, who is online on the tailnet, last night's backup, recent restarts, and the
errors of whatever is failing.

They are written to `suggestion_prompts` on the model rather than to the global
`ui.prompt_suggestions`, because the frontend reads
`model.info.meta.suggestion_prompts` first and only falls back to the global
list - a suggestion that assumes the status tool exists belongs to the model the
tool is attached to. Edit them in **Workspace → Models → gemma-4-e2b-it**, or in
the `SUGGESTIONS` heredoc in the script; the `pi-pcloud.prompt_suggestions`
marker means a UI edit is never overwritten. The marker carries a version
(`SUGGESTIONS_VERSION`, currently `5-$DEFAULT_LANGUAGE`), so changing the tiles in
the script means bumping it - which re-seeds them once, and does overwrite an edit
made in the UI.

Each wording was checked against `llama-server` with the tool schema attached,
because a prompt that reads well is not necessarily one this 4B model turns into
a call: "est-ce qu'un conteneur est arrêté ou en mauvaise santé ?" makes it ask
*which* container instead of calling anything, where the plural "est-ce que tous
les services tournent correctement ?" calls `services` every time. Worth
re-checking a new suggestion the same way.

**Language.** One `.env` variable, `DEFAULT_LANGUAGE`, sets the language of
everything in the stack that has to choose one, as a BCP 47 tag. It defaults to
`en-US`; this is the only place to change it:

| It drives | How |
|-----------|-----|
| Open WebUI's interface | `DEFAULT_LOCALE`, for users who have not picked a language themselves |
| Which Piper voice reads answers aloud | matched against the voices baked into the image |
| The new-chat suggestion tiles | written in that language by `scripts/open-webui-bootstrap.sh` |

`fr-FR` and `en-US` are the two tags with voices shipped. Anything else still
works - the interface has its own translations, and Piper picks the closest
voice it has (`fr-BE` finds `fr_FR-siwis-medium`; `de-DE` warns in the log and
uses English until you add a German voice to `VOICES` in
`config/piper/Dockerfile`). To name a voice outright instead of matching the
language, set `PIPER_DEFAULT_VOICE` on the service.

Changing it later is one variable and a restart: the seeding markers carry the
language, so `pi-pcloud.local_tts_defaults` moves from `2-en-US` to `2-fr-FR` and
re-seeds once. A voice you then pick in Admin Settings stays picked.

**Text-to-speech.** The read-aloud button goes through `piper`, built
from `config/piper/` on top of [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl).
Upstream publishes no image and its HTTP server speaks its own protocol, so the
image adds `config/piper/openai_api.py`, a small OpenAI-compatible facade
(`/v1/audio/speech`, `/v1/audio/voices`, `/v1/audio/models`) - the shape Open
WebUI's "OpenAI" TTS engine calls. Voices are baked into the image:

| Voice | |
|-------|---|
| `fr_FR-siwis-medium` | French, female - the default |
| `fr_FR-tom-medium` | French, male |
| `fr_FR-upmc-medium` | French, female, different timbre |
| `en_US-lessac-medium` | English, so English text is not read with a French phonemiser |

Roughly five seconds of speech per second of CPU, ~215MB resident. The default
voice is not named on the service - it is matched against `DEFAULT_LANGUAGE`
above, because open-webui asks for OpenAI's own voice names (`alloy`, `echo`),
none of which exist here, so the fallback *is* the voice in practice. Pick a
voice per user in **Settings → Audio**; it overrides the default. To add voices, extend
`VOICES` in `config/piper/Dockerfile` (the catalogue is
[rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices)) and rebuild
with `docker compose build piper`. To go back to the browser's own voices, set
the TTS engine to Web API in Admin Settings - nothing re-imposes Piper.

**Speech-to-text.** The microphone button goes through `parakeet`, built
from `config/parakeet/` on top of NVIDIA's
[Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), run
as ONNX via [onnx-asr](https://github.com/istupakov/onnx-asr). As with Piper,
upstream publishes no image - and onnx-asr has no HTTP server at all - so the
image adds `config/parakeet/openai_api.py`, an OpenAI-compatible facade serving
`POST /v1/audio/transcriptions`, the shape Open WebUI's "OpenAI" STT engine
calls. The weights are baked into the image, so the container needs no network.

It is wired on both paths, and needs nothing done by hand on either. A fresh
install is configured by the `AUDIO_STT_*` variables on the open-webui service:
those are PersistentConfig, read into the database on an instance's very first
start, so `make install` comes up dictating with no second step. An instance
whose database already exists ignores them by design, and there
`scripts/open-webui-bootstrap.sh` writes the same values once (marker
`pi-pcloud.local_stt_defaults`). The image itself is built by the `docker compose
up -d` the systemd unit already runs, so the first boot after a checkout builds
it and starts it like any other service. The setting is global rather than
per-account, and the microphone is on for every role by default
(`chat.stt` in `user.permissions`), so it works for every user the moment they
sign in - no admin approval, no per-user configuration.

Open WebUI ships its own faster-whisper, and that is what this replaces. It runs
*inside* the open-webui container, which is capped at 1g and already sits near
730MB, so the only model that fits is the default `base` - and `base` is the
reason dictated French comes back wrong. Measured on 113 seconds of read French
([FLEURS](https://huggingface.co/datasets/google/fleurs) `fr_fr`) across this
Pi's three AI cores:

| Engine | WER | Speed | Resident |
|--------|-----|-------|----------|
| faster-whisper `base` (Open WebUI's default) | 20.2% | 0.95x realtime | ~630MB |
| faster-whisper `small` | 12.5% | 1.25x realtime | ~1.0GB |
| faster-whisper `medium` | 4.9% | 3.99x realtime | ~2.7GB |
| **Parakeet TDT v3, int8 (in use)** | **8.7%** | **0.17x realtime** | **~1.2GB** |
| Parakeet TDT v3, fp32 | 4.5% | 0.30x realtime | ~2.3GB |

Whisper decodes autoregressively - a token at a time, so accuracy is bought with
wall-clock. Parakeet is a TDT model whose decoder is a small joint network
stepped once per frame, which is why it reaches whisper-`medium` accuracy at a
twentieth of the cost. In practice a dictated sentence comes back in well under
a second, and it punctuates and capitalises.

**It has no language setting at all**, and that is the other half of the fix.
Parakeet was trained on 25 European languages and picks one acoustically, so
dictating in English tomorrow needs no switch flipped - where whisper
*auto-detects*, and its failure mode on a short French clip is to decide the
audio is English and transliterate it. Open WebUI still sends a `language`
field; the facade accepts and ignores it. The measurements here were taken on
French because that is what gets dictated on this box, not because anything
restricts it to French.

For **more accuracy at twice the memory**, rebuild in fp32 - 4.5% WER, still
three times faster than realtime, but ~2.3GB resident and a ~2.5GB model in the
image:

```bash
docker compose build --build-arg PARAKEET_QUANTIZATION= parakeet
```

and set `PARAKEET_QUANTIZATION=` (empty) on the service in `compose.yaml`, so
the weights loaded are the weights baked in. Raise `mem_limit` to `3584m` too.

Long uploads are transcribed in 20-second windows. That is not only about
memory - a single 120-second pass took the container past 2GB and got it killed -
but about a cliff in the ONNX export, which stops transcribing part of a long
call. Against 57 seconds of continuous French with a 163-word reference:

| Window | Words returned | WER |
|--------|----------------|-----|
| 10s | 157 | 20.2% |
| **20s** | **162** | **15.3%** |
| 30s | 160 | 16.6% |
| 60s | 75 | 73.0% |

At 60 seconds half the audio simply goes missing, so the window has to stay well
under it. Boundaries are then nudged onto the quietest nearby frame rather than
falling wherever 20 seconds lands, because a window that opens mid-word is the
one that comes back in the wrong language - on a deliberately badly-cut sample
that alone took the transcript from 33.7% WER to 19.5%. Dictation reaches none of
this: it is one window. Tune with `PARAKEET_CHUNK_SECONDS` if you feed it long
recordings.

To go back to Open WebUI's built-in whisper, set the STT engine to Whisper
(Local) in **Admin Settings → Audio** - nothing re-imposes Parakeet.

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
| `LLAMA_ARG_CHAT_TEMPLATE_KWARGS` | `{"enable_thinking":false}` | Thinking off (see above). Drop the line to restore it — `--reasoning-budget 0` is *not* equivalent: it closes the channel without telling the model, which then reasons in the visible answer. |
| `LLAMA_ARG_N_PARALLEL` | `1` | One server slot; concurrent requests queue instead of splitting the three threads. |
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
