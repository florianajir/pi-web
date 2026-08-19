# Tailscale & Headscale VPN Setup

This stack includes Headscale, a self-hosted Tailscale control plane. It creates a private WireGuard mesh for secure remote access to your services — official Tailscale clients on every platform, but coordination stays on your Pi instead of Tailscale's cloud.

Logins are federated to Authelia: Headscale is registered as an OIDC client, so joining the VPN means signing in with your LLDAP account.

## Architecture

- **headscale** — control plane, reachable at `https://headscale.<HOST_NAME>` (this router is public: clients must reach it from anywhere). Runs an embedded DERP relay (STUN on `3478/udp`).
- **headplane** — admin web UI at `https://headscale.<HOST_NAME>/admin` (admin group + 2FA, LAN-only).
- **tailscale** — the Pi's own node, on the host network (WireGuard on `41641/udp`). It is started with `--advertise-exit-node --advertise-routes=${HOST_LAN_SUBNET} --ssh`, so exit-node use, LAN access and Tailscale SSH need nothing extra on the Pi — they only need approval/enabling per client.
- `scripts/headscale-init.sh` runs on stack start: it creates the Headscale user, registers the Pi with a short-lived preauth key, and provisions Headplane's API key.

## Connecting a Device

1. Install the official Tailscale client ([tailscale.com/download](https://tailscale.com/download); on Linux: `curl -fsSL https://tailscale.com/install.sh | sh`).

2. Point it at your Headscale:

   ```bash
   tailscale up --login-server https://headscale.<HOST_NAME>
   ```

3. Open the URL the command prints. It leads to Authelia — sign in with your LLDAP account and the device is registered. On mobile, set the login server under the Tailscale app's account/server settings and log in the same way.

If the browser flow isn't practical, register the node key manually on the Pi instead:

```bash
make headscale-register <key-from-the-url>
```

### Preauth Keys (headless devices)

For devices that can't open a browser:

```bash
docker compose exec headscale headscale preauthkeys create --user <user-id> --reusable
tailscale up --login-server https://headscale.<HOST_NAME> --authkey <key>
```

Revoke reusable keys if they leak — they allow registration without any interactive login.

## DNS on the VPN

Headscale pushes DNS to every client (`config/headscale/config.yaml`):

- All queries go to `100.64.0.1` — the Pi's tailnet IP — through the tunnel, so Pi-hole filtering applies everywhere you take the device.
- `*.<HOST_NAME>` resolves to the Pi (split DNS + Pi-hole's wildcard record), so `https://nextcloud.<HOST_NAME>` etc. work from the VPN with valid TLS. See [Networking](NETWORKING.md#dns-from-the-vpn).
- MagicDNS names live under `tailnet.<HOST_NAME>`.

A client must accept DNS for this to work (`tailscale up --accept-dns=true`, or "Use Tailscale DNS" in the app — the default).

## Using the Pi as Exit Node / LAN Gateway

The Pi already advertises both. Approve the routes once (Headplane → the Pi's node → routes), then per client:

```bash
tailscale set --exit-node <pi-tailnet-ip>   # route ALL traffic through home
tailscale set --accept-routes=true          # or just reach the home LAN subnet
```

## Managing Users & Devices

Headplane (`https://headscale.<HOST_NAME>/admin`) covers day-to-day: viewing nodes, expiring keys, approving routes, editing ACLs. The CLI equivalent:

```bash
docker compose exec headscale headscale users list
docker compose exec headscale headscale nodes list
docker compose exec headscale headscale nodes delete --identifier <node_id>
make headscale-reset       # wipe ALL nodes, preauth keys and IP allocations (destructive)
```

ACLs use Headscale's HuJSON policy format, loaded from `config/headscale/policy.hujson` (`policy.mode: file`). The default policy is permissive; edit the file (or use Headplane's ACL editor) and restart Headscale to restrict traffic between devices. See the [Headscale docs](https://headscale.net/) for the policy syntax.

## Troubleshooting

**Device won't register** — check `docker compose logs headscale | tail -30`. The login server must be `https://headscale.<HOST_NAME>` (port 443, valid TLS). A device that was registered before must be deleted before re-registering.

**Can't reach services from the VPN** — verify the client got a `100.64.x.x` address (`tailscale ip`) and that DNS is accepted (`tailscale dns status`). Test resolution: `nslookup nextcloud.<HOST_NAME>` should return the Pi's LAN IP.

**Connections relay instead of going direct** — forward `41641/udp` (WireGuard) and `3478/udp` (STUN) on your router. Without them, traffic still works but rides the embedded DERP relay.

**Node shows offline but the device is connected** — "last seen" lags by design; check `tailscale status` on the device itself before trusting the list.

**Uptime Kuma** monitors headscale, headplane, the tailscale container and the actual VPN egress — see [Monitoring](MONITORING.md#monitor-groups).
