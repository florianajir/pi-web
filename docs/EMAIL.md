# Email & Notifications

The stack supports outbound email for notifications, password resets, and workflow automation. All services share SMTP credentials configured in `.env`.

## SMTP Configuration

All SMTP settings are defined in `.env`:

| Variable | Purpose | Default | Example |
|----------|---------|---------|---------|
| `SMTP_HOST` | SMTP server | `localhost` | `smtp.gmail.com` |
| `SMTP_PORT` | SMTP port | `587` | 587 (TLS), 465 (SSL), 25 (plain) |
| `SMTP_USERNAME` | Username | *(empty)* | `your-email@gmail.com` |
| `SMTP_PASSWORD` | Password/token | *(empty)* | App password (Gmail) or token |
| `EMAIL` | Sender address | `noreply@localhost` | `noreply@example.com` |
| `SMTP_SECURE` | Nextcloud security | `tls` | `tls`, `ssl`, or empty |
| `SMTP_AUTHTYPE` | Nextcloud auth | `LOGIN` | `LOGIN`, `PLAIN`, etc. |
| `SMTP_ENCRYPTION` | LLDAP encryption | `STARTTLS` | `STARTTLS`, `NONE` |
| `SMTP_SSL` | n8n SSL | `false` | `true` or `false` |
| `MAIL_FROM_ADDRESS` | Nextcloud sender local | `nextcloud` | Local part of address |
| `MAIL_DOMAIN` | Nextcloud sender domain | `${HOST_NAME}` | Combined: `${MAIL_FROM_ADDRESS}@${MAIL_DOMAIN}` |

## Quick Setup by Provider

### Gmail

```env
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USERNAME=your-email@gmail.com
SMTP_PASSWORD=abcd efgh ijkl mnop             # 16-char app password
SMTP_SECURE=tls
SMTP_AUTHTYPE=LOGIN
EMAIL=your-email@gmail.com
```

**To generate app password:**
1. Enable 2FA on Google Account
2. Go to https://myaccount.google.com/apppasswords
3. Select **Mail** and **Windows Computer** (or other device)
4. Copy 16-character password
5. Paste into `SMTP_PASSWORD` (spaces ignored)

### Outlook/Microsoft

```env
SMTP_HOST=smtp.office365.com
SMTP_PORT=587
SMTP_USERNAME=your-email@outlook.com
SMTP_PASSWORD=your-app-password
SMTP_SECURE=tls
SMTP_AUTHTYPE=LOGIN
EMAIL=your-email@outlook.com
```

### Postmark, SendGrid, Mailgun

```env
SMTP_HOST=smtp.postmarkapp.com              # (for Postmark)
SMTP_PORT=587
SMTP_USERNAME=your-api-token
SMTP_PASSWORD=your-api-token
SMTP_SECURE=tls
EMAIL=your-verified-sender@example.com
```

### Self-hosted Postfix/Sendmail

```env
SMTP_HOST=localhost                         # On Pi, local relay
SMTP_PORT=25
SMTP_USERNAME=                              # Often empty
SMTP_PASSWORD=                              # Often empty
SMTP_SECURE=
SMTP_AUTHTYPE=
EMAIL=noreply@example.com
```

## Services Using Email

### Auto-configured Services

These read SMTP settings directly from `.env` at startup — **no manual setup needed:**

#### Authelia

**Purpose:** 2FA enrollment, password reset, identity verification

**Configuration:** Auto-configured from `.env`

**Example email:**
- Subject: "Verify your new email address"
- Body: Verification link + 5-minute expiry

**Note:** Has `disable_startup_check` enabled — stack starts even without valid SMTP

#### Nextcloud

**Purpose:** Sharing notifications, activity digests, password resets

**Configuration:** Auto-configured from `.env` variables:
- `MAIL_FROM_ADDRESS` + `MAIL_DOMAIN` = sender address
- `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`
- `SMTP_SECURE`, `SMTP_AUTHTYPE` (per-service overrides)

**Example email:**
- Sharing: "John shared a folder with you"
- Digest: Daily activity summary
- Reset: Password reset link

**Features:**
- Can be disabled per-user in Nextcloud settings
- Digest frequency configurable in admin panel
- Replies to emails are **not** processed

#### LLDAP

**Purpose:** Self-service password reset emails

**Configuration:** Auto-configured from `.env`

**Example email:**
- Subject: "Password reset for LLDAP"
- Body: Reset link + instructions

#### n8n

**Purpose:** Workflow email nodes, error notifications

**Configuration:** Auto-configured from `.env`, mapped to `N8N_SMTP_*` variables

**Example:**
- Nodes: **Send Email** action in workflows
- Errors: Notifications on workflow failures

#### Ntfy

**Purpose:** Outbound email notifications for push topics

**Configuration:** Auto-configured from `.env`

**Example:**
- Alert triggers Ntfy topic
- Ntfy sends email via `SMTP_HOST:SMTP_PORT`

#### Beszel

**Purpose:** Host monitoring alerts, threshold breaches, offline alerts

**Configuration:** Auto-configured via PocketBase settings API (bootstrap script)

