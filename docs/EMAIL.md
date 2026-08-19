# Email & Notifications

The stack sends outbound email for password resets, alerts and sharing notifications. All services share the SMTP credentials configured in `.env`. For push notifications, the primary channel is [ntfy](MONITORING.md#ntfy-topics), not email.

## SMTP Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `SMTP_HOST` | SMTP server | `localhost` |
| `SMTP_PORT` | SMTP port | `587` |
| `SMTP_USERNAME` | Username | *(empty)* |
| `SMTP_PASSWORD` | Password / app password / API token | *(empty)* |
| `EMAIL` | Sender address (also the admin/ACME address) | — |

Per-service overrides, all optional (compose defaults suit port 587 + STARTTLS):

| Variable | Used by | Default |
|----------|---------|---------|
| `SMTP_SECURE` | Nextcloud | `tls` |
| `SMTP_AUTHTYPE` | Nextcloud | `LOGIN` |
| `SMTP_ENCRYPTION` | Authelia, LLDAP | `STARTTLS` |
| `SMTP_SSL` | n8n | `false` |
| `MAIL_FROM_ADDRESS` | Nextcloud sender local part | `nextcloud` |

Nextcloud's sender domain is always `HOST_NAME` (so the address is `${MAIL_FROM_ADDRESS}@${HOST_NAME}`). Vaultwarden pins `SMTP_SECURITY=starttls` in `compose.yaml`; switch it to `force_tls` there if you move to port 465.

**Gmail example** (requires an [app password](https://myaccount.google.com/apppasswords), not your account password):

```env
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USERNAME=your-email@gmail.com
SMTP_PASSWORD=your-app-password
EMAIL=your-email@gmail.com
```

**Disable email:** leave `SMTP_HOST` empty or `localhost`. The stack starts normally (Authelia has `disable_startup_check` enabled); delivery just fails silently.

Apply changes with `make restart`.

## Who Sends What

Auto-configured from `.env` — no manual setup:

| Service | Sends |
|---------|-------|
| **Authelia** | 2FA enrollment, password reset, identity verification |
| **Nextcloud** | Share notifications, activity digests, password resets |
| **LLDAP** | Self-service password reset links |
| **Vaultwarden** | Invitations and the whole emergency-access flow (invite, grant, takeover notice). Emergency access is useless without working SMTP — and since `SSO_ONLY` is on, the trusted contact also needs an LLDAP account (see [Security](SECURITY.md#vaultwarden-account-setup)) |
| **n8n** | Workflow **Send Email** nodes, error notifications (`N8N_SMTP_*`) |
| **ntfy** | Email delivery for topics, when a subscriber requests it |
| **Beszel** | Alert emails (configured via its API by `scripts/beszel-agent-bootstrap.sh`) |

Configured through their own UI (they don't read `.env`):

| Service | Where |
|---------|-------|
| **Uptime Kuma** | Settings → Notifications → SMTP. Optional: its ntfy notifications are already bootstrapped, so email is a second channel, not a requirement |
| **Immich** | Admin → Settings → Notification settings (SMTP). Fill in the same `SMTP_*` values |
| **Kavita** | Settings → Email — usually unnecessary, see [Installation](INSTALLATION.md#email-optional) |
| **Dockhand** | Nothing to do: alerts go to ntfy via `scripts/dockhand-oidc-bootstrap.sh`. Manual SMTP exists in its UI but isn't the stack default |

## Testing

- **Authelia:** `https://auth.<HOST_NAME>` → Settings → add/verify an email or reset a password
- **Nextcloud:** Administration → Basic settings → Send test email
- **Beszel / Uptime Kuma:** trigger or test a notification from their settings

Check for errors:

```bash
docker compose logs authelia | grep -i -E 'smtp|mail'
docker compose logs nextcloud | grep -i mail
```

## Troubleshooting

- **Connection refused** — wrong host/port, or ISP blocks outbound 25 (use 587)
- **Authentication failed** — for Gmail/Office 365 use an app password, not the account password
- **Mail lands in spam** — set up SPF/DKIM/DMARC for your domain with your provider, and keep the sender address on a domain you control
