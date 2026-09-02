# Architecture

One Raspberry Pi, one Docker Compose file, one systemd unit. Traefik is the only way in from the internet; everything else is reachable only from the LAN, the tailnet, or another container.

## The shape of it

```mermaid
flowchart LR
  Internet((Internet))
  Cloudflare[Cloudflare DNS]
  LAN[Home LAN clients]
  VPN[VPN clients]

  subgraph Pi["Raspberry Pi — Docker Compose"]
    DDNS[ddns-updater]
    Traefik[traefik]
    Tailscale[tailscale]
    Headscale[headscale]

    subgraph Apps["Routed services"]
      A1["nextcloud · immich · vaultwarden\nn8n · ntfy · kavita"]
      A2["qbittorrent · prowlarr · kapowarr\nstremio (via gluetun)"]
      A3["open-webui · beszel · uptime-kuma\nhomepage · dockhand · backrest"]
      Authelia[authelia]
    end

    subgraph Internal["Not routed"]
      Postgres[(postgres)]
      Redis[(redis)]
      LLDAP[(lldap)]
      PiholeDNS[(pihole + unbound)]
      AI["llama-cpp · piper\nparakeet · system-tools"]
    end
  end

  Internet -->|HTTPS 443| Traefik
  Cloudflare <-->|record updates| DDNS
  Traefik --> A1 & A2 & A3
  Traefik -->|forward-auth| Authelia
  A1 & A3 -->|OIDC| Authelia
  Authelia --> LLDAP & Postgres & Redis
  A1 & A3 --> Postgres & Redis
  A3 --> AI
  LAN -->|DNS 53| PiholeDNS
  VPN <-->|WireGuard| Tailscale
  Tailscale <--> Headscale
```

Every routed service follows the same path: TLS at Traefik, then the `lan` IP allowlist, then either forward-auth to Authelia or the service's own OIDC login. The rules per service are in [Security](SECURITY.md#per-service-protection).

## What each service is for

| Service | Purpose | Reached by |
|---------|---------|------------|
| **Traefik** | Reverse proxy, TLS termination, middleware chains | the internet, on 443 |
| **ddns-updater** | Keeps the Cloudflare records pointed at your public IP | Cloudflare API |
| **Authelia** | SSO portal, OIDC provider, forward-auth backend | all users |
| **LLDAP** | The user and group directory — one source of truth | Authelia, Nextcloud, Dockhand |
| **PostgreSQL** | Database for Nextcloud, Immich, Authelia, LLDAP, Vaultwarden, Open WebUI | app containers |
| **Redis (Valkey)** | Session store and cache | app containers |
| **Pi-hole** | Ad blocking, local DNS for `*.<HOST_NAME>` | LAN and VPN clients |
| **Unbound** | Recursive resolver — walks the delegation tree itself | Pi-hole only |
| **Headscale** | Self-hosted Tailscale control plane | VPN clients, from anywhere |
| **Headplane** | Web UI for Headscale | admins, LAN-only + 2FA |
| **Tailscale** | The Pi's own VPN node; advertises the LAN and an exit node | your devices |
| **Nextcloud** | Files, sharing, collaboration | users |
| **Immich** | Photo and video library with ML tagging | users |
| **Vaultwarden** | Bitwarden-compatible password manager | Bitwarden clients |
| **n8n** | Workflow automation | users |
| **ntfy** | Push notifications | the other services |
| **Kavita** | Comics, manga and ebook reader | users, and OPDS clients |
| **Gluetun** | VPN gateway; owns the network namespace for qBittorrent, Kapowarr and Stremio | those three |
| **qBittorrent** | Torrent client, all traffic through Gluetun | users |
| **Prowlarr** | Indexer manager, with FlareSolverr for protected indexers | users |
| **Kapowarr** | Comics and manga manager; feeds the Kavita libraries | users |
| **Shelfmark** | Book and audiobook search; files what it downloads into the Kavita Books library | users |
| **Audiobookshelf** | Audiobook player for `download/audiobooks/`, with Audible metadata matching and progress sync | users |
| **Stremio + Comet** | Streaming server and its debrid addon | users |
| **Open WebUI** | Local AI chat frontend — see [Local AI](AI.md) | users |
| **llama.cpp / Piper / Parakeet / system-tools** | Inference, TTS, STT and the host-status tool | Open WebUI |
| **Homepage** | Dashboard with live widgets | users |
| **Beszel** | Hardware metrics and threshold alerts | admins |
| **Uptime Kuma** | Service and route monitoring | admins |
| **Dockhand** | Container management UI | admins, 2FA |
| **Backrest** | Nightly restic backups | S3 |

