#!/bin/sh
# Render Headscale policy from template using EMAIL

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}" 
ENV_FILE="$PROJECT_DIR/.env"
POLICY_TEMPLATE_FILE="$PROJECT_DIR/config/headscale/policy.hujson.template"
POLICY_FILE="$PROJECT_DIR/config/headscale/policy.hujson"
CONFIG_TEMPLATE_FILE="$PROJECT_DIR/config/headscale/config.yaml.template"
CONFIG_FILE="$PROJECT_DIR/config/headscale/config.yaml"

log() {
    echo "[headscale-policy] $(date '+%H:%M:%S') $*" >&2
}

main() {
    if [ ! -f "$POLICY_TEMPLATE_FILE" ]; then
        log "ERROR: policy template not found at $POLICY_TEMPLATE_FILE"
        exit 1
    fi

    if [ ! -f "$CONFIG_TEMPLATE_FILE" ]; then
        log "ERROR: config template not found at $CONFIG_TEMPLATE_FILE"
        exit 1
    fi

    if [ -f "$ENV_FILE" ]; then
        EMAIL=$(grep "^EMAIL=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "")
        HOST_NAME=$(grep "^HOST_NAME=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "")
        PIHOLE_IP=$(grep "^PIHOLE_IP=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "")
    fi

    if [ -z "$EMAIL" ]; then
        log "ERROR: EMAIL is not set in .env"
        exit 1
    fi

    HOST_NAME="${HOST_NAME:-pi.lan}"
    PIHOLE_IP="${PIHOLE_IP:-192.168.1.29}"

    UPDATED_POLICY=$(sed -e "s|__HEADSCALE_USER__|$EMAIL|g" "$POLICY_TEMPLATE_FILE")

    if [ -f "$POLICY_FILE" ] && [ "$UPDATED_POLICY" = "$(cat "$POLICY_FILE")" ]; then
        log "Policy already up to date"
    else
        printf '%s\n' "$UPDATED_POLICY" > "$POLICY_FILE"
        log "Rendered policy to $POLICY_FILE"
    fi

    UPDATED_CONFIG=$(sed -e "s|__HOST_NAME__|$HOST_NAME|g" -e "s|__PIHOLE_IP__|$PIHOLE_IP|g" "$CONFIG_TEMPLATE_FILE")

    if [ -f "$CONFIG_FILE" ] && [ "$UPDATED_CONFIG" = "$(cat "$CONFIG_FILE")" ]; then
        log "Config already up to date"
        exit 0
    fi

    printf '%s\n' "$UPDATED_CONFIG" > "$CONFIG_FILE"
    log "Rendered config to $CONFIG_FILE"
}

main "$@"
