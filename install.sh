#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="florianajir"
REPO_NAME="pi-web"
DEFAULT_REPO="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"

log() {
	printf '➡️  %s\n' "$*"
}

success() {
	printf '✅ %s\n' "$*"
}

warn() {
	printf '⚠️  %s\n' "$*" >&2
}

die() {
	printf '❌ %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage: install.sh [--dir PATH] [--repo URL] [--ref BRANCH] [--non-interactive] [--skip-preflight] [--skip-install]

Clone or refresh pi-web, prepare .env, then run make preflight and make install.

Options:
  --dir PATH           Target checkout directory (default: current repo or ~/pi-web)
  --repo URL           Git remote to clone from
  --ref BRANCH         Git ref to checkout
  --non-interactive    Disable prompts; rely on existing .env values or PI_WEB_* overrides
  --skip-preflight     Skip make preflight
  --skip-install       Stop after repository + .env preparation
  -h, --help           Show this help

Environment overrides:
  PI_WEB_DIR, PI_WEB_REPO, PI_WEB_REF
  PI_WEB_NONINTERACTIVE=1
  PI_WEB_SKIP_PREFLIGHT=1
  PI_WEB_SKIP_INSTALL=1

  PI_WEB_HOST_NAME
  PI_WEB_TIMEZONE
  PI_WEB_EMAIL
  PI_WEB_ADMIN_USER
  PI_WEB_ADMIN_PASSWORD
  PI_WEB_HOST_LAN_IP
  PI_WEB_HOST_LAN_PARENT
  PI_WEB_HOST_LAN_SUBNET
  PI_WEB_HOST_LAN_GATEWAY
  PI_WEB_CLOUDFLARE_DNS_API_TOKEN
  PI_WEB_CLOUDFLARE_ZONE_ID
EOF
}

home_dir_for_default() {
	local sudo_home=""

	if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && command -v getent >/dev/null 2>&1; then
		sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | awk -F: '{print $6}')"
		if [[ -n "$sudo_home" ]]; then
			printf '%s\n' "$sudo_home"
			return
		fi
	fi

	printf '%s\n' "${HOME:-$PWD}"
}

resolve_default_dir() {
	if [[ -f "$PWD/Makefile" && -f "$PWD/compose.yaml" && -f "$PWD/.env.dist" ]]; then
		printf '%s\n' "$PWD"
		return
	fi

	printf '%s/pi-web\n' "$(home_dir_for_default)"
}

