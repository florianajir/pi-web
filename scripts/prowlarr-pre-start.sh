#!/bin/sh
# Pre-start: render Prowlarr config.xml from template on fresh installs.
# Auth is delegated to the reverse proxy (Authelia) via AuthenticationMethod=External,
# so there is no first-run wizard and no double login. A stable API key is generated
# once and lives in config.xml (single source of truth, reused by the bootstrap).
# Writes the config only if it does not yet exist, preserving runtime edits.
# A pre-start hook (scripts/stack-up.sh), so it runs before docker compose up.

set -eu

. "$(dirname "$0")/lib.sh"

PROWLARR_CONFIG_TEMPLATE="$PROJECT_DIR/config/prowlarr/config.xml.template"

main() {
    local data_location config_dir config_file api_key

    data_location="$(resolve_data_location_path)"
    config_dir="$data_location/prowlarr"
    config_file="$config_dir/config.xml"

    # -s, not -f: an empty config.xml left by an earlier failed render must be
    # regenerated, not accepted forever — Prowlarr would boot with defaults
    # (no AuthenticationMethod=External) and the two scripts that scrape the
    # API key out of this file would come up empty.
    if [ -s "$config_file" ]; then
        log "Config already exists at $config_file, skipping"
        return 0
    fi

    [ -f "$PROWLARR_CONFIG_TEMPLATE" ] || die "Prowlarr config template not found at $PROWLARR_CONFIG_TEMPLATE"

    # Prowlarr API keys are 32-char hex; trim the 64-char lib default.
    api_key="$(generate_secret | cut -c1-32)"
    [ -n "$api_key" ] || die "Failed to generate Prowlarr API key"

    mkdir -p "$config_dir"

    render_config() {
        sed -e "s|__API_KEY__|$(sed_escape "$api_key")|g" "$PROWLARR_CONFIG_TEMPLATE"
    }
    write_file_atomic "$config_file" render_config || die "Failed to render $config_file"

    # linuxserver's s6 init chowns /config to PUID:PGID on start, but make the file
    # readable by the project owner too (root-run systemd start otherwise leaves root:root).
    fix_ownership "$config_dir"

    log "Rendered Prowlarr config to $config_file"
}

main "$@"
