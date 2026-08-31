#!/bin/sh
# Print the five values that open the off-site backup, as two sheets to cut
# apart and store in two different places.
#
# Why five values and not the whole .env: the S3 repository already holds .env
# at /userdata/pi-web-env/.env, so these five are the only thing that has to
# survive off the machine - and unlike .env, they change almost never. That
# turns "keep a large mutable secret file synced off-site" into "keep a few
# near-static strings on paper", which needs no tooling, no passphrase to
# remember, and no upload credential living on the machine being protected.
#
# Split across two sheets on purpose. Sheet A downloads the ciphertext, sheet B
# decrypts it; neither is useful alone, so one stolen sheet is not a breach.
# They are paired by a random code rather than by naming the service, so sheet
# B reads as a meaningless string to whoever finds it.
#
# Usage:
#   sh scripts/recovery-kit.sh [output-path] [--verify]
#
# --verify proves the five values actually open the repository, from a
# throwaway container with neither config.json nor .env mounted - the same
# conditions you would be restoring under. Do it at least once: a kit that has
# never been tested is a guess.
set -eu

. "$(dirname "$0")/lib.sh"

OUT=/tmp/pi-web-recovery-kit.txt
VERIFY=no
for arg in "$@"; do
    case "$arg" in
        --verify) VERIFY=yes ;;
        -*) die "unknown option: $arg" ;;
        *) OUT="$arg" ;;
    esac
done

# This file holds the keys to every secret in the stack.
umask 077

