#!/bin/sh
set -eu

# Generates Comet's two passwords: the /admin dashboard and the /configure page.
#
# Neither is derived from PASSWORD, for the reason vaultwarden-pre-start.sh
# gives: both are Comet's own login with no Authelia forward-auth in front, and
# /configure is the page that holds a user's debrid API key. Reusing the SSO
# password would turn a PASSWORD leak into a debrid-credential leak, so
# rotate-password.sh leaves these alone like it does the ntfy passwords.
#
# CONFIGURE_PAGE_PASSWORD has a second job: setting it is what makes Comet mount
# every Stremio endpoint under /s/<PUBLIC_API_TOKEN>/ (_build_stremio_api_prefix
# in comet/core/models.py), and that prefix is the only thing comet-public@docker
# lets out to the internet. The token is NOT derived from the password - it is
# persisted in the comet_data volume through PUBLIC_API_TOKEN_FILE - so rotating
# either password here leaves every already-installed addon URL valid.

. "$(dirname "$0")/lib.sh"

OUTPUT_FILE="${PROJECT_DIR}/config/comet/comet.env"

ADMIN_PASSWORD_VALUE="$(read_env_value_from_file "$OUTPUT_FILE" ADMIN_DASHBOARD_PASSWORD)"
CONFIGURE_PASSWORD_VALUE="$(read_env_value_from_file "$OUTPUT_FILE" CONFIGURE_PAGE_PASSWORD)"

if [ -z "$ADMIN_PASSWORD_VALUE" ]; then
    ADMIN_PASSWORD_VALUE="$(generate_secret)"
    log "Generated ADMIN_DASHBOARD_PASSWORD for Comet's admin dashboard"
fi

if [ -z "$CONFIGURE_PASSWORD_VALUE" ]; then
    CONFIGURE_PASSWORD_VALUE="$(generate_secret)"
    log "Generated CONFIGURE_PAGE_PASSWORD for Comet's configuration page"
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

# generate_secret emits hex, so no value here needs Compose's $$ escaping.
{
    printf '# Managed by scripts/comet-pre-start.sh\n'
    printf 'ADMIN_DASHBOARD_PASSWORD=%s\n' "$ADMIN_PASSWORD_VALUE"
    printf 'CONFIGURE_PAGE_PASSWORD=%s\n' "$CONFIGURE_PASSWORD_VALUE"
} | write_secret_file "$OUTPUT_FILE" || die "could not write $OUTPUT_FILE"
# The systemd unit runs this as root, so without this the file lands root:root
# 0600: the grep documented in docs/SECURITY.md is denied, and the next non-root
# run of this script dies under `set -eu` - which stack-up.sh turns into a fatal
# start for the whole stack.
fix_ownership "$OUTPUT_FILE"
log "Rendered Comet env to $OUTPUT_FILE"
