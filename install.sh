#!/bin/sh
# pi-pcloud quick-start installer:
#   curl -fsSL https://raw.githubusercontent.com/florianajir/pi-pcloud/main/install.sh | sh
#
# Checks prerequisites, clones the repository (default ~/pi-pcloud, override
# with PI_PCLOUD_DIR; run from inside an existing clone to reuse it), builds
# .env from .env.dist by prompting for the Makefile's REQUIRED_ENV_VARS, then
# hands over to `make preflight` and `make install`.
#
# Standalone by design: the prerequisite/clone phase runs before the clone
# exists, so it cannot source scripts/lib.sh. Post-clone helpers delegate to
# lib.sh in a subshell (sourcing it here would clobber this script's log/die).
#
# Safe to re-run: an existing clone is fast-forwarded, an existing .env is
# never touched, and .env only appears once fully configured. Prompts read
# from /dev/tty (stdin is the script itself when piped from curl); any value
# already exported skips its prompt or overrides its auto-detection, which
# allows unattended installs (these need passwordless sudo, as `make install`
# applies sysctl/systemd changes).
set -eu

REPO_URL="${PI_PCLOUD_REPO:-https://github.com/florianajir/pi-pcloud.git}"
# Privilege prefix for the handful of root-only commands below; check_privileges
# empties it when the installer already runs as root, since a root-only image
# often ships without a sudo binary at all. The Makefile applies the same rule
# to its own recipes, so `make install` works in that environment too.
SUDO="sudo"

log() { printf '[pi-pcloud] %s\n' "$*" >&2; }
die() {
    log "ERROR: $*"
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }
# `true`, not `:` — a redirection error on a special builtin like `:` is fatal
# in dash (the script aborts instead of returning a failure status).
interactive() { { true </dev/tty; } 2>/dev/null; }

