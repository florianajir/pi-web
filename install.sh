#!/bin/sh
# pi-pcloud quick-start installer:
#   curl -fsSL https://raw.githubusercontent.com/florianajir/pi-pcloud/main/install.sh | sh
#
# Checks prerequisites, clones the repository (default ~/pi-pcloud, override
# with PI_PCLOUD_DIR), builds .env from .env.dist by prompting for the
# required values, then hands over to `make preflight` and `make install`.
# Standalone by design: it runs before the clone exists, so it cannot source
# scripts/lib.sh.
#
# Safe to re-run: an existing clone is fast-forwarded and an existing .env is
# never touched. Prompts read from /dev/tty (stdin is the script itself when
# piped from curl); any required value already exported in the environment
# skips its prompt, which allows unattended installs.
set -eu

REPO_URL="${PI_PCLOUD_REPO:-https://github.com/florianajir/pi-pcloud.git}"

log() { printf '[pi-pcloud] %s\n' "$*" >&2; }
die() {
    log "ERROR: $*"
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }
# `true`, not `:` — a redirection error on a special builtin like `:` is fatal
# in dash (the script aborts instead of returning a failure status).
interactive() { { true </dev/tty; } 2>/dev/null; }

restore_echo() {
    if [ -n "${ECHO_OFF:-}" ]; then
        stty echo </dev/tty 2>/dev/null || true
    fi
}
trap restore_echo EXIT
trap 'restore_echo; exit 130' INT
trap 'restore_echo; exit 143' TERM

confirm() {
    local answer=""
    printf '%s [y/N]: ' "$1" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
    case "$answer" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ask VAR "label" "default" [secret] — resolution order: already-exported
# value > interactive answer > default. Secrets are read with echo disabled.
ask() {
    local var="$1" label="$2" default="$3" secret="${4:-}"
    local current="" value=""

    eval "current=\${$var:-}"
    if [ -n "$current" ]; then
        return 0
    fi

    if ! interactive; then
        [ -n "$default" ] || die "$var is required but no terminal is available: export $var and re-run"
        eval "$var=\$default"
        return 0
    fi

    if [ -n "$default" ] && [ -z "$secret" ]; then
        printf '%s [%s]: ' "$label" "$default" >/dev/tty
    else
        printf '%s: ' "$label" >/dev/tty
    fi

    if [ -n "$secret" ]; then
        ECHO_OFF=1
        stty -echo </dev/tty
        IFS= read -r value </dev/tty || value=""
        stty echo </dev/tty
        ECHO_OFF=""
        printf '\n' >/dev/tty
    else
        IFS= read -r value </dev/tty || value=""
    fi

    [ -n "$value" ] || value="$default"
    [ -n "$value" ] || die "$var cannot be empty"
    eval "$var=\$value"
}

ensure_base_tools() {
    local missing="" cmd
    for cmd in git make; do
        have "$cmd" || missing="$missing $cmd"
    done
    [ -n "$missing" ] || return 0

    if have apt-get && interactive && confirm "Missing tools:$missing — install them with apt-get?"; then
        # shellcheck disable=SC2086
        sudo apt-get update -qq && sudo apt-get install -y $missing
    else
        die "missing required tools:$missing — install them and re-run"
    fi
}

ensure_docker() {
    if ! have docker; then
        if interactive && confirm "Docker is not installed. Install it now via https://get.docker.com?"; then
            curl -fsSL https://get.docker.com | sh
            sudo usermod -aG docker "$(id -un)"
        else
            die "Docker is required: https://docs.docker.com/engine/install/debian/"
        fi
    fi

    docker compose version >/dev/null 2>&1 \
        || die "the Docker Compose plugin is missing: https://docs.docker.com/compose/install/linux/"

    if ! docker info >/dev/null 2>&1; then
        if sudo docker info >/dev/null 2>&1; then
            die "Docker only answers via sudo: run 'sudo usermod -aG docker $(id -un)', log out and back in, then re-run this installer"
        fi
        die "Docker daemon is not reachable: check 'systemctl status docker'"
    fi
}

resolve_install_dir() {
    if [ -n "${PI_PCLOUD_DIR:-}" ]; then
        INSTALL_DIR="$PI_PCLOUD_DIR"
    elif [ -f compose.yaml ] && [ -f .env.dist ] && [ -d .git ]; then
        INSTALL_DIR="$(pwd)"
    else
        INSTALL_DIR="$HOME/pi-pcloud"
    fi
}

clone_or_update() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        case "$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null)" in
            "$REPO_URL" | *pi-pcloud*)
                log "Existing clone in $INSTALL_DIR, fast-forwarding..."
                git -C "$INSTALL_DIR" pull --ff-only \
                    || log "WARNING: could not fast-forward (local changes?), continuing with current checkout"
                ;;
            *) die "$INSTALL_DIR is a git repository but not a pi-pcloud clone; set PI_PCLOUD_DIR to another path" ;;
        esac
    elif [ -e "$INSTALL_DIR" ]; then
        die "$INSTALL_DIR exists and is not a pi-pcloud clone; set PI_PCLOUD_DIR to another path"
    else
        log "Cloning $REPO_URL into $INSTALL_DIR..."
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
}

