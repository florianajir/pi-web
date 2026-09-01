#!/bin/sh
# Print the five values that open the off-site backup, as two sheets to cut
# apart and store in two different places.
#
# Why five values and not the whole .env: the S3 repository already holds .env
# at /userdata/pi-web-env/.env, so these five are the only thing that has to
# survive off the machine - and unlike .env, they change almost never. Keeping
# a few near-static strings on paper needs no tooling, no passphrase to
# remember, and no upload credential living on the machine being protected.
#
# Read from config.json, not .env: that is the file Backrest actually feeds to
# restic, so it is the operative truth. Taking it as the single source is why
# this script has no drift check - there is no second source to disagree with.
#
# Verification is not optional. It runs restic from a throwaway container with
# nothing mounted, which is the state you would really be restoring in, and it
# answers "are these the right values" directly. Every indirect check this
# script used to carry was a worse proxy for this one test.
set -eu

. "$(dirname "$0")/lib.sh"

# These are the keys to every secret in the stack.
umask 077

CONFIG="$PROJECT_DIR/config/backrest/config.json"
[ -r "$CONFIG" ] || die "cannot read $CONFIG - has the stack ever started?"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v docker >/dev/null 2>&1 || die "docker is required (verification is mandatory)"

repo="$(jq -ec '.repos[]|select(.id=="s3")' "$CONFIG")" || die "no 's3' repository in $CONFIG"
field() { printf '%s' "$repo" | jq -r "$1"; }
env_of() { field ".env[]?|select(startswith(\"$1=\"))|sub(\"^[^=]*=\";\"\")"; }

URI="$(field '.uri')"
PW="$(field '.password')"
AK="$(env_of AWS_ACCESS_KEY_ID)"
SK="$(env_of AWS_SECRET_ACCESS_KEY)"
RG="$(env_of AWS_DEFAULT_REGION)"
for f in "uri:$URI" "password:$PW" "AWS_ACCESS_KEY_ID:$AK" "AWS_SECRET_ACCESS_KEY:$SK"; do
    [ -n "${f#*:}" ] || die "the 's3' repository in $CONFIG has no ${f%%:*}"
done

# mktemp, not a fixed path: created atomically at 0600 under a name nobody can
# predict. That is the whole reason this script takes no output argument - a
# caller-supplied path needed a guard against landing inside the backup, and
# the guard was defeatable by a symlink.
ENVFILE="$(mktemp)"
trap 'rm -f "$ENVFILE"' EXIT INT TERM

# --env-file rather than -e: -e puts every secret in the host process table,
# readable by any local user through /proc/<pid>/cmdline for the length of the
# call.
printf 'RESTIC_REPOSITORY=%s\nRESTIC_PASSWORD=%s\nAWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nAWS_DEFAULT_REGION=%s\n' \
    "$URI" "$PW" "$AK" "$SK" "$RG" > "$ENVFILE"

log "verifying the five values against the live repository..."
if ! out="$(docker run --rm --env-file "$ENVFILE" --entrypoint restic \
        pi-backrest:local snapshots --latest 1 2>&1)"; then
    # Keep restic's message: a locked repo, a wrong region and a wrong password
    # all fail here, and this is the one place it matters which.
    die "the five values did NOT open the repository, so this sheet would be useless:
$out"
fi
log "verified: these five values open the repository on their own"

# Created only once verification has passed, so a failed run leaves nothing
# behind and no half-written sheet can ever be mistaken for a good one.
OUT="$(mktemp)"
CODE="PW-$(LC_ALL=C tr -dc 'A-Z0-9' </dev/urandom | head -c4)"

cat > "$OUT" <<EOF
================================================================================
  FEUILLE A  --  ACCES AU STOCKAGE                 etabli le $(date +%Y-%m-%d)
================================================================================

  Sauvegarde du serveur familial. Cette feuille permet de TELECHARGER
  l'archive, pas de la LIRE. Le mot de passe de dechiffrement est sur une
  seconde feuille, rangee ailleurs, portant le code $CODE.
  Il faut les deux pour lire quoi que ce soit.

  ATTENTION : cette feuille seule ne permet pas de lire la sauvegarde, mais
  elle permet de la SUPPRIMER - la cle ci-dessous a le droit d'effacer, et le
  bucket n'a ni versioning ni object lock. A ranger aussi soigneusement que
  l'autre.

  Depot        $URI
  Region       $RG
  Cle d'acces  $AK
  Cle secrete  $SK

--------------------------------------------------------------------------------
  QUOI FAIRE  --  depuis n'importe quel ordinateur, apres avoir installe
  restic (https://restic.net) :

    export RESTIC_REPOSITORY="$URI"
    export AWS_ACCESS_KEY_ID="$AK"
    export AWS_SECRET_ACCESS_KEY="$SK"
    export AWS_DEFAULT_REGION="$RG"
    export RESTIC_PASSWORD="<le mot de passe de la feuille $CODE>"

    restic snapshots          # verifier que ca repond

  Pour repartir vite, un seul fichier suffit : il contient tous les autres
  mots de passe du systeme. Quelques kilo-octets, n'importe quel disque fait
  l'affaire.

    restic restore latest --target /tmp/r --include /userdata/pi-web-env
    # ressort dans  /tmp/r/userdata/pi-web-env/.env

  Pour tout restaurer, il faut environ 250 Go LIBRES sur un vrai disque.
  Ne pas viser /tmp : c'est souvent de la RAM, la restauration mourrait en
  route. Monter un disque et viser dessus :

    restic restore latest --target /mnt/restore

--------------------------------------------------------------------------------
  A SAVOIR

  - Ces valeurs ne changent quasiment jamais. Apres une rotation de la cle S3
    ou du mot de passe du depot, relancer  sh scripts/recovery-kit.sh  puis
    REIMPRIMER ET REMPLACER LES DEUX FEUILLES : le code d'appariement change
    a chaque fois, une seule moitie remplacee ne correspondrait plus a l'autre.
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

log "kit written to $OUT (pairing code $CODE)"
log "print it, cut along the %%%% line, store the two halves apart, then:"
log "    shred -u $OUT"