# Runs on every exit path, including the signal traps below, so a terminal is
# never left with echo off and the staging file (which holds secrets) never
# outlives the run.
cleanup() {
    # Redirections apply left to right, so the group keeps a missing /dev/tty
    # from printing an error of its own.
    { stty echo </dev/tty; } 2>/dev/null || true
    [ -z "${ENV_STAGE:-}" ] || rm -f "$ENV_STAGE" "$ENV_STAGE.new"
    [ -z "${DOCKER_SCRIPT:-}" ] || rm -f "$DOCKER_SCRIPT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

confirm() {
    local answer=""
    printf '%s [y/N]: ' "$1" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
    case "$answer" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Docker Compose's .env parser mangles more than `$VAR` interpolation: a
# trailing backslash escapes the newline, an unquoted value is truncated at
# whitespace-then-`#` (inline comment) and surrounding quotes are stripped —
# while the bootstrap scripts read .env verbatim with grep/cut, so any of
# these would hand the services and the scripts two different values. All are
# refused at the prompt instead of being silently mangled downstream.
# Compose's `$$` escape is not usable here for the same verbatim-reader
# reason. Newlines can only arrive via pre-exported values (read -r cannot
# produce one); LF is a literal newline because $(...) strips trailing ones.
LF='
'
VALUE_RULES="must not contain '\$', '\\', a newline or ' #', and must not start or end with a quote (Docker Compose's .env parser mangles these)"
# shellcheck disable=SC1003 # '\' is a literal backslash pattern, not an escaped quote
value_is_safe() {
    case "$1" in
        *'$'* | *'\'* | *[[:space:]]'#'* | \"* | *\" | \'* | *\' | *"$LF"*) return 1 ;;
        *) return 0 ;;
    esac
}

# ask VAR "label" "default" [secret] — resolution order: already-exported
# value > interactive answer > default. Secrets are read with echo disabled.
# Empty or unsafe answers re-prompt rather than abort, so a stray Enter cannot
# discard the answers already given.
ask() {
    local var="$1" label="$2" default="$3" secret="${4:-}"
    local current="" value=""

    eval "current=\${$var:-}"
    if [ -n "$current" ]; then
        value_is_safe "$current" || die "$var $VALUE_RULES"
        return 0
    fi

    if ! interactive; then
        [ -n "$default" ] || die "$var is required but no terminal is available: export $var and re-run"
        eval "$var=\$default"
        return 0
    fi

    while :; do
        if [ -n "$default" ] && [ -z "$secret" ]; then
            printf '%s [%s]: ' "$label" "$default" >/dev/tty
        else
            printf '%s: ' "$label" >/dev/tty
        fi

        if [ -n "$secret" ]; then
            stty -echo </dev/tty
            IFS= read -r value </dev/tty || die "no input available on /dev/tty for $var"
            stty echo </dev/tty
            printf '\n' >/dev/tty
        else
            IFS= read -r value </dev/tty || die "no input available on /dev/tty for $var"
        fi

        [ -n "$value" ] || value="$default"
        if [ -z "$value" ]; then
            log "$var cannot be empty"
        elif ! value_is_safe "$value"; then
            log "$var $VALUE_RULES"
        else
            break
        fi
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
        if ! $SUDO apt-get update -qq; then
            die "apt-get update failed — check your mirrors, install$missing manually and re-run"
        fi
        # shellcheck disable=SC2086
        if ! $SUDO apt-get install -y $missing; then
            die "apt-get could not install$missing — install them manually and re-run"
        fi
    else
        die "missing required tools:$missing — install them and re-run"
    fi
}

# Downloaded to a file first: `curl | sh` would hide a download failure (the
# pipeline reports sh's status, and sh on empty input exits 0).
install_docker() {
    DOCKER_SCRIPT="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$DOCKER_SCRIPT" \
        || die "could not download https://get.docker.com — check network access and retry"
    sh "$DOCKER_SCRIPT"
    rm -f "$DOCKER_SCRIPT"
    DOCKER_SCRIPT=""
    have docker || die "the get.docker.com script did not install Docker"
    # Skipped as root: the group grant would be a no-op (the daemon socket is
    # already reachable) and sudo may not exist to carry it out.
    # shellcheck disable=SC2086
    [ -z "$SUDO" ] || $SUDO usermod -aG docker "$(id -un)"
}

ensure_docker() {
    local daemon_ok=""

    if ! have docker; then
        if interactive && confirm "Docker is not installed. Install it now via https://get.docker.com?"; then
            install_docker
            docker info >/dev/null 2>&1 \
                || die "Docker is installed, but the docker group only takes effect at next login: log out and back in, then re-run this installer (it resumes where it left off)"
            daemon_ok=1
        else
            die "Docker is required: https://docs.docker.com/engine/install/debian/"
        fi
    fi

    docker compose version >/dev/null 2>&1 \
        || die "the Docker Compose plugin is missing: https://docs.docker.com/compose/install/linux/"

    [ -z "$daemon_ok" ] || return 0
    if ! docker info >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
            die "Docker only answers via sudo: run 'sudo usermod -aG docker $(id -un)', log out and back in, then re-run this installer"
        fi
        die "Docker daemon is not reachable: check 'systemctl status docker'"
    fi
}

# `-e`, not `-d`: .git is a file in worktree and submodule checkouts.
looks_like_clone() {
    [ -f "$1/compose.yaml" ] && [ -f "$1/.env.dist" ] && [ -e "$1/.git" ]
}

resolve_install_dir() {
    if [ -n "${PI_PCLOUD_DIR:-}" ]; then
        INSTALL_DIR="$PI_PCLOUD_DIR"
    elif looks_like_clone "$(pwd)"; then
        INSTALL_DIR="$(pwd)"
    elif [ "$(id -u)" -eq 0 ]; then
        # $HOME would bake /root into the systemd unit's WorkingDirectory,
        # leaving the stack unmanageable from the operator's account.
        INSTALL_DIR="/opt/pi-pcloud"
    else
        INSTALL_DIR="$HOME/pi-pcloud"
    fi
}

clone_or_update() {
    if [ -e "$INSTALL_DIR/.git" ]; then
        case "$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null)" in
            "$REPO_URL" | *pi-pcloud*)
                log "Existing clone in $INSTALL_DIR, fast-forwarding..."
                git -C "$INSTALL_DIR" pull --ff-only \
                    || log "WARNING: could not fast-forward (local changes?), continuing with current checkout"
                ;;
            *) die "$INSTALL_DIR is a git repository but not a pi-pcloud clone; set PI_PCLOUD_DIR to another path" ;;
        esac
    # An empty pre-created directory (permissions or mount setup) is fine:
    # git clone accepts it as a destination.
    elif [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        die "$INSTALL_DIR exists and is neither empty nor a pi-pcloud clone; set PI_PCLOUD_DIR to another path"
    else
        log "Cloning $REPO_URL into $INSTALL_DIR..."
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
}