## Network isolation

Containers only share a network when they have to talk:

```mermaid
flowchart TB
    subgraph frontend["frontend — 172.30.11.0/24"]
        Traefik["traefik (.250)"]
        Services["every routed service"]
        Gluetun["gluetun + qbittorrent,\nkapowarr, stremio\n(shared namespace)"]
    end
    subgraph auth["auth — internal"]
        AutheliaB[authelia] --- LLDAP[lldap]
        AutheliaB --- PG_Auth[(postgres)]
        AutheliaB --- Redis_Auth[(redis)]
    end
    subgraph app["nextcloud · immich · ai · vault · ntfy — internal"]
        App["each app + only its own backends"]
    end
    subgraph dns["dns_internal — 172.30.53.0/24, no gateway"]
        PH[pihole] --> UB[unbound]
    end
    subgraph lan_net["lan — macvlan on the physical LAN"]
        PH_LAN["pihole's own LAN IP"]
    end

    Traefik --> Services
    Traefik -->|forward-auth| AutheliaB
    Services --> App
```

The effect: a compromised app container cannot query Unbound directly, cannot reach LLDAP, and cannot see another app's database traffic. The full table of networks, subnets and members is in [Networking](NETWORKING.md#network-isolation).

## Where the data is

```
pi-pcloud/
├── .env                # your configuration and secrets
├── compose.yaml        # every service, network and volume
├── Makefile            # the commands
├── scripts/            # pre-start, bootstrap and OIDC-wiring hooks
├── config/             # per-service configuration templates
└── docs/
```

Traefik is the exception to `config/` — it has no config directory, being driven entirely by CLI flags and Docker labels in `compose.yaml`.

Persistent state is split deliberately:

| Where | What | Why |
|-------|------|-----|
| `${DATA_LOCATION}` (default `./data`) | `nextcloud`, `immich`, `postgres18`, `authelia-config`, `lldap`, `vaultwarden`, `uptime-kuma`, `backrest`, `download`, `comics`, `manga`, `n8n`, `open-webui`, … | Anything you would miss. **Point this at your SSD.** Backrest mounts most of it read-only |
| Named Docker volumes | Pi-hole, Redis, Headscale, Beszel, ntfy, Kavita config, llama.cpp weights, … | Smaller state, and the model weights that belong on the fast root filesystem rather than in backups |

### The reading libraries

Two readers, split by medium: Kavita for anything paged, Audiobookshelf for anything
listened to. Kavita has no audiobook library type at all, and Audiobookshelf reads only
audio — so neither is a subset of the other and both point at their own folders.

Kavita gets one library per kind of content, because the library *type* decides how it
parses filenames and how it reads: right-to-left for manga, a comic parser for issues,
a text reader for epub/pdf. Each library therefore needs its own folder.

| Kavita library | Type | Reads | Filled by |
|----------------|------|-------|-----------|
| Comics | ComicVine | `comics/` | Kapowarr (root folder) |
| Manga | Manga | `manga/` + `download/manga/` | Kapowarr (second root folder) and the `manga` qBittorrent category |
| Books | Book | `download/books/` | the `books` qBittorrent category, and Shelfmark's imports |

