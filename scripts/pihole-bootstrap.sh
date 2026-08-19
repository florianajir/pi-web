#!/bin/sh
# Bootstrap Pi-hole: adds recommended block lists, allows the click-redirect
# domains they over-block, then updates gravity. Idempotent - lists and allows
# already present are skipped.

set -e

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=60
RETRY_INTERVAL=5
PIHOLE_CONTAINER="${PIHOLE_CONTAINER:-pi-pihole}"
PIHOLE_API="http://localhost:8082/api"

# Firebog's "ticked" lists, the low-false-positive set — https://firebog.net
# Groups: Base | Suspicious | Advertising | Tracking & Telemetry | Malicious
BLOCK_LISTS="
https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt
https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Spam/hosts
https://v.firebog.net/hosts/static/w3kbl.txt
https://adaway.org/hosts.txt
https://v.firebog.net/hosts/AdguardDNS.txt
https://v.firebog.net/hosts/Admiral.txt
https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt
https://v.firebog.net/hosts/Easylist.txt
https://raw.githubusercontent.com/FadeMind/hosts.extras/master/UncheckyAds/hosts
https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts
https://v.firebog.net/hosts/Easyprivacy.txt
https://v.firebog.net/hosts/Prigent-Ads.txt
https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.2o7Net/hosts
https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt
https://hostfiles.frogeye.fr/firstparty-trackers-hosts.txt
https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt
https://v.firebog.net/hosts/Prigent-Crypto.txt
https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Risk/hosts
https://phishing.army/download/phishing_army_blocklist_extended.txt
https://raw.githubusercontent.com/Spam404/lists/master/main-blacklist.txt
https://urlhaus.abuse.ch/downloads/hostfile/
"

# Click-redirect and CNAME collateral: domains the block lists catch as ad
# infrastructure, but which sit in the middle of a user-initiated navigation.
# Blocking them turns a click into a dead page rather than removing an ad.
# Each one below was verified present in gravity, most in several lists at once
# (including StevenBlack), so dropping lists cannot fix them — only an allow can.
ALLOW_LISTS="
g.msn.com
www.googleadservices.com
googleadservices.com
clickserve.dartsearch.net
awin1.com
go.redirectingat.com
click.linksynergy.com
s.click.aliexpress.com
trk.klclick.com
analytics.google.com
dit.whatsapp.net
"

# Inside the container: it ships curl, and there is no network hop to reach.
pihole_curl() {
    docker exec "$PIHOLE_CONTAINER" curl -sS "$@"
}

# The password goes in via a temp file so it never appears in process args or logs.
get_session() {
    local password="$1"
    local body_file response
    body_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f $body_file" EXIT
    printf '{"password":"%s"}' "$password" > "$body_file"
    response=$(docker exec -i "$PIHOLE_CONTAINER" curl -sS \
        -X POST \
        -H "Content-Type: application/json" \
        -d @- \
        "$PIHOLE_API/auth" < "$body_file")
    rm -f "$body_file"
    # Extract sid from {"session":{"sid":"VALUE",...}}
    printf '%s' "$response" | grep -o '"sid":"[^"]*"' | head -1 | cut -d'"' -f4
}

# Returns 0 if newly added, 1 if already present or on error.
add_list() {
    local sid="$1"
    local url="$2"
    local response http_code
    # type=block must be a query param, not in the JSON body
    response=$(pihole_curl \
        -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "sid: $sid" \
        -d "{\"address\":\"$url\",\"comment\":\"firebog\",\"enabled\":true}" \
        "$PIHOLE_API/lists?type=block" 2>&1)
    http_code=$(printf '%s' "$response" | tail -1)

    case "$http_code" in
        2*) log "Added: $url"; return 0 ;;
        *)  log "Already present or error (HTTP $http_code): $url"; return 1 ;;
    esac
}

# Exact, not regex: an allow is a hole in the filter, so it stays as narrow as the
# domain that was actually breaking. Returns 0 if newly added, 1 otherwise.
add_allow() {
    local sid="$1"
    local domain="$2"
    local http_code
    http_code=$(pihole_curl \
        -o /dev/null \
        -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "sid: $sid" \
        -d "{\"domain\":\"$domain\",\"comment\":\"click-redirect allow\",\"enabled\":true,\"groups\":[0]}" \
        "$PIHOLE_API/domains/allow/exact")
    case "$http_code" in
        2*) log "Allowed: $domain"; return 0 ;;
        *)  return 1 ;;
    esac
}

update_gravity() {
    local sid="$1"
    log "Updating gravity (downloading block lists, this may take a while)..."
    local http_code
    http_code=$(pihole_curl \
        -o /dev/null \
        -w "%{http_code}" \
        -X POST \
        -H "sid: $sid" \
        "$PIHOLE_API/action/gravity")
    if [ "${http_code#2}" != "$http_code" ]; then
        log "Gravity update triggered via API (runs in background)"
        return 0
    fi
    # Fallback for versions whose API action is unavailable.
    if docker exec "$PIHOLE_CONTAINER" pihole reloadlists >/dev/null 2>&1; then
        log "Lists reloaded via CLI"
        return 0
    fi
    log "WARNING: gravity update failed — run manually: docker exec $PIHOLE_CONTAINER pihole reloadlists"
}

main() {
    log "=== Pi-hole Bootstrap ==="

    wait_for_container "$PIHOLE_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL"
    wait_for_health "$PIHOLE_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL"

    local password
    password="$(get_env_value PASSWORD)"
    password="${password:-admin}"

    local sid
    sid=$(get_session "$password")
    if [ -z "$sid" ]; then
        die "Could not authenticate with Pi-hole API (check PASSWORD in .env)"
    fi
    log "Authenticated with Pi-hole API"

    local newly_added=0
    for url in $BLOCK_LISTS; do
        [ -z "$url" ] && continue
        if add_list "$sid" "$url"; then
            newly_added=$((newly_added + 1))
        fi
    done

    # Allow entries take effect on the next list reload, not on a gravity
    # rebuild, so they never need to trigger one on their own.
    for domain in $ALLOW_LISTS; do
        [ -z "$domain" ] && continue
        add_allow "$sid" "$domain" || true
    done

    if [ "$newly_added" -gt 0 ]; then
        log "$newly_added new list(s) added"
        update_gravity "$sid"
    else
        log "All block lists already present, skipping gravity update"
    fi

    log "Pi-hole block lists configured"
}

main "$@"
