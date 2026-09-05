#!/bin/sh
set -eu

# Generates the shared secret the n8n task broker and its external runner
# authenticate with.
#
# It used to be `${N8N_RUNNERS_AUTH_TOKEN:-<a hard-coded default>}` in compose.yaml,
# with the variable defined nowhere - so every install ran the broker with the
# same published default, listening on 0.0.0.0 inside `frontend`. Any of the
# ~25 containers there could register as a task runner and receive the workflow
# code and data n8n hands out for execution.
#
# Not derived from PASSWORD: this is a machine-to-machine credential with no
# login behind it, so rotate-password.sh leaves it alone, like Comet's and
# ntfy's own secrets.

. "$(dirname "$0")/lib.sh"

OUTPUT_FILE="${PROJECT_DIR}/config/n8n/n8n.env"

TOKEN_VALUE="$(read_env_value_from_file "$OUTPUT_FILE" N8N_RUNNERS_AUTH_TOKEN)"

if [ -z "$TOKEN_VALUE" ]; then
    TOKEN_VALUE="$(generate_secret)"
    log "Generated N8N_RUNNERS_AUTH_TOKEN for the n8n task broker"
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

# generate_secret emits hex, so no value here needs Compose's $$ escaping.
{
    printf '# Managed by scripts/n8n-pre-start.sh\n'
    printf 'N8N_RUNNERS_AUTH_TOKEN=%s\n' "$TOKEN_VALUE"
} | write_secret_file "$OUTPUT_FILE" || die "could not write $OUTPUT_FILE"
# The systemd unit runs this as root; without this the file lands root:root 0600
# and the next non-root run dies under `set -eu`, which stack-up.sh turns into a
# fatal start for the whole stack.
fix_ownership "$OUTPUT_FILE"
log "Rendered n8n env to $OUTPUT_FILE"