**Example emails:**
- "CPU usage exceeded 85%"
- "System went offline"
- "Disk usage is critical (>90%)"

### Manual Setup Services

These support email but must be configured through their web UI:

#### Uptime Kuma

**Location:** *Settings* → *Notifications* → *Add*

**Steps:**
1. Log in to `https://uptime.<HOST_NAME>`
2. Go to **Settings** → **Notifications**
3. Click **Add Notification**
4. Select **SMTP**
5. Fill in:
   - Server: `SMTP_HOST`
   - Port: `SMTP_PORT`
   - Username: `SMTP_USERNAME`
   - Password: `SMTP_PASSWORD`
   - From email: `EMAIL`
   - Secure: `SMTP_SECURE` choice
6. Test & save

**Uses for:** Uptime alerts, status changes

#### Immich

**Status:** Not currently supported in Immich

Immich doesn't expose SMTP settings for notifications. Workaround: Use webhooks to external services (n8n, Zapier, IFTTT).

#### Portainer

**Status:** Not currently supported in Portainer

Portainer doesn't expose SMTP settings for notifications. Workaround: Use alerts via webhooks.

## Testing Email

### Send Test Email from CLI

```bash
# Using sendmail command
echo "Subject: Test\n\nThis is a test." | \
  sendmail -S smtp.gmail.com:587 \
  -au your-email@gmail.com \
  -ap password \
  recipient@example.com
```

### Check Service Logs

```bash
# Authelia
docker compose logs authelia | grep -i email

# Nextcloud
docker compose logs nextcloud | grep -i mail

# Check if SMTP credentials work
docker compose exec authelia curl -v smtp://SMTP_HOST:SMTP_PORT
```

### Test via Services

1. **Authelia:** Go to `https://auth.<HOST_NAME>` → **Profile** → **Add email** → verify
2. **Nextcloud:** Share file with another user → should receive email
3. **Beszel:** Create alert → should email when triggered

## Troubleshooting

### Emails not sending

**Check 1: SMTP credentials**
```bash
# Verify in .env
grep SMTP .env | head -5
```

**Check 2: Firewall**
- Outbound port `SMTP_PORT` (587/465/25) must be open
- Check ISP blocks port 25 (common for residential)
- Try port 587 (TLS, less likely to be blocked)

**Check 3: Service logs**
```bash
docker compose logs authelia | tail -20
docker compose logs nextcloud | tail -20
```

Look for connection errors:
- `Connection refused` — Wrong host/port
- `Authentication failed` — Wrong username/password
- `Timeout` — Firewall blocking port

**Check 4: SMTP server requirements**
- Gmail: Requires app password, not your Google password
- Office 365: May require "less secure apps" enabled (for some accounts)
- Self-hosted: Check Postfix/Sendmail is running and listening

### Restart to apply changes

After editing `.env`:

```bash
make stop
make start
make logs
```

Wait 30 seconds for services to fully start.

### Email arriving in spam

**Common causes:**
1. SPF/DKIM/DMARC not configured for your domain
2. Sender address doesn't match SMTP account
3. Low reputation (new domain/account)

**Solutions:**
1. Configure DNS records:
   - **SPF:** `v=spf1 include:mail.provider.com ~all`
   - **DKIM:** Ask provider for record
   - **DMARC:** `v=DMARC1; p=none;`
2. Use `MAIL_FROM_ADDRESS=noreply` and `MAIL_DOMAIN=<your-domain>`
3. Wait 7-14 days for reputation to build
4. Check provider's spam folder; mark as "Not spam"

### Disable email for testing

To disable email without errors:

```env
SMTP_HOST=                          # Leave empty
SMTP_PORT=
SMTP_USERNAME=
SMTP_PASSWORD=
```

Stack starts normally; email delivery fails silently. Authelia's `disable_startup_check` keeps the stack resilient.

## Advanced: Email Rules & Filters

### Nextcloud Mail Settings (Admin)

1. Go to **Settings** → **Administration** → **Mail**
2. Configure:
   - Default address: `admin@example.com`
   - Reply-to address: Optional
   - Send mode: SMTP (already configured)

### Create Email Workflows in n8n

Example: Trigger email on Nextcloud file upload

1. Create n8n workflow
2. Add **Nextcloud** trigger: "File uploaded"
3. Add **Send Email** node with notification
4. Deploy workflow
5. Emails now sent automatically on uploads

### Forward to Slack / Discord

Ntfy can bridge to Slack/Discord:

1. Create Slack webhook URL
2. In Beszel alert, set webhook to Slack endpoint
3. Alerts now appear in Slack channel

## Best Practices

1. **Use app passwords** — Never use your actual Gmail/Office password
2. **Test after changes** — Verify with a test email
3. **Monitor logs** — Check for SMTP errors in service logs
4. **Use TLS** — Port 587 (TLS) preferred over 25 (plain text)
5. **SPF/DKIM** — Configure DNS records to improve deliverability
6. **Reply-to address** — Keep consistent with your domain
7. **Rate limits** — Most providers limit emails per minute; don't spam
8. **Privacy** — Sending service has access to email content; use trusted providers

See [Configuration](CONFIGURATION.md#email--smtp) for all SMTP environment variables and examples.