# Delegates to lib.sh so the installer and the stack agree on .env parsing;
# the subshell keeps lib.sh's own log/die out of this script.
read_env_key() {
    sh -c '. "$1/scripts/lib.sh" >/dev/null 2>&1 && read_env_value_from_file "$2" "$3"' \
        _ "$INSTALL_DIR" "$1" "$2" 2>/dev/null \
        || grep "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2-
}

# Injection-safe upsert into the staging file: the value travels through awk's
# ENVIRON, never through a program string, so |, &, \ or quotes cannot corrupt
# it. Written under umask 077 so secrets never touch a world-readable file.
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

# Same generator as scripts/rotate-password.sh, so fresh installs and
# rotations share one password policy; a fallback that changes the policy
# says so rather than downgrading silently.
gen_password() {
    local secret=""
    secret="$(sh -c '. "$1/scripts/lib.sh" >/dev/null 2>&1 && generate_secret' _ "$INSTALL_DIR" 2>/dev/null || true)"
    if [ -z "$secret" ]; then
        log "WARNING: scripts/lib.sh generate_secret unavailable; falling back to a 24-character random password"
        secret="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    fi
    [ "${#secret}" -ge 24 ] || die "could not generate a password (got ${#secret} characters)"
    printf '%s' "$secret"
}

# The Makefile owns the required-variable list (enforced by check-env). Tokens
# are validated because they are eval'd as variable names below.
# shellcheck disable=SC1003 # '\' is a literal backslash pattern, not an escaped quote
read_required_vars() {
    local raw="" var="" out=""

    raw="$(sed -n 's/^REQUIRED_ENV_VARS[[:space:]]*:=[[:space:]]*//p' "$INSTALL_DIR/Makefile" | head -n1)"
    case "$raw" in
        *'\') die "REQUIRED_ENV_VARS spans several lines in $INSTALL_DIR/Makefile; this installer cannot read it" ;;
    esac
    for var in $raw; do
        case "$var" in
            '#'*) break ;;
            *[!A-Z0-9_]* | '') die "unexpected token '$var' in the Makefile's REQUIRED_ENV_VARS" ;;
        esac
        out="$out $var"
    done
    [ -n "$out" ] || die "could not read REQUIRED_ENV_VARS from $INSTALL_DIR/Makefile"
    printf '%s' "$out"
}

ask_required() {
    local var="$1" label="" default="" secret=""

    case "$var" in
        HOST_NAME) label="Domain name (e.g. pi.example.com)" ;;
        EMAIL) label="Admin email address" ;;
        ADMIN_USER)
            label="Admin username"
            default="admin"
            ;;
        PASSWORD)
            label="Admin password (Enter = generate one)"
            default="$GENERATED_PASSWORD"
            secret=1
            ;;
        TIMEZONE)
            label="Timezone"
            default="$DETECTED_TZ"
            ;;
        HOST_LAN_IP)
            label="Static LAN IP of this machine (a changing DHCP lease breaks Headscale and local DNS)"
            default="$DETECTED_IP"
            ;;
        CLOUDFLARE_DNS_API_TOKEN)
            label="Cloudflare API token (DNS edit on your zone)"
            secret=1
            ;;
        CLOUDFLARE_ZONE_ID) label="Cloudflare zone ID" ;;
        *) label="$var" ;;
    esac
    ask "$var" "$label" "$default" "$secret"
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

# Asked of the kernel rather than guessed from the name (bridges over Wi-Fi,
# renamed interfaces): macvlan, which gives Pi-hole its LAN address, does not
# work over Wi-Fi.
is_wireless() {
    [ -d "/sys/class/net/$1/wireless" ] || [ -e "/sys/class/net/$1/phy80211" ]
}

