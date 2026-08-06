# Homepage widget secrets (auto-provisioned only)

Each file here is a single-line secret read by the Homepage container (via
`{{HOMEPAGE_FILE_x}}` in `compose.yaml`) to authenticate a service widget on
the dashboard. This whole directory is gitignored - nothing here is committed.

| File                | Service   | How it gets there |
|---------------------|-----------|--------------------|
| `prowlarr_api_key`  | Prowlarr  | `scripts/homepage-widgets-bootstrap.sh` reads it from Prowlarr's own `config.xml` |
| `headscale_api_key` | Headscale | same script, creates a dedicated `headscale apikeys create` token |
| `headscale_node_id` | Headscale | same script, looks up the `tailscale` client's node ID |

All three regenerate on every stack boot (idempotent - only rewritten if the
value actually changed, only restarts Homepage when it does). No manual setup
needed for these.

For widgets that need a key you generate yourself in another app's UI
(Immich, Kavita), see `config/homepage/homepage.env.example` instead - those
don't have a way to auto-create a key, so they use a plain `.env`-style file
you edit directly.