PI_WEB_REPO="${PI_WEB_REPO:-$DEFAULT_REPO}"
PI_WEB_REF="${PI_WEB_REF:-main}"
PI_WEB_NONINTERACTIVE="${PI_WEB_NONINTERACTIVE:-0}"
PI_WEB_SKIP_PREFLIGHT="${PI_WEB_SKIP_PREFLIGHT:-0}"
PI_WEB_SKIP_INSTALL="${PI_WEB_SKIP_INSTALL:-0}"
PI_WEB_DIR="${PI_WEB_DIR:-$(resolve_default_dir)}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dir)
			[[ $# -ge 2 ]] || die "--dir requires a value"
			PI_WEB_DIR="$2"
			shift 2
			;;
		--repo)
			[[ $# -ge 2 ]] || die "--repo requires a value"
			PI_WEB_REPO="$2"
			shift 2
			;;
		--ref)
			[[ $# -ge 2 ]] || die "--ref requires a value"
			PI_WEB_REF="$2"
			shift 2
			;;
		--non-interactive)
			PI_WEB_NONINTERACTIVE=1
			shift
			;;
		--skip-preflight)
			PI_WEB_SKIP_PREFLIGHT=1
			shift
			;;
		--skip-install)
			PI_WEB_SKIP_INSTALL=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "Unknown option: $1"
			;;
	esac
done

INTERACTIVE=0
if [[ "$PI_WEB_NONINTERACTIVE" != "1" && -r /dev/tty && -w /dev/tty ]]; then
	INTERACTIVE=1
fi

require_cmd() {
	local cmd="$1"
	local hint="$2"

	command -v "$cmd" >/dev/null 2>&1 || die "$hint"
}

require_compose() {
	if ! command -v docker >/dev/null 2>&1; then
		die "Docker is required. Install Docker Engine + Docker Compose, then rerun the installer."
	fi

	if ! docker compose version >/dev/null 2>&1; then
		die "Docker Compose plugin is required. Install it, then rerun the installer."
	fi
}

detect_timezone() {
	local tz=""

	if command -v timedatectl >/dev/null 2>&1; then
		tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
	fi

	if [[ -z "$tz" && -f /etc/timezone ]]; then
		tz="$(tr -d '[:space:]' < /etc/timezone)"
	fi

	if [[ -z "$tz" && -L /etc/localtime ]]; then
		tz="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
	fi

	printf '%s' "${tz:-UTC}"
}

detect_default_interface() {
	ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

detect_host_ip() {
	ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

detect_gateway() {
	ip route show default 2>/dev/null | awk '/default/ {for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}'
}

detect_subnet() {
	local iface="$1"

	if [[ -z "$iface" ]]; then
		return 0
	fi

	ip -o -f inet addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}'
}

prompt_plain() {
	local label="$1"
	local default_value="${2:-}"
	local reply=""

	if [[ "$INTERACTIVE" != "1" ]]; then
		printf '%s' "$default_value"
		return
	fi

	if [[ -n "$default_value" ]]; then
		printf '%s [%s]: ' "$label" "$default_value" > /dev/tty
	else
		printf '%s: ' "$label" > /dev/tty
	fi

	IFS= read -r reply < /dev/tty || true
	printf '%s' "${reply:-$default_value}"
}

prompt_secret() {
	local label="$1"
	local default_value="${2:-}"
	local reply=""

	if [[ "$INTERACTIVE" != "1" ]]; then
		printf '%s' "$default_value"
		return
	fi

	if [[ -n "$default_value" ]]; then
		printf '%s [leave blank to keep current]: ' "$label" > /dev/tty
	else
		printf '%s: ' "$label" > /dev/tty
	fi

	IFS= read -r -s reply < /dev/tty || true
	printf '\n' > /dev/tty
	printf '%s' "${reply:-$default_value}"
}

generate_password() {
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex 16
		return
	fi

	od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

env_override_for() {
	case "$1" in
		HOST_NAME) printf '%s' "${PI_WEB_HOST_NAME:-}" ;;
		TIMEZONE) printf '%s' "${PI_WEB_TIMEZONE:-}" ;;
		EMAIL) printf '%s' "${PI_WEB_EMAIL:-}" ;;
		USER) printf '%s' "${PI_WEB_ADMIN_USER:-}" ;;
		PASSWORD) printf '%s' "${PI_WEB_ADMIN_PASSWORD:-}" ;;
		HOST_LAN_IP) printf '%s' "${PI_WEB_HOST_LAN_IP:-}" ;;
		HOST_LAN_PARENT) printf '%s' "${PI_WEB_HOST_LAN_PARENT:-}" ;;
		HOST_LAN_SUBNET) printf '%s' "${PI_WEB_HOST_LAN_SUBNET:-}" ;;
		HOST_LAN_GATEWAY) printf '%s' "${PI_WEB_HOST_LAN_GATEWAY:-}" ;;
		CLOUDFLARE_DNS_API_TOKEN) printf '%s' "${PI_WEB_CLOUDFLARE_DNS_API_TOKEN:-}" ;;
		CLOUDFLARE_ZONE_ID) printf '%s' "${PI_WEB_CLOUDFLARE_ZONE_ID:-}" ;;
		*) printf '' ;;
	esac
}

get_env_var() {
	local file="$1"
	local key="$2"

	awk -v k="$key" 'index($0, k "=") == 1 {sub(/^[^=]*=/, "", $0); value = $0} END {print value}' "$file"
}

set_env_var() {
	local file="$1"
	local key="$2"
	local value="$3"
	local tmp_file

	tmp_file="$(mktemp)"
	awk -v k="$key" -v v="$value" '
		BEGIN { updated = 0 }
		index($0, k "=") == 1 {
			if (!updated) {
				print k "=" v
				updated = 1
			}
			next
		}
		{ print }
		END {
			if (!updated) {
				print k "=" v
			}
		}
	' "$file" > "$tmp_file"
	mv "$tmp_file" "$file"
}

