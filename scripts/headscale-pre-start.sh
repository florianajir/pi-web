#!/bin/sh
# Render Headscale policy from template using EMAIL

set -eu

. "$(dirname "$0")/lib.sh"

POLICY_TEMPLATE_FILE="$PROJECT_DIR/config/headscale/policy.hujson.template"
POLICY_FILE="$PROJECT_DIR/config/headscale/policy.hujson"
CONFIG_TEMPLATE_FILE="$PROJECT_DIR/config/headscale/config.yaml.template"
CONFIG_FILE="$PROJECT_DIR/config/headscale/config.yaml"

main() {
    # These paths must exist as files before `docker compose up`: Docker creates a
    # directory at a missing bind-mount source, and headplane then dies on EISDIR.
    HEADPLANE_CONFIG="$PROJECT_DIR/config/headplane/config.yaml"
    HEADPLANE_API_KEY_FILE="$PROJECT_DIR/config/headplane/headscale_api_key"
    HOMEPAGE_API_KEY_FILE="$PROJECT_DIR/config/homepage/secrets/headscale_api_key"
    mkdir -p "$(dirname "$HEADPLANE_CONFIG")"
    if [ -d "$HEADPLANE_CONFIG" ]; then
        log "WARNING: headplane config.yaml is a directory (Docker bind-mount artifact). Removing..."
        rm -rf "$HEADPLANE_CONFIG"
    fi
    if [ ! -e "$HEADPLANE_CONFIG" ]; then
        touch "$HEADPLANE_CONFIG"
        log "Created placeholder $HEADPLANE_CONFIG (will be populated by headscale-init.sh)"
    fi

    # Ensure the Headscale API key file bind-mounted by Headplane is a file.
    if [ -d "$HEADPLANE_API_KEY_FILE" ]; then
        log "WARNING: headplane headscale_api_key is a directory (Docker bind-mount artifact). Removing..."
        rm -rf "$HEADPLANE_API_KEY_FILE"
    fi
    if [ ! -e "$HEADPLANE_API_KEY_FILE" ]; then
        printf 'pending-headscale-api-key\n' > "$HEADPLANE_API_KEY_FILE"
        chmod 600 "$HEADPLANE_API_KEY_FILE" 2>/dev/null || true
        log "Created placeholder $HEADPLANE_API_KEY_FILE (will be populated by headscale-init.sh)"
    fi

    # Same again for the second Headscale key, the one homepage's widget and the
    # system-tools `devices` topic both bind-mount. It is created by
    # homepage-widgets-bootstrap.sh, which is a post-start hook - i.e. after the
    # `docker compose up` that bind-mounts it - so on a fresh install Docker gets
    # there first and makes a directory, which write_secret can then never
    # replace. Left empty on purpose: that bootstrap only mints a key when the
    # file has no content in it.
    mkdir -p "$(dirname "$HOMEPAGE_API_KEY_FILE")"
    if [ -d "$HOMEPAGE_API_KEY_FILE" ]; then
        log "WARNING: homepage headscale_api_key is a directory (Docker bind-mount artifact). Removing..."
        rm -rf "$HOMEPAGE_API_KEY_FILE"
    fi
    if [ ! -e "$HOMEPAGE_API_KEY_FILE" ]; then
        touch "$HOMEPAGE_API_KEY_FILE"
        safe_chmod 600 "$HOMEPAGE_API_KEY_FILE"
        log "Created empty $HOMEPAGE_API_KEY_FILE (will be populated by homepage-widgets-bootstrap.sh)"
    fi

    if [ ! -f "$POLICY_TEMPLATE_FILE" ]; then
        die "policy template not found at $POLICY_TEMPLATE_FILE"
    fi

    if [ ! -f "$CONFIG_TEMPLATE_FILE" ]; then
        die "config template not found at $CONFIG_TEMPLATE_FILE"
    fi

    EMAIL="$(get_env_value EMAIL)"
    HOST_NAME="$(get_env_value HOST_NAME)"
    DATA_LOCATION="$(get_env_value DATA_LOCATION)"
    HOST_LAN_SUBNET="$(get_env_value HOST_LAN_SUBNET)"

    if [ -z "$EMAIL" ]; then
        die "EMAIL is not set in .env"
    fi

    HOST_NAME="${HOST_NAME:-pi.lan}"
    DATA_LOCATION="${DATA_LOCATION:-./data}"
    HOST_LAN_SUBNET="${HOST_LAN_SUBNET:-192.168.1.0/24}"
    case "$DATA_LOCATION" in
        /*) : ;;
        *)  DATA_LOCATION="$PROJECT_DIR/$DATA_LOCATION" ;;
    esac

    # Read OIDC client secret for Headscale node registration. -r rather than -f:
    # the file is mode 600 and root-owned, so a test for existence alone is also
    # false when this script is run by hand as a normal user, and the secret then
    # silently reads as empty.
    OIDC_SECRET_FILE="$DATA_LOCATION/authelia-config/secrets/oidc_headscale_secret.txt"
    OIDC_HEADSCALE_SECRET=""
    if [ -r "$OIDC_SECRET_FILE" ]; then
        OIDC_HEADSCALE_SECRET=$(cat "$OIDC_SECRET_FILE")
    fi

    UPDATED_POLICY=$(sed \
        -e "s|__HEADSCALE_USER__|$(sed_escape "$EMAIL")|g" \
        -e "s|__HOST_LAN_SUBNET__|$(sed_escape "$HOST_LAN_SUBNET")|g" \
        "$POLICY_TEMPLATE_FILE")

    if [ -f "$POLICY_FILE" ] && [ "$UPDATED_POLICY" = "$(cat "$POLICY_FILE")" ]; then
        log "Policy already up to date"
    else
        printf '%s\n' "$UPDATED_POLICY" > "$POLICY_FILE"
        log "Rendered policy to $POLICY_FILE"
    fi

    # Authelia has this client as confidential (public: false, hashed secret), so
    # substituting an empty string does not produce a degraded config - it
    # produces one Authelia rejects every login against, while headscale starts
    # happily: only_start_if_oidc_is_available gates on the *discovery* call,
    # which reads the issuer alone and never the secret, so it cannot catch
    # this. Worse, the "already up to date" check below then preserves it on
    # every later run. Never write that file.
    if [ -z "$OIDC_HEADSCALE_SECRET" ]; then
        # The secrets directory is mode 700 root-owned, so a non-root run cannot
        # even stat the file: absent and forbidden look identical from here
        # unless the directory itself is tested for searchability.
        if [ -e "$OIDC_SECRET_FILE" ] || [ ! -x "$(dirname "$OIDC_SECRET_FILE")" ]; then
            log "ERROR: cannot read $OIDC_SECRET_FILE - run this as root, the way the systemd unit does"
        else
            log "ERROR: OIDC secret missing at $OIDC_SECRET_FILE - run authelia-pre-start.sh first"
        fi
        if [ -f "$CONFIG_FILE" ]; then
            # Whatever is already there at least kept working until now.
            log "Leaving $CONFIG_FILE untouched"
            exit 0
        fi
        exit 1
    fi

    UPDATED_CONFIG=$(sed \
        -e "s|__HOST_NAME__|$(sed_escape "$HOST_NAME")|g" \
        -e "s|__OIDC_HEADSCALE_SECRET__|$(sed_escape "$OIDC_HEADSCALE_SECRET")|g" \
        "$CONFIG_TEMPLATE_FILE")

    if [ -f "$CONFIG_FILE" ] && [ "$UPDATED_CONFIG" = "$(cat "$CONFIG_FILE")" ]; then
        log "Config already up to date"
        exit 0
    fi

    printf '%s\n' "$UPDATED_CONFIG" | write_secret_file "$CONFIG_FILE" ||
        die "could not write $CONFIG_FILE"
    fix_ownership "$CONFIG_FILE"
    log "Rendered config to $CONFIG_FILE"
}

main "$@"