Everything else under `download/` stays invisible to Kavita, which matters because
Kavita indexes *every* subfolder of a folder it is given — point it at the download
root and a software torrent's installer tree becomes series named after its internals
(`AdpSdk`, `IPMClient`, `Template`, ...).

| Path | Written by | Read by Kavita |
|------|-----------|----------------|
| `download/manga/`, `download/books/` | the matching qBittorrent category | yes |
| `download/audiobooks/` | the `audiobooks` qBittorrent category, and Shelfmark (`DESTINATION_AUDIOBOOK`); read by **Audiobookshelf**, not Kavita | no |
| `download/shelfmark/` | qBittorrent's `shelfmark` and `shelfmark-audiobooks` categories, where Shelfmark's own grabs land before import | no |
| `download/prowlarr/` | qBittorrent's `prowlarr` category (Prowlarr's default) | no |
| `download/incomplete/` | qBittorrent's temp path | no |
| `download/` (root) | torrents added by hand with no category — nothing indexes it | no |

### qBittorrent categories

The category is the whole routing decision: its save path is the destination, so it is
also what to pick when adding a torrent by hand. `scripts/qbittorrent-bootstrap.sh` owns
the list, `scripts/prowlarr-bootstrap.sh` the newznab ids Prowlarr maps onto it.

| Category | Save path | Destination | Prowlarr ids |
|----------|-----------|-------------|--------------|
| `books` | `download/books/` | Kavita, **Books** | 7010, 7020, 7040, 7050, 7060 |
| `manga` | `download/manga/` | Kavita, **Manga** | 7030 |
| `audiobooks` | `download/audiobooks/` | **Audiobookshelf** | 3030 |
| `shelfmark` | `download/shelfmark/` | staging — Shelfmark imports it | — |
| `shelfmark-audiobooks` | `download/shelfmark/` | staging, same folder; a label so the list distinguishes the two | — |
| `prowlarr` | `download/prowlarr/` | nothing; Prowlarr's fallback for unmapped ids | — |

Two asymmetries are deliberate. **Comics has no category**: Kapowarr owns `comics/` and
moves files inside it with copy-then-delete, which races a torrent seeding from that
tree. And the **staging categories are not destinations** — Shelfmark post-processes only
torrents belonging to one of its own tasks, so a torrent added there by hand downloads
and then sits forever. Shelfmark itself routes by the task's content type, not by
category, which is why the two staging categories can share one folder.

Prowlarr routes the split automatically: its qBittorrent download client carries a
category map, and Prowlarr resolves the client category as
`GetCategoryForRelease(release) ?? Settings.Category`. **newznab has no manga
category** — manga ships as 7030 `Books/Comics`, the same id as comics — so 7030 goes
to `manga` and the remaining Books subcategories (7010 Mags, 7020 EBook, 7040
Technical, 7050 Other, 7060 Foreign) go to `books`. Audiobooks are 3030
`Audio/Audiobook`, a sibling of the music ids under 3000 rather than a Books
subcategory, so they are mapped on their own and 3010 MP3 and 3040 Lossless keep
falling through to the default. Comics do not come through Prowlarr at all: Kapowarr
fetches them and imports into its own root folder.

Seven places must agree on these paths, and all seven are provisioned: the `kavita`
volumes in `compose.yaml`, `DESIRED_LIBRARIES` in
`scripts/kavita-library-bootstrap.sh`, `LIBRARY_CATEGORIES` in
`scripts/qbittorrent-bootstrap.sh`, `QB_CATEGORY_MAP` in
`scripts/prowlarr-bootstrap.sh`, `ROOT_FOLDERS` in
`scripts/kapowarr-bootstrap.sh`, `INGEST_DIR` and `DESTINATION_AUDIOBOOK` on the
`shelfmark` service, and `LIBRARY_PATH` in `scripts/audiobookshelf-bootstrap.sh`.