# Exported values win over detection, mirroring the prompt contract. Resolved
# before any prompt so an abort here cannot discard typed credentials.
resolve_network() {
    detect_network
    LAN_PARENT="${HOST_LAN_PARENT:-$DETECTED_IFACE}"
    LAN_SUBNET="${HOST_LAN_SUBNET:-$DETECTED_SUBNET}"
    LAN_GATEWAY="${HOST_LAN_GATEWAY:-$DETECTED_GATEWAY}"

    if [ -z "$LAN_PARENT" ] || [ -z "$LAN_SUBNET" ] || [ -z "$LAN_GATEWAY" ]; then
        log "Could not determine the LAN layout (interface/subnet/gateway)"
        if interactive && confirm "Continue with the 192.168.1.0/24 defaults from .env.dist (and fix .env afterwards)?"; then
            log "WARNING: review HOST_LAN_*, ALLOW_IP_RANGES and PIHOLE_IP in .env — a wrong LAN range locks every client out"
            return 0
        fi
        die "no usable network layout: export HOST_LAN_PARENT, HOST_LAN_SUBNET and HOST_LAN_GATEWAY (plus PIHOLE_IP), then re-run"
    fi

    if is_wireless "$LAN_PARENT"; then
        log "WARNING: $LAN_PARENT is a Wi-Fi interface; macvlan (Pi-hole's LAN address) does not work over Wi-Fi"
        if interactive; then
            confirm "Continue with $LAN_PARENT anyway?" \
                || die "connect the machine over Ethernet, or export HOST_LAN_PARENT, then re-run"
        fi
    fi
}

# Rebuilt member by member: the fixed entries (loopback, VPN, Docker) stay
# owned by .env.dist, and a missing LAN member is an error rather than a
# silent no-op. No sed interpolation (a CIDR is full of regex metacharacters).
build_allow_ip_ranges() {
    RANGES="$1" DIST_LAN="$2" LAN="$3" awk 'BEGIN {
        count = split(ENVIRON["RANGES"], members, ",")
        out = ""
        replaced = 0
        for (i = 1; i <= count; i++) {
            member = members[i]
            if (member == ENVIRON["DIST_LAN"]) {
                member = ENVIRON["LAN"]
                replaced = 1
            }
            out = (out == "" ? member : out "," member)
        }
        if (!replaced) exit 1
        print out
    }'
}

# .250 by convention (the .env.dist default), stepping down when it would
# collide with the host itself or the gateway.
pick_pihole_ip() {
    local prefix="$1" octet="" candidate=""
    for octet in 250 249 248 247; do
        candidate="$prefix.$octet"
        [ "$candidate" != "${HOST_LAN_IP:-}" ] || continue
        [ "$candidate" != "$LAN_GATEWAY" ] || continue
        printf '%s' "$candidate"
        return 0
    done
    return 1
}

write_network_settings() {
    local dist_ranges="" dist_lan="" ranges="" pihole_ip=""

    [ -z "$LAN_PARENT" ] || set_env HOST_LAN_PARENT "$LAN_PARENT"
    [ -z "$LAN_SUBNET" ] || set_env HOST_LAN_SUBNET "$LAN_SUBNET"
    [ -z "$LAN_GATEWAY" ] || set_env HOST_LAN_GATEWAY "$LAN_GATEWAY"
    [ -n "$LAN_SUBNET" ] || return 0

    if [ -n "${ALLOW_IP_RANGES:-}" ]; then
        set_env ALLOW_IP_RANGES "$ALLOW_IP_RANGES"
    else
        dist_ranges="$(read_env_key "$INSTALL_DIR/.env.dist" ALLOW_IP_RANGES)"
        dist_lan="$(read_env_key "$INSTALL_DIR/.env.dist" HOST_LAN_SUBNET)"
        if ranges="$(build_allow_ip_ranges "$dist_ranges" "$dist_lan" "$LAN_SUBNET")"; then
            set_env ALLOW_IP_RANGES "$ranges"
        else
            die "the ALLOW_IP_RANGES default in .env.dist no longer contains the LAN subnet ($dist_lan); export ALLOW_IP_RANGES and re-run"
        fi
    fi

    if [ -n "${PIHOLE_IP:-}" ]; then
        set_env PIHOLE_IP "$PIHOLE_IP"
        return 0
    fi
    case "$LAN_SUBNET" in
        *.0/24)
            pihole_ip="$(pick_pihole_ip "${LAN_SUBNET%.0/24}")" \
                || die "no free address left for Pi-hole in $LAN_SUBNET; export PIHOLE_IP and re-run"
            set_env PIHOLE_IP "$pihole_ip"
            ;;
        *)
            if interactive; then
                log "Pi-hole needs a free static address inside $LAN_SUBNET (outside your router's DHCP range)"
                ask PIHOLE_IP "Pi-hole IP" ""
                set_env PIHOLE_IP "$PIHOLE_IP"
            else
                die "non-/24 subnet ($LAN_SUBNET): export PIHOLE_IP with a free address inside it and re-run"
            fi
            ;;
    esac
}

