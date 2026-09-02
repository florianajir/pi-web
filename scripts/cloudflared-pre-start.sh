#!/bin/sh
# Render the cloudflared ingress config from its template.
#
# Runs only when the `cloudflared` profile is enabled; the tunnel is optional and
# the stack is fully functional without it.

set -eu

. "$(dirname "$0")/lib.sh"

TEMPLATE_FILE="$PROJECT_DIR/config/cloudflared/config.yml.template"
CONFIG_FILE="$PROJECT_DIR/config/cloudflared/config.yml"
CREDENTIALS_FILE="$PROJECT_DIR/config/cloudflared/credentials.json"

main() {
    [ -f "$TEMPLATE_FILE" ] || die "config template not found at $TEMPLATE_FILE"

    HOST_NAME="$(get_env_value HOST_NAME)"
    HOST_NAME="${HOST_NAME:-pi.lan}"

    TUNNEL_ID="$(get_env_value CLOUDFLARE_TUNNEL_ID)"
    if [ -z "$TUNNEL_ID" ]; then
        die "CLOUDFLARE_TUNNEL_ID is not set in .env - create a tunnel first (see docs/NETWORKING.md)"
    fi

    # Docker creates a *directory* at a missing bind-mount source, and cloudflared
    # then fails to parse its credentials with an error that says nothing about
    # the real cause. Catch it here, where the message can be useful.
    if [ -d "$CREDENTIALS_FILE" ]; then
        die "$CREDENTIALS_FILE is a directory (Docker bind-mount artifact) - remove it and restore the tunnel credentials"
    fi
    if [ ! -e "$CREDENTIALS_FILE" ]; then
        die "tunnel credentials missing at $CREDENTIALS_FILE - copy the JSON written by 'cloudflared tunnel create'"
    fi
    # -r, not -f: the file is mode 400 and owned by the container's uid, so a
    # normal user running this by hand cannot read it, and that is expected.
    if [ ! -r "$CREDENTIALS_FILE" ]; then
        log "NOTE: $CREDENTIALS_FILE is not readable by $(id -un); that is expected when it is owned by the container uid"
    fi

    UPDATED_CONFIG=$(sed \
        -e "s|__TUNNEL_ID__|$(sed_escape "$TUNNEL_ID")|g" \
        -e "s|__HOST_NAME__|$(sed_escape "$HOST_NAME")|g" \
        "$TEMPLATE_FILE")

    if [ -f "$CONFIG_FILE" ] && [ "$UPDATED_CONFIG" = "$(cat "$CONFIG_FILE")" ]; then
        log "Ingress config already up to date"
    else
        printf '%s\n' "$UPDATED_CONFIG" > "$CONFIG_FILE"
        safe_chmod 644 "$CONFIG_FILE"
        log "Rendered $CONFIG_FILE for $HOST_NAME (tunnel $TUNNEL_ID)"
    fi
}

main "$@"
