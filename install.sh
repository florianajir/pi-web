#!/bin/sh
# pi-pcloud quick-start installer:
#   curl -fsSL https://raw.githubusercontent.com/florianajir/pi-pcloud/main/install.sh | sh
#
# Checks prerequisites, clones the repository (default ~/pi-pcloud, override
# with PI_PCLOUD_DIR; run from inside an existing clone to reuse it), builds
# .env from .env.dist by prompting for the values required by the Makefile's
# REQUIRED_ENV_VARS, then hands over to `make preflight` and `make install`.
# Standalone by design: it runs before the clone exists, so it cannot source
# scripts/lib.sh.
#
# Safe to re-run: an existing clone is fast-forwarded and an existing .env is
# never touched (.env only appears once fully configured). Prompts read from
# /dev/tty (stdin is the script itself when piped from curl); any value
# already exported in the environment skips its prompt or overrides its
# auto-detection, which allows unattended installs (passwordless sudo needed).
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
# Empty answers re-prompt rather than abort, so a stray Enter cannot discard
# the answers already given.
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

    while [ -z "$value" ]; do
        if [ -n "$default" ] && [ -z "$secret" ]; then
            printf '%s [%s]: ' "$label" "$default" >/dev/tty
        else
            printf '%s: ' "$label" >/dev/tty
        fi

        if [ -n "$secret" ]; then
            ECHO_OFF=1
            stty -echo </dev/tty
            IFS= read -r value </dev/tty || die "no input available on /dev/tty for $var"
            stty echo </dev/tty
            ECHO_OFF=""
            printf '\n' >/dev/tty
        else
            IFS= read -r value </dev/tty || die "no input available on /dev/tty for $var"
        fi

        [ -n "$value" ] || value="$default"
        [ -n "$value" ] || log "$var cannot be empty"
    done
    eval "$var=\$value"
}

ensure_base_tools() {
    local missing="" cmd=""
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

# Downloaded to a file first: `curl | sh` would hide a download failure (the
# pipeline reports sh's status, and sh on empty input exits 0).
install_docker() {
    local script=""
    script="$(mktemp)"
    if ! curl -fsSL https://get.docker.com -o "$script"; then
        rm -f "$script"
        die "could not download https://get.docker.com — check network access and retry"
    fi
    sh "$script"
    rm -f "$script"
    have docker || die "the get.docker.com script did not install Docker"
    sudo usermod -aG docker "$(id -un)"
}

ensure_docker() {
    if ! have docker; then
        if interactive && confirm "Docker is not installed. Install it now via https://get.docker.com?"; then
            install_docker
            if ! docker info >/dev/null 2>&1; then
                die "Docker is installed, but the docker group only takes effect at next login: log out and back in, then re-run this installer (it resumes where it left off)"
            fi
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

read_env_key() {
    grep "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2-
}

# Injection-safe upsert into the staging file: the value travels through
# awk's ENVIRON, never through a program string, so |, &, \ or quotes cannot
# corrupt it. Written under umask 077 so secrets never touch a
# world-readable file.
set_env() {
    local key="$1"
    (
        umask 077
        ENV_VALUE="$2" awk -v key="$key" '
            index($0, key "=") == 1 { print key "=" ENVIRON["ENV_VALUE"]; found = 1; next }
            { print }
            END { if (!found) print key "=" ENVIRON["ENV_VALUE"] }
        ' "$ENV_STAGE" >"$ENV_STAGE.new"
    )
    mv "$ENV_STAGE.new" "$ENV_STAGE"
}

# Exported values win over detection, mirroring the prompt contract.
set_env_detected() {
    local key="$1" detected="$2" current=""
    eval "current=\${$key:-}"
    set_env "$key" "${current:-$detected}"
}

# Same generator as scripts/rotate-password.sh, so fresh installs and
# rotations follow one password policy; falls back if sourcing lib.sh fails.
gen_password() {
    local secret=""
    secret="$(sh -c '. "$1/scripts/lib.sh" >/dev/null 2>&1 && generate_secret' _ "$INSTALL_DIR" 2>/dev/null || true)"
    [ -n "$secret" ] || secret="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    printf '%s' "$secret"
}

detect_network() {
    local route=""
    route="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
    DETECTED_IP="" DETECTED_IFACE="" DETECTED_GATEWAY="" DETECTED_SUBNET=""
    # shellcheck disable=SC2086 # trusted `ip route` output, split on purpose
    set -- $route
    while [ $# -gt 1 ]; do
        case "$1" in
            src) DETECTED_IP="$2" ;;
            dev) DETECTED_IFACE="$2" ;;
            via) DETECTED_GATEWAY="$2" ;;
        esac
        shift
    done
    if [ -n "$DETECTED_IFACE" ]; then
        DETECTED_SUBNET="$(ip -4 route show dev "$DETECTED_IFACE" proto kernel scope link 2>/dev/null | awk 'NR == 1 { print $1 }')"
    fi
}

# .250 by convention (matches the .env.dist default), stepping down when it
# would collide with the host itself or the gateway.
pick_pihole_ip() {
    local prefix="$1" octet=""
    for octet in 250 249 248; do
        if [ "$prefix.$octet" != "${HOST_LAN_IP:-}" ] && [ "$prefix.$octet" != "$DETECTED_GATEWAY" ]; then
            printf '%s.%s' "$prefix" "$octet"
            return 0
        fi
    done
    printf '%s.250' "$prefix"
}