configure_env() {
    if [ -f "$ENV_FILE" ]; then
        log "Keeping existing $ENV_FILE"
        return 0
    fi
    # Set only after the early return above: the EXIT trap removes
    # "$ENV_STAGE"*, and the keep-existing-.env path must not delete a
    # user's own .env.tmp file.
    ENV_STAGE="$ENV_FILE.tmp"
    rm -f "$ENV_STAGE" "$ENV_STAGE.new"

    local required_vars="" var="" value=""
    required_vars="$(read_required_vars)"

    # Everything that can abort runs before the first prompt, so a refused
    # confirmation never discards typed credentials.
    resolve_network

    DETECTED_TZ=""
    if [ -z "${TIMEZONE:-}" ]; then
        DETECTED_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)"
        [ -n "$DETECTED_TZ" ] || DETECTED_TZ="Etc/UTC"
    fi
    GENERATED_PASSWORD=""
    [ -n "${PASSWORD:-}" ] || GENERATED_PASSWORD="$(gen_password)"

    log "Configuring $ENV_FILE (press Enter to accept a [default])"
    for var in $required_vars; do
        ask_required "$var"
    done

    cp "$INSTALL_DIR/.env.dist" "$ENV_STAGE"
    chmod 600 "$ENV_STAGE"
    for var in $required_vars; do
        eval "value=\${$var:-}"
        set_env "$var" "$value"
    done
    write_network_settings
    mv "$ENV_STAGE" "$ENV_FILE"
    ENV_STAGE=""

    if [ -n "$GENERATED_PASSWORD" ] && [ "${PASSWORD:-}" = "$GENERATED_PASSWORD" ]; then
        log "A password was generated and stored as PASSWORD in $ENV_FILE (not displayed)"
    fi
    log "Optional settings (SMTP, S3 backups, language) can be filled in $ENV_FILE later"
}

check_privileges() {
    if [ "$(id -u)" -eq 0 ]; then
        log "WARNING: running as root; prefer a regular account (sudo is requested only where needed)"
        SUDO=""
        return 0
    fi
    have sudo || die "sudo is required: 'make install' applies sysctl, /etc/hosts and systemd changes"
    if ! interactive && ! sudo -n true 2>/dev/null; then
        die "unattended installs need passwordless sudo ('make install' applies sysctl, /etc/hosts and systemd changes)"
    fi
}

main() {
    have curl || die "curl is required"
    check_privileges
    ensure_base_tools
    ensure_docker
    resolve_install_dir
    clone_or_update
    ENV_FILE="$INSTALL_DIR/.env"
    configure_env

    cd "$INSTALL_DIR"
    local host_name="" pihole_ip=""
    pihole_ip="$(read_env_key "$ENV_FILE" PIHOLE_IP)"
    [ -z "$pihole_ip" ] || log "Pi-hole will claim $pihole_ip — make sure it sits outside your router's DHCP range (edit PIHOLE_IP in .env now if not)"

    log "Running preflight checks..."
    make preflight
    log "Installing (sudo will be requested for systemd/sysctl setup)..."
    make install

    host_name="$(read_env_key "$ENV_FILE" HOST_NAME)"
    log "Installation complete. First startup takes a few minutes (make logs to watch)."
    log "Next: create users at https://lldap.${host_name:-<HOST_NAME>} then sign in at https://auth.${host_name:-<HOST_NAME>}"
    log "See docs/INSTALLATION.md (First Login) for the remaining one-time steps."
}

main "$@"