Shelfmark is the manual half of that: you search, it fetches. Torrents go out through
the same qBittorrent instance (so through the VPN) under its own `shelfmark` category,
and Shelfmark then renames the finished file into `download/books/`, where Kavita
already looks — which is why its grabs are saved outside that folder in the first
place, so Kavita indexes the imported book and not the torrent's directory tree.
Shelfmark itself sits on `frontend`, not in gluetun's namespace: putting it behind the
VPN would add it to the set of routers that disappear when gluetun goes unhealthy. Its
direct downloads still egress through the tunnel, via gluetun's internal HTTP proxy
(`HTTPPROXY=on`, `gluetun:8888`) rather than by sharing its network namespace.

The dependency is soft, and stays soft: Shelfmark is **not** in gluetun's profile list,
so enabling it does not force a VPN container on an install that only wants
Prowlarr-backed search. `scripts/shelfmark-settings-bootstrap.sh` asks
`docker compose config --services` whether gluetun is part of the current selection —
not whether it is running, so a gluetun that is merely down does not flip the setting —
and configures the proxy only then. When it is not selected the script unwinds its own
proxy setting and says so in the start log; a proxy set by hand is left alone.

That split is deliberate, and it is narrower than it looks. `PROXY_MODE`/`HTTP_PROXY`
are set in Shelfmark's `plugins/network.json`, **not** in its environment, because
`HTTP_PROXY` and `NO_PROXY` are the names `requests` reads out of the environment on its
own — setting them there would route every other outbound call through the tunnel too.
In the config file they reach only the callers of `download/network.py get_proxies()`,
which is the release-source and download path. So Anna's Archive traffic is on the VPN,
while the Prowlarr API, the OIDC token exchange and the metadata providers stay direct —
and a gluetun outage costs you direct downloads, not search or login.

The proxy is addressed as `gluetun.docker`, an alias compose.yaml adds for exactly this:
the bundled bypasser hands the string to SeleniumBase, whose proxy validation rejects a
host with no dot in it and then fails to start the browser at all.

Audiobookshelf closes the other end of that chain. `download/audiobooks/` had a writer
and no reader: Shelfmark files audiobooks there, Kavita cannot open them, and Nextcloud
only stores them. Audiobookshelf mounts the same folder read-only as `/audiobooks` and
adds the listening half — progress sync across devices, and Audible metadata matching,
which is the only source in the stack carrying narrator, runtime and chapters. The
Audible storefront is regional and a French catalogue is invisible from `audible.com`,
so `scripts/audiobookshelf-bootstrap.sh` picks the provider from `DEFAULT_LANGUAGE`.

None of its configuration can come from the environment or a config file — server
settings live only in its SQLite database — so that bootstrap drives the admin API
instead, and has to create the root account first to have anything to authenticate
with. Three consequences worth knowing.

The root account *is* the SSO account: the bootstrap gives it `EMAIL` and sets
`authOpenIDMatchExistingBy: email`, so signing in through Authelia lands on the admin
rather than on a second, plain-user account.

Local login is then switched off (`authActiveAuthMethods: ["openid"]`), so the shared
`PASSWORD` is not a second door into a service that holds everyone's listening history —
the same stance as Shelfmark, Dockhand and Beszel. It is gated on the bootstrap first minting itself an
API key and storing it at `${DATA_LOCATION}/audiobookshelf/config/pi-web-api-key`,
because disabling `local` is otherwise a one-way door — `/login` is wired to passport's
local strategy, and turning the method off *unuses* that strategy, so the route stops
answering entirely (500, not 401) and the only remaining door is the API. The key is
what keeps that door open for `audiobookshelf-bootstrap.sh`,
`homepage-widgets-bootstrap.sh` and `rotate-password.sh` alike; it lives inside the
`/config` directory Backrest snapshots so a restore brings it back. Every client can do
OIDC, which is why this is safe here and would not be for Kavita's OPDS readers: the
mobile apps get their own registered redirect URI (`/auth/openid/mobile-redirect`),
which Audiobookshelf bounces to `audiobookshelf://oauth` itself.