# Injection-safe .env write: the value travels through awk's ENVIRON, never
# through a sed/awk program string, so |, &, \ or quotes cannot corrupt it.
set_env() {
    local key="$1"
    ENV_VALUE="$2" awk -v key="$key" '
        index($0, key "=") == 1 { print key "=" ENVIRON["ENV_VALUE"]; found = 1; next }
        { print }
        END { if (!found) print key "=" ENVIRON["ENV_VALUE"] }
    ' "$ENV_FILE" >"$ENV_FILE.tmp"
    chmod 600 "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
}

gen_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

detect_network() {
    local route=""
    route="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
    DETECTED_IP="$(printf '%s\n' "$route" | awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }')"
    DETECTED_IFACE="$(printf '%s\n' "$route" | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }')"
    DETECTED_GATEWAY="$(printf '%s\n' "$route" | awk '{ for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1) }')"
    DETECTED_SUBNET=""
    if [ -n "$DETECTED_IFACE" ]; then
        DETECTED_SUBNET="$(ip -4 route show dev "$DETECTED_IFACE" proto kernel scope link 2>/dev/null | awk 'NR == 1 { print $1 }')"
    fi
}

apply_network_defaults() {
    if [ -z "$DETECTED_IFACE" ] || [ -z "$DETECTED_SUBNET" ] || [ -z "$DETECTED_GATEWAY" ]; then
        log "WARNING: could not detect the LAN layout; review HOST_LAN_* and PIHOLE_IP in $ENV_FILE"
        return 0
    fi

    set_env HOST_LAN_PARENT "$DETECTED_IFACE"
    set_env HOST_LAN_SUBNET "$DETECTED_SUBNET"
    set_env HOST_LAN_GATEWAY "$DETECTED_GATEWAY"
    set_env ALLOW_IP_RANGES "127.0.0.1/32,$DETECTED_SUBNET,100.64.0.0/10,172.30.0.0/16"

    case "$DETECTED_SUBNET" in
        *.0/24)
            set_env PIHOLE_IP "${DETECTED_SUBNET%.0/24}.250"
            log "Network: $DETECTED_IFACE, subnet $DETECTED_SUBNET, gateway $DETECTED_GATEWAY, Pi-hole ${DETECTED_SUBNET%.0/24}.250"
            log "Make sure the Pi-hole IP sits outside your router's DHCP range (edit PIHOLE_IP in $ENV_FILE otherwise)"
            ;;
        *)
            log "Network: $DETECTED_IFACE, subnet $DETECTED_SUBNET, gateway $DETECTED_GATEWAY"
            log "WARNING: non-/24 subnet, set PIHOLE_IP in $ENV_FILE to a free address inside it"
            ;;
    esac
}

configure_env() {
    if [ -f "$ENV_FILE" ]; then
        log "Keeping existing $ENV_FILE"
        return 0
    fi

    detect_network
    local detected_tz="" generated=""
    detected_tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)"
    [ -n "$detected_tz" ] || detected_tz="Etc/UTC"
    generated="$(gen_password)"

    log "Configuring $ENV_FILE (press Enter to accept a [default])"
    ask HOST_NAME "Domain name (e.g. pi.example.com)" ""
    ask EMAIL "Admin email address" ""
    ask ADMIN_USER "Admin username" "admin"
    ask PASSWORD "Admin password (Enter = generate one)" "$generated" secret
    ask TIMEZONE "Timezone" "$detected_tz"
    ask HOST_LAN_IP "Static LAN IP of this machine" "$DETECTED_IP"
    ask CLOUDFLARE_DNS_API_TOKEN "Cloudflare API token (DNS edit on your zone)" "" secret
    ask CLOUDFLARE_ZONE_ID "Cloudflare zone ID" ""

    cp "$INSTALL_DIR/.env.dist" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    # shellcheck disable=SC2153 # assigned by ask() via eval
    set_env HOST_NAME "$HOST_NAME"
    set_env EMAIL "$EMAIL"
    set_env ADMIN_USER "$ADMIN_USER"
    set_env PASSWORD "$PASSWORD"
    set_env TIMEZONE "$TIMEZONE"
    set_env HOST_LAN_IP "$HOST_LAN_IP"
    set_env CLOUDFLARE_DNS_API_TOKEN "$CLOUDFLARE_DNS_API_TOKEN"
    set_env CLOUDFLARE_ZONE_ID "$CLOUDFLARE_ZONE_ID"
    apply_network_defaults

    if [ "$PASSWORD" = "$generated" ]; then
        log "A password was generated and stored as PASSWORD in $ENV_FILE (not displayed)"
    fi
    log "Optional settings (SMTP, S3 backups, language) can be filled in $ENV_FILE later"
}

main() {
    if [ "$(id -u)" -eq 0 ]; then
        log "WARNING: running as root — the stack will live under $HOME; prefer running as a regular user (sudo is requested only where needed)"
    fi
    have curl || die "curl is required"
    have sudo || die "sudo is required"
    ensure_base_tools
    ensure_docker
    resolve_install_dir
    clone_or_update
    ENV_FILE="$INSTALL_DIR/.env"
    configure_env

    cd "$INSTALL_DIR"
    log "Running preflight checks..."
    make preflight
    log "Installing (sudo will be requested for systemd/sysctl setup)..."
    make install

    local host_name=""
    host_name="$(grep '^HOST_NAME=' "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    log "Installation complete. First startup takes a few minutes (make logs to watch)."
    log "Next: create users at https://lldap.${host_name:-<HOST_NAME>} then sign in at https://auth.${host_name:-<HOST_NAME>}"
    log "See docs/INSTALLATION.md (First Login) for the remaining one-time steps."
}

main "$@"