apply_network_defaults() {
    if [ -z "$DETECTED_IFACE" ] || [ -z "$DETECTED_SUBNET" ] || [ -z "$DETECTED_GATEWAY" ]; then
        log "Could not detect the LAN layout (interface/subnet/gateway)"
        if interactive && confirm "Continue with the 192.168.1.0/24 defaults from .env.dist (edit .env afterwards)?"; then
            log "WARNING: review HOST_LAN_*, ALLOW_IP_RANGES and PIHOLE_IP in $ENV_FILE before relying on the stack"
            return 0
        fi
        die "no safe network defaults: export HOST_LAN_PARENT, HOST_LAN_SUBNET, HOST_LAN_GATEWAY (and PIHOLE_IP), then re-run"
    fi

    local iface=""
    iface="${HOST_LAN_PARENT:-$DETECTED_IFACE}"
    case "$iface" in
        wl*)
            log "WARNING: $iface looks like Wi-Fi; macvlan (Pi-hole's LAN presence) does not work over most Wi-Fi adapters"
            if interactive; then
                confirm "Continue with $iface anyway?" || die "connect the machine over Ethernet or export HOST_LAN_PARENT, then re-run"
            fi
            ;;
    esac

    set_env_detected HOST_LAN_PARENT "$DETECTED_IFACE"
    set_env_detected HOST_LAN_SUBNET "$DETECTED_SUBNET"
    set_env_detected HOST_LAN_GATEWAY "$DETECTED_GATEWAY"

    local lan_subnet="" dist_ranges="" dist_lan=""
    lan_subnet="${HOST_LAN_SUBNET:-$DETECTED_SUBNET}"
    # The fixed members (loopback, VPN, Docker) stay owned by .env.dist: only
    # the LAN member is swapped for the detected subnet.
    dist_ranges="$(read_env_key "$INSTALL_DIR/.env.dist" ALLOW_IP_RANGES)"
    dist_lan="$(read_env_key "$INSTALL_DIR/.env.dist" HOST_LAN_SUBNET)"
    if [ -n "$dist_ranges" ] && [ -n "$dist_lan" ]; then
        set_env_detected ALLOW_IP_RANGES "$(printf '%s' "$dist_ranges" | sed "s|$dist_lan|$lan_subnet|")"
    fi

    case "$lan_subnet" in
        *.0/24)
            set_env_detected PIHOLE_IP "$(pick_pihole_ip "${lan_subnet%.0/24}")"
            ;;
        *)
            log "WARNING: non-/24 subnet ($lan_subnet): set PIHOLE_IP in $ENV_FILE to a free address inside it"
            ;;
    esac
    log "Network: interface $iface, subnet $lan_subnet, gateway ${HOST_LAN_GATEWAY:-$DETECTED_GATEWAY}"
}

configure_env() {
    if [ -f "$ENV_FILE" ]; then
        log "Keeping existing $ENV_FILE"
        return 0
    fi
    rm -f "$ENV_STAGE" "$ENV_STAGE.new"

    local required_vars="" var="" value="" detected_tz="" generated=""
    # The Makefile owns the required-variable list (enforced by check-env);
    # parsing it here keeps the installer in sync when the list grows.
    required_vars="$(sed -n 's/^REQUIRED_ENV_VARS[[:space:]]*:=[[:space:]]*//p' "$INSTALL_DIR/Makefile")"
    [ -n "$required_vars" ] || die "could not read REQUIRED_ENV_VARS from $INSTALL_DIR/Makefile"

    detect_network
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

    cp "$INSTALL_DIR/.env.dist" "$ENV_STAGE"
    chmod 600 "$ENV_STAGE"
    for var in $required_vars; do
        eval "value=\${$var:-}"
        if [ -z "$value" ]; then
            ask "$var" "$var" ""
            eval "value=\${$var:-}"
        fi
        set_env "$var" "$value"
    done
    apply_network_defaults
    mv "$ENV_STAGE" "$ENV_FILE"

    if [ "${PASSWORD:-}" = "$generated" ]; then
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
    ENV_STAGE="$ENV_FILE.tmp"
    configure_env

    cd "$INSTALL_DIR"
    log "Running preflight checks..."
    make preflight
    log "Installing (sudo will be requested for systemd/sysctl setup)..."
    make install

    local host_name="" pihole_ip=""
    host_name="$(read_env_key "$ENV_FILE" HOST_NAME)"
    pihole_ip="$(read_env_key "$ENV_FILE" PIHOLE_IP)"
    log "Installation complete. First startup takes a few minutes (make logs to watch)."
    [ -z "$pihole_ip" ] || log "Check that Pi-hole's IP ($pihole_ip) sits outside your router's DHCP range (edit PIHOLE_IP in .env otherwise)"
    log "Next: create users at https://lldap.${host_name:-<HOST_NAME>} then sign in at https://auth.${host_name:-<HOST_NAME>}"
    log "See docs/INSTALLATION.md (First Login) for the remaining one-time steps."
}

main "$@"