And the client asks for no `groups` scope: Audiobookshelf reads the group claim as a
*role* and denies any login whose groups contain none of `admin`/`user`/`guest`, so
requesting it would lock out every regular user in a stack where only `admin` exists.

Podcasts are deliberately not offered. Audiobookshelf can serve them, but it
downloads episodes *into* the library folder, and **its own** mount of that
folder is `:ro` — a podcast library would fail with `EROFS` on its first fetch.
(Nextcloud's separate mount of the same path is read-write, for organising it;
that does not help a process writing through a different, read-only one.) It
would need a writable mount of its own, which nothing in the download chain
feeds.

Kapowarr's `volume_folder_naming` is deliberately flat (`{series_name} ({year})`, no
volume subfolder): Kavita's ComicVine parser takes the series name from the folder and
`GetFoldersTillRoot` stops below the scan root, so any intermediate folder makes every
series come out named `Volume 01`.

The same libraries are also mounted into Nextcloud as `files_external` mounts
(`Comics`, `Manga`, `Books` and `Audiobooks`, alongside the existing `Downloads`),
so any file can get a public share link the way Immich does for photos — and so
Nextcloud is where the tree gets **organised**: renamed, moved between libraries,
deleted. Audiobooks are in both places on purpose: Nextcloud shares the file,
Audiobookshelf plays it and keeps your position. The mounts are created by
`config/nextcloud/hooks/post-installation/20-external-storage.sh`, which is
idempotent and can be re-run by hand on an existing install — worth knowing,
because it is a *post-installation* hook and so does not fire again on an
existing Nextcloud when a mount is added to its list.

Write access took two pieces, and only one of them is obvious. The bind mounts
are read-write, but Nextcloud's PHP runs as uid 33 while the tree belongs to
uid/gid 1000 in mode 0755, so it would still only get `r-x`.
`scripts/nextcloud-pre-start.sh` grants uid 33 write access with a POSIX ACL.

Two traps are worth recording, because both look like the right answer:

- **`group_add: "1000"` does not work.** Apache calls `initgroups()` when it
  drops to `www-data`, which rebuilds the group list from the container's
  `/etc/group` and discards the supplementary gid compose added. The group *does*
  survive in a `docker exec`, so the mistake passes a hand test and then fails
  every real request.
- **`chmod -R g+w` does not last.** qBittorrent, Kapowarr and Shelfmark all run
  with umask 022, so every directory they create afterwards comes back `0755`
  and Nextcloud silently loses access to exactly the new downloads it is most
  likely to be asked to tidy up. A *default* ACL is inherited by whatever is
  created later, umask notwithstanding.

The trade-off is real and deliberate: `Downloads` is writable too, and
qBittorrent seeds from there, so deleting a file in Nextcloud can break the
torrent still serving it. Kapowarr's moves are copy-then-delete, so avoid
reorganising `Comics`/`Manga` while it has a task running.

**Recommended layout:** clone onto the SSD and symlink it into place, so systemd and the docs agree on one path.

```bash
git clone https://github.com/florianajir/pi-pcloud.git /mnt/ssd/pi-pcloud
ln -s /mnt/ssd/pi-pcloud /opt/pi-pcloud
```

## Backups

Two independent layers: Backrest takes the nightly full backup of application data plus database dumps, and Beszel snapshots its own metrics database. Schedules, retention and how failures are noticed: [Monitoring → Backup strategy](MONITORING.md#backup-strategy).

## Deliberate limits

This is a **single-instance design**: one Pi, no clustering, no replication, no failover. Resilience comes from backups, not redundancy — a dead Pi is restored onto a new one from the S3 repository, not failed over to. If uptime matters more than simplicity for you, this is the trade-off to know about up front.