clone_or_refresh_repo() {
	if [[ -d "$PI_WEB_DIR/.git" ]]; then
		if [[ ! -f "$PI_WEB_DIR/Makefile" || ! -f "$PI_WEB_DIR/compose.yaml" || ! -f "$PI_WEB_DIR/.env.dist" ]]; then
			die "Existing checkout does not look like pi-web: $PI_WEB_DIR"
		fi

		log "Using existing pi-web checkout in $PI_WEB_DIR"

		if [[ -n "$(git -C "$PI_WEB_DIR" status --porcelain 2>/dev/null || true)" ]]; then
			warn "Local changes detected; skipping git refresh."
			return
		fi

		log "Refreshing checkout from $PI_WEB_REPO ($PI_WEB_REF)"
		if git -C "$PI_WEB_DIR" fetch "$PI_WEB_REPO" "$PI_WEB_REF" >/dev/null 2>&1; then
			git -C "$PI_WEB_DIR" checkout -q -B "$PI_WEB_REF" FETCH_HEAD
			git -C "$PI_WEB_DIR" reset --hard FETCH_HEAD >/dev/null
			success "Repository updated"
		else
			warn "Could not refresh repository; continuing with existing checkout."
		fi
		return
	fi

	if [[ -e "$PI_WEB_DIR" && -n "$(find "$PI_WEB_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]]; then
		die "Target directory exists and is not an empty pi-web checkout: $PI_WEB_DIR"
	fi

	mkdir -p "$(dirname "$PI_WEB_DIR")"
	log "Cloning pi-web into $PI_WEB_DIR"
	git clone --branch "$PI_WEB_REF" "$PI_WEB_REPO" "$PI_WEB_DIR"
	success "Repository cloned"
}

prepare_env_file() {
	local env_file="$PI_WEB_DIR/.env"

	if [[ -f "$env_file" ]]; then
		return
	fi

	[[ -f "$PI_WEB_DIR/.env.dist" ]] || die "Missing $PI_WEB_DIR/.env.dist"
	cp "$PI_WEB_DIR/.env.dist" "$env_file"
	success "Created $env_file from .env.dist"
}

