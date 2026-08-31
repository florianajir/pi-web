#!/bin/sh
# Renders BACKREST_AUTH_USER/BACKREST_AUTH_PASSWORD into config.json as a
# bcrypt user before handing off to the image's own entrypoint.
#
# This lives in the container, not in backrest-pre-start.sh, because the host
# has no bcrypt tool (no htpasswd, no python bcrypt) and the hash cannot be
# precomputed into a git-tracked template.
#
# Why it matters: Backrest's API returns the restic repo password and the S3
# access keys in cleartext to any unauthenticated caller, and pi-backrest
# shares the frontend network with ~22 other containers. Without a user here,
# any one of them can read the credentials and wipe the whole repository.
set -eu
umask 077

CONFIG="${BACKREST_CONFIG:-/config/backrest/config.json}"

log() { echo "[backrest-auth] $*" >&2; }

bootstrap_auth() {
  [ -n "${BACKREST_AUTH_USER:-}" ] || { log "BACKREST_AUTH_USER unset; leaving auth as configured"; return 0; }
  [ -n "${BACKREST_AUTH_PASSWORD:-}" ] || { log "BACKREST_AUTH_PASSWORD unset; leaving auth as configured"; return 0; }
  [ -f "$CONFIG" ] || { log "no config at $CONFIG yet; skipping"; return 0; }

  # Skip the rewrite when the stored hash already matches, so a restart does
  # not churn config.json (and its modno) on every boot. Look the user up by
  # name rather than at users[0]: extra users added through the UI are kept
  # (see the patch below), so ours is not necessarily first.
  current="$(jq -r --arg u "$BACKREST_AUTH_USER" \
    'first(.auth.users[]? | select(.name == $u) | .passwordBcrypt) // empty' \
    "$CONFIG" 2>/dev/null | base64 -d 2>/dev/null || true)"
  disabled="$(jq -r '.auth.disabled // false' "$CONFIG" 2>/dev/null || echo true)"
  if [ "$disabled" = "false" ] && [ -n "$current" ]; then
    verify="$(mktemp)"
    printf '%s:%s\n' "$BACKREST_AUTH_USER" "$current" > "$verify"
    if htpasswd -vb "$verify" "$BACKREST_AUTH_USER" "$BACKREST_AUTH_PASSWORD" >/dev/null 2>&1; then
      rm -f "$verify"
      log "auth already up to date for user '$BACKREST_AUTH_USER'"
      return 0
    fi
    rm -f "$verify"
  fi

  # htpasswd emits the $2y$ marker; Go's bcrypt only accepts $2a$/$2b$. The
  # digest itself is identical, so rewriting the marker is safe.
  hash="$(htpasswd -nbBC 10 "" "$BACKREST_AUTH_PASSWORD" | cut -d: -f2 | sed 's/^\$2y\$/\$2b\$/')"
  case "$hash" in
    '$2b$'*) ;;
    *) log "unexpected bcrypt output; leaving auth unchanged"; return 0 ;;
  esac

  # passwordBcrypt is a protobuf `bytes` field, so its JSON form is base64.
  encoded="$(printf '%s' "$hash" | base64 -w0)"

  # Update our user in place and leave every other entry alone: assigning the
  # whole .auth object would silently delete any extra user added through the
  # Backrest UI on the next container start.
  tmp="$(mktemp)"
  if jq --arg u "$BACKREST_AUTH_USER" --arg p "$encoded" \
       '.auth = (.auth // {})
        | .auth.disabled = false
        | .auth.users = (
            (.auth.users // []) as $users
            | if ($users | map(.name) | index($u)) then
                $users | map(if .name == $u then .passwordBcrypt = $p else . end)
              else
                $users + [{"name": $u, "passwordBcrypt": $p}]
              end
          )' \
       "$CONFIG" > "$tmp" && [ -s "$tmp" ]; then
    # cat, not mv: keep the existing inode so the bind mount stays intact.
    cat "$tmp" > "$CONFIG"
    log "auth enabled for user '$BACKREST_AUTH_USER'"
  else
    log "failed to patch auth into $CONFIG; leaving it unchanged"
  fi
  rm -f "$tmp"
}

bootstrap_auth || log "auth bootstrap failed; continuing so backups still run"

exec /docker-entrypoint "$@"