# The kit must not land anywhere that gets backed up: a recovery kit stored
# inside the thing it recovers is not a kit.
DATA_DIR="$(resolve_data_location_path)"
OUT_DIR="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd || echo "")"
[ -n "$OUT_DIR" ] || die "directory for $OUT does not exist"
case "$OUT_DIR/" in
    "$PROJECT_DIR"/* | "${DATA_DIR%/}"/*)
        die "refusing to write the kit under $PROJECT_DIR or ${DATA_DIR%/}: it would be swept into the backup it exists to recover. Use a path under /tmp."
        ;;
esac

URI="$(get_env_value BACKREST_S3_URI)"
if [ -z "$URI" ]; then
    endpoint="$(get_env_value S3_ENDPOINT)"
    bucket="$(get_env_value S3_BUCKET)"
    if [ -n "$endpoint" ] && [ -n "$bucket" ]; then
        URI="s3:${endpoint}/${bucket}/restic"
    fi
fi
REGION="$(get_env_value S3_REGION)"
[ -n "$REGION" ] || REGION=fr-par
AK="$(get_env_value S3_ACCESS_KEY_ID)"
[ -n "$AK" ] || AK="$(get_env_value BACKREST_S3_ACCESS_KEY_ID)"
SK="$(get_env_value S3_SECRET_ACCESS_KEY)"
[ -n "$SK" ] || SK="$(get_env_value BACKREST_S3_SECRET_ACCESS_KEY)"
PW="$(get_env_value BACKREST_S3_REPO_PASSWORD)"

[ -n "$URI" ] || die "BACKREST_S3_URI is empty and cannot be derived from S3_ENDPOINT/S3_BUCKET"
[ -n "$AK" ]  || die "S3_ACCESS_KEY_ID is empty in .env"
[ -n "$SK" ]  || die "S3_SECRET_ACCESS_KEY is empty in .env"
[ -n "$PW" ]  || die "BACKREST_S3_REPO_PASSWORD is empty in .env"

# Backrest reads config.json, not .env, so a divergence means the sheet would
# carry values the running backup does not use. That drift is silent, and it
# would only surface on the day the kit is needed.
CONFIG="$PROJECT_DIR/config/backrest/config.json"
if [ -r "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
    c_uri="$(jq -r '.repos[]|select(.id=="s3")|.uri // empty' "$CONFIG" 2>/dev/null || true)"
    c_pw="$(jq -r '.repos[]|select(.id=="s3")|.password // empty' "$CONFIG" 2>/dev/null || true)"
    c_ak="$(jq -r '.repos[]|select(.id=="s3")|.env[]?|select(startswith("AWS_ACCESS_KEY_ID="))|sub("^[^=]*=";"")' "$CONFIG" 2>/dev/null || true)"
    drift=""
    [ "$c_uri" = "$URI" ] || drift="$drift uri"
    [ "$c_pw" = "$PW" ] || drift="$drift password"
    [ "$c_ak" = "$AK" ] || drift="$drift access-key"
    if [ -n "$drift" ]; then
        log "WARNING: .env and config.json disagree on:$drift"
        log "WARNING: Backrest uses config.json. Reconcile them before trusting this sheet."
    else
        log "checked: .env and config.json agree"
    fi
fi

if [ "$VERIFY" = yes ]; then
    if command -v docker >/dev/null 2>&1 && docker image inspect pi-backrest:local >/dev/null 2>&1; then
        log "verifying the five values against the live repository (nothing mounted)..."
        if docker run --rm --entrypoint sh \
            -e RESTIC_REPOSITORY="$URI" \
            -e RESTIC_PASSWORD="$PW" \
            -e AWS_ACCESS_KEY_ID="$AK" \
            -e AWS_SECRET_ACCESS_KEY="$SK" \
            -e AWS_DEFAULT_REGION="$REGION" \
            pi-backrest:local -c 'restic snapshots --latest 1 >/dev/null 2>&1'; then
            log "verified: these five values open the repository on their own"
        else
            die "the five values did NOT open the repository - do not print this sheet"
        fi
    else
        log "WARNING: docker or the pi-backrest:local image is unavailable; skipping verification"
    fi
fi

CODE="PW-$(LC_ALL=C tr -dc 'A-Z0-9' </dev/urandom | head -c4)"
TODAY="$(date +%Y-%m-%d)"

cat > "$OUT" <<EOF
================================================================================
  FEUILLE A  --  ACCES AU STOCKAGE                    etabli le $TODAY
================================================================================

  Sauvegarde du serveur familial. Cette feuille permet de TELECHARGER
  l'archive, pas de la LIRE. Le mot de passe de dechiffrement est sur une
  seconde feuille, rangee ailleurs, portant le code $CODE.
  Il faut les deux.

  Depot        $URI
  Region       $REGION
  Cle d'acces  $AK
  Cle secrete  $SK

--------------------------------------------------------------------------------
  QUOI FAIRE  --  depuis n'importe quel ordinateur, apres avoir installe
  restic (https://restic.net) :

    export RESTIC_REPOSITORY="$URI"
    export AWS_ACCESS_KEY_ID="$AK"
    export AWS_SECRET_ACCESS_KEY="$SK"
    export AWS_DEFAULT_REGION="$REGION"
    export RESTIC_PASSWORD="<le mot de passe de la feuille $CODE>"

    restic snapshots                         # verifier que ca repond
    restic restore latest --target /tmp/r     # tout restaurer (~243 Go)

  Pour repartir vite, un seul fichier suffit : il contient tous les autres
  mots de passe du systeme.

    restic restore latest --target /tmp/r --include /userdata/pi-web-env
    # ressort dans  /tmp/r/userdata/pi-web-env/.env

--------------------------------------------------------------------------------
  A SAVOIR

  - Ces valeurs ne changent quasiment jamais. Apres une rotation de la cle S3
    ou du mot de passe du depot, regenerer et REIMPRIMER cette feuille :
        sh scripts/recovery-kit.sh --verify
  - Ne pas ranger cette feuille au meme endroit que la feuille $CODE.
  - Une fois par an, verifier que 'restic snapshots' repond encore.

================================================================================




%%%%%%%%%%%%%%%%%%%%%  DECOUPER ICI -- RANGER AILLEURS  %%%%%%%%%%%%%%%%%%%%%%%%




================================================================================
  $CODE
================================================================================

    $PW

  Cette chaine est la seconde moitie d'un jeu de deux. Seule, elle n'ouvre
  rien et ne designe rien. L'autre feuille indique quoi en faire.

  Ne pas ranger au meme endroit que l'autre feuille.

================================================================================
EOF

chmod 600 "$OUT"
log "kit written to $OUT"
log "pairing code: $CODE"
log ""
log "Next: print it, cut along the %%%% line, store the two halves in two"
log "different places, then remove the file:  shred -u $OUT"