configure_env() {
	local env_file="$PI_WEB_DIR/.env"
	local detected_timezone detected_ip detected_iface detected_gateway detected_subnet
	local generated_password=""
	local value=""
	local current=""

	detected_timezone="$(detect_timezone)"
	detected_iface="$(detect_default_interface)"
	detected_ip="$(detect_host_ip)"
	detected_gateway="$(detect_gateway)"
	detected_subnet="$(detect_subnet "$detected_iface")"

	current="$(get_env_var "$env_file" HOST_NAME)"
	value="$(env_override_for HOST_NAME)"
	value="${value:-$current}"
	value="$(prompt_plain "Base domain (services live at <service>.<HOST_NAME>)" "$value")"
	set_env_var "$env_file" HOST_NAME "$value"

	current="$(get_env_var "$env_file" TIMEZONE)"
	value="$(env_override_for TIMEZONE)"
	value="${value:-${current:-$detected_timezone}}"
	value="$(prompt_plain "Timezone" "$value")"
	set_env_var "$env_file" TIMEZONE "$value"

	current="$(get_env_var "$env_file" EMAIL)"
	value="$(env_override_for EMAIL)"
	value="${value:-$current}"
	value="$(prompt_plain "Admin email" "$value")"
	set_env_var "$env_file" EMAIL "$value"

	current="$(get_env_var "$env_file" USER)"
	value="$(env_override_for USER)"
	value="${value:-${current:-admin}}"
	value="$(prompt_plain "Admin username" "$value")"
	set_env_var "$env_file" USER "$value"

	current="$(get_env_var "$env_file" PASSWORD)"
	value="$(env_override_for PASSWORD)"
	value="${value:-$current}"
	value="$(prompt_secret "Admin password" "$value")"
	if [[ -z "$value" ]]; then
		value="$(generate_password)"
		generated_password="$value"
	fi
	set_env_var "$env_file" PASSWORD "$value"

	current="$(get_env_var "$env_file" HOST_LAN_IP)"
	value="$(env_override_for HOST_LAN_IP)"
	value="${value:-${current:-$detected_ip}}"
	value="$(prompt_plain "Host LAN IP" "$value")"
	set_env_var "$env_file" HOST_LAN_IP "$value"

	current="$(get_env_var "$env_file" HOST_LAN_PARENT)"
	value="$(env_override_for HOST_LAN_PARENT)"
	value="${value:-${current:-${detected_iface:-eth0}}}"
	set_env_var "$env_file" HOST_LAN_PARENT "$value"

	current="$(get_env_var "$env_file" HOST_LAN_SUBNET)"
	value="$(env_override_for HOST_LAN_SUBNET)"
	value="${value:-${current:-$detected_subnet}}"
	set_env_var "$env_file" HOST_LAN_SUBNET "$value"

	current="$(get_env_var "$env_file" HOST_LAN_GATEWAY)"
	value="$(env_override_for HOST_LAN_GATEWAY)"
	value="${value:-${current:-$detected_gateway}}"
	set_env_var "$env_file" HOST_LAN_GATEWAY "$value"

	current="$(get_env_var "$env_file" CLOUDFLARE_DNS_API_TOKEN)"
	value="$(env_override_for CLOUDFLARE_DNS_API_TOKEN)"
	value="${value:-$current}"
	value="$(prompt_secret "Cloudflare DNS API token" "$value")"
	set_env_var "$env_file" CLOUDFLARE_DNS_API_TOKEN "$value"

	current="$(get_env_var "$env_file" CLOUDFLARE_ZONE_ID)"
	value="$(env_override_for CLOUDFLARE_ZONE_ID)"
	value="${value:-$current}"
	value="$(prompt_plain "Cloudflare zone ID" "$value")"
	set_env_var "$env_file" CLOUDFLARE_ZONE_ID "$value"

	local missing=()
	local required_keys=(HOST_NAME TIMEZONE EMAIL USER PASSWORD HOST_LAN_IP CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_ZONE_ID)
	local key=""

	for key in "${required_keys[@]}"; do
		if [[ -z "$(get_env_var "$env_file" "$key")" ]]; then
			missing+=("$key")
		fi
	done

	if (( ${#missing[@]} > 0 )); then
		printf 'Missing required settings in %s:\n' "$env_file" >&2
		printf '  - %s\n' "${missing[@]}" >&2
		die "Rerun interactively or set the matching PI_WEB_* environment overrides."
	fi

	success "Saved configuration to $env_file"

	if [[ -n "$generated_password" ]]; then
		warn "Generated admin password: $generated_password"
		warn "It is stored in $env_file — keep it somewhere safe."
	fi
}

run_make_target() {
	local target="$1"

	log "Running make $target"
	if ! (cd "$PI_WEB_DIR" && make "$target"); then
		die "make $target failed. Fix the issue above and rerun the installer."
	fi
}

maybe_request_sudo() {
	if [[ "$PI_WEB_SKIP_INSTALL" == "1" ]]; then
		return
	fi

	if [[ "$(id -u)" -eq 0 ]]; then
		return
	fi

	require_cmd sudo "sudo is required for systemd and sysctl setup. Install it or rerun as root."
	log "Requesting sudo access for systemd and sysctl setup"
	sudo -v
}

require_cmd git "git is required. Install it first (for example: sudo apt install git)."
require_cmd make "make is required. Install it first (for example: sudo apt install make)."
require_cmd ip "iproute2 is required. Install it first (for example: sudo apt install iproute2)."

if [[ "$PI_WEB_SKIP_PREFLIGHT" != "1" || "$PI_WEB_SKIP_INSTALL" != "1" ]]; then
	require_compose
fi

if [[ "$PI_WEB_SKIP_INSTALL" != "1" ]]; then
	require_cmd systemctl "systemd is required for pi-web installation."
fi

clone_or_refresh_repo
prepare_env_file
configure_env
maybe_request_sudo

if [[ "$PI_WEB_SKIP_PREFLIGHT" != "1" ]]; then
	run_make_target preflight
else
	warn "Skipping make preflight (--skip-preflight)"
fi

if [[ "$PI_WEB_SKIP_INSTALL" != "1" ]]; then
	run_make_target install
	success "pi-web is installed in $PI_WEB_DIR"
	printf '\nNext steps:\n'
	printf '  - Follow startup logs: cd %s && make logs\n' "$PI_WEB_DIR"
	printf '  - Check service status: cd %s && make status\n' "$PI_WEB_DIR"
	printf '  - Open the auth portal: https://auth.%s\n' "$(get_env_var "$PI_WEB_DIR/.env" HOST_NAME)"
else
	success "pi-web is ready in $PI_WEB_DIR"
	printf '\nNext steps:\n'
	printf '  - Review %s/.env\n' "$PI_WEB_DIR"
	printf '  - Run: cd %s && make preflight && make install\n' "$PI_WEB_DIR"
fi
